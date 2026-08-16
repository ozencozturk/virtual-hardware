//! virtio-console over the MMIO transport: a whole write() per descriptor chain
//! rather than the two vmexits per byte a 16550 costs.
//!
//! Transmit walks a chain and hands it to a caller-supplied sink; receive holds
//! input in a FIFO and fills the guest's posted buffers. Modern layout only
//! (VIRTIO_F_VERSION_1), so there is no legacy transitional path.
//!
//! `pushInput` and `serviceRx` may run on different threads; the caller
//! serializes them.

const std = @import("std");
const bits = @import("bits");

/// Where transmitted bytes go, so this model performs no I/O itself. Defaults
/// to discarding; a chain arrives whole, so there is no length to buffer for.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, bytes: []const u8) void = discard,

    fn discard(_: ?*anyopaque, _: []const u8) void {}
};

/// virtio-mmio register offsets (virtio 1.x, transport version 2).
const Reg = enum(usize) {
    magic = 0x000,
    version = 0x004,
    device_id = 0x008,
    vendor_id = 0x00c,
    device_features = 0x010,
    device_features_sel = 0x014,
    driver_features = 0x020,
    driver_features_sel = 0x024,
    queue_sel = 0x030,
    queue_num_max = 0x034,
    queue_num = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_ack = 0x064,
    status = 0x070,
    queue_desc_low = 0x080,
    queue_desc_high = 0x084,
    queue_driver_low = 0x090,
    queue_driver_high = 0x094,
    queue_device_low = 0x0a0,
    queue_device_high = 0x0a4,
    config_generation = 0x0fc,
    _,
};

/// `struct virtio_console_config`. Geometry only; multiport is not offered, so
/// `max_nr_ports` stays 1.
const Config = extern struct {
    cols: u16 = 80,
    rows: u16 = 25,
    max_nr_ports: u32 = 1,
    emerg_wr: u32 = 0,
};

/// Bits the driver writes to the status register as it brings the device up.
const Status = packed struct(u32) {
    acknowledge: bool = false,
    driver: bool = false,
    driver_ok: bool = false,
    features_ok: bool = false,
    _rsvd4: u2 = 0,
    needs_reset: bool = false,
    failed: bool = false,
    _rsvd8: u24 = 0,

    fn fromBits(v: u32) Status {
        return @bitCast(v);
    }
};

/// Descriptor flags. `next` matters most: dropping a chain's tail truncates.
const DescFlags = packed struct(u16) {
    next: bool = false,
    write: bool = false, // device-writable; set on receive buffers
    indirect: bool = false,
    _rsvd: u13 = 0,
};

/// Why the device pulled the interrupt line. Only the used-buffer bit is ever
/// set here — nothing can change this device's configuration under the guest.
const InterruptStatus = packed struct(u32) {
    used_buffer_notification: bool = false,
    config_change: bool = false,
    _rsvd: u30 = 0,

    fn fromBits(v: u32) InterruptStatus {
        return @bitCast(v);
    }

    fn toBits(self: InterruptStatus) u32 {
        return @bitCast(self);
    }

    /// Bits write-1-to-clear may touch, derived so it cannot drift.
    const W1C_MASK = (InterruptStatus{
        .used_buffer_notification = true,
        .config_change = true,
    }).toBits();
};

/// A 64-bit value the transport splits across two 32-bit registers. Fields
/// rather than shifts, because the two halves are otherwise transposable.
const Addr = packed struct(u64) {
    low: u32 = 0,
    hi: u32 = 0,

    fn fromBits(v: u64) Addr {
        return @bitCast(v);
    }

    fn toBits(self: Addr) u64 {
        return @bitCast(self);
    }
};

const MAGIC: u32 = 0x7472_6976; // "virt"
const VERSION: u32 = 2;
const DEVICE_ID: u32 = 3; // console
const VENDOR_ID: u32 = 0x554d_4551;
const VIRTIO_F_VERSION_1: u6 = 32;

/// Everything this device offers; `Addr` splits it for the transport.
const DEVICE_FEATURES: u64 = @as(u64, 1) << VIRTIO_F_VERSION_1;

/// Queue indices fixed by the spec for a console with no multiport support.
const RX_QUEUE = 0;
const TX_QUEUE = 1;
const NUM_QUEUES = 2;

/// Ring size offered to the driver. Power of two, as the spec requires.
pub const QUEUE_SIZE: u32 = 64;

/// Input waiting for the guest. Sized to absorb a paste, not a stream.
const RX_FIFO = 256;

/// Descriptors are 16 bytes: addr, len, flags, next.
const DESC_BYTES = 16;

/// Which half of a split 64-bit register a store lands in.
const Half = enum { low, hi };

/// Write one half of a split address register; the guest may write them in
/// either order, so the other half must survive.
fn setHalf(dst: *u64, half: Half, v: u32) void {
    var a = Addr.fromBits(dst.*);
    switch (half) {
        .low => a.low = v,
        .hi => a.hi = v,
    }
    dst.* = a.toBits();
}

const Queue = struct {
    num: u32 = 0,
    ready: u32 = 0,
    desc: u64 = 0,
    avail: u64 = 0,
    used: u64 = 0,
    /// Next avail-ring slot to consume. Wraps with the ring, not with `idx`.
    last_avail: u16 = 0,
    used_idx: u16 = 0,
};

pub const VirtioConsole = struct {
    /// Width of the MMIO window this device answers on.
    pub const MMIO_SIZE = 0x1000;

    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    interrupt_status: u32 = 0,
    queues: [NUM_QUEUES]Queue = @splat(.{}),
    config: Config = .{},
    /// Bytes handed to the sink.
    bytes_out: u64 = 0,
    /// A buffer was completed and the guest has not acknowledged it yet.
    irq_line: bool = false,
    /// Where transmitted bytes go. Supplied by the owner — see `Sink`.
    out: Sink = .{},

    /// Input waiting for the guest to post a buffer, oldest first. A full ring
    /// drops the newest byte, as a real UART's receive FIFO does on overrun.
    rx: [RX_FIFO]u8 = @splat(0),
    rx_head: usize = 0,
    rx_len: usize = 0,
    /// Bytes handed to the guest.
    bytes_in: u64 = 0,
    /// Dropped because the FIFO was full, so an overrun is visible.
    rx_dropped: u64 = 0,

    pub fn load(self: *VirtioConsole, offset: usize, size: usize) !u64 {
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        // Device configuration space, past the transport registers.
        if (offset >= 0x100) {
            const c = std.mem.asBytes(&self.config);
            const o = offset - 0x100;
            if (o + 4 > c.len) return 0;
            return std.mem.readInt(u32, c[o..][0..4], .little);
        }
        return switch (@as(Reg, @enumFromInt(offset))) {
            .magic => MAGIC,
            .version => VERSION,
            .device_id => DEVICE_ID,
            .vendor_id => VENDOR_ID,
            // Only bit 32 is offered: low word empty, high word carries it.
            .device_features => blk: {
                const f = Addr.fromBits(DEVICE_FEATURES);
                break :blk if (self.device_features_sel == 1) f.hi else f.low;
            },
            .queue_num_max => QUEUE_SIZE,
            .queue_ready => if (self.queueOrNull()) |q| q.ready else 0,
            .interrupt_status => self.interrupt_status,
            .status => self.status,
            .config_generation => 0,
            else => 0,
        };
    }

    pub fn store(self: *VirtioConsole, offset: usize, size: usize, value: u64) !void {
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        if (offset >= 0x100) return; // config space is read-only here
        const v: u32 = @truncate(value);
        switch (@as(Reg, @enumFromInt(offset))) {
            .device_features_sel => self.device_features_sel = v,
            .driver_features_sel => self.driver_features_sel = v,
            .driver_features => {
                var f = Addr.fromBits(self.driver_features);
                if (self.driver_features_sel == 1) f.hi = v else f.low = v;
                self.driver_features = f.toBits();
            },
            .queue_sel => self.queue_sel = v,
            .queue_num => (self.queueOrNull() orelse return).num = v,
            .queue_ready => (self.queueOrNull() orelse return).ready = v,
            .queue_desc_low => setHalf(&(self.queueOrNull() orelse return).desc, .low, v),
            .queue_desc_high => setHalf(&(self.queueOrNull() orelse return).desc, .hi, v),
            .queue_driver_low => setHalf(&(self.queueOrNull() orelse return).avail, .low, v),
            .queue_driver_high => setHalf(&(self.queueOrNull() orelse return).avail, .hi, v),
            .queue_device_low => setHalf(&(self.queueOrNull() orelse return).used, .low, v),
            .queue_device_high => setHalf(&(self.queueOrNull() orelse return).used, .hi, v),
            // Write-1-to-clear, masked to the bits that exist: an ack into
            // reserved positions must not disturb a pending completion.
            .interrupt_ack => {
                self.interrupt_status &= ~(v & InterruptStatus.W1C_MASK);
                if (self.interrupt_status == 0) self.irq_line = false;
            },
            .status => {
                self.status = v;
                if (v == 0) self.reset();
            },
            else => {},
        }
    }

    /// The selected queue, or null. `queue_sel` is guest data: an out-of-range
    /// select must not index the array or fall back to a real queue.
    fn queueOrNull(self: *VirtioConsole) ?*Queue {
        return if (self.queue_sel < NUM_QUEUES) &self.queues[@intCast(self.queue_sel)] else null;
    }

    fn reset(self: *VirtioConsole) void {
        // Totals describe the run, not the device incarnation, so they survive;
        // queued input does not, its destination buffers went with the rings.
        const out = self.bytes_out;
        const in = self.bytes_in;
        const dropped = self.rx_dropped;
        // The sink is the owner's wiring, not device state.
        const sink = self.out;
        self.* = .{};
        self.bytes_out = out;
        self.bytes_in = in;
        self.rx_dropped = dropped;
        self.out = sink;
    }

    /// Queue one byte for the guest; false when the FIFO was full and it was
    /// dropped. Dropping beats blocking on a guest that is not draining.
    pub fn pushInput(self: *VirtioConsole, byte: u8) bool {
        if (self.rx_len >= RX_FIFO) {
            self.rx_dropped += 1;
            return false;
        }
        self.rx[(self.rx_head + self.rx_len) % RX_FIFO] = byte;
        self.rx_len += 1;
        return true;
    }

    /// Hand queued input to the guest. Does nothing until the driver is up and
    /// has posted a buffer, so input typed before then waits rather than is lost.
    pub fn serviceRx(self: *VirtioConsole, memory: []u8, base: u64) void {
        if (!Status.fromBits(self.status).driver_ok) return;
        const q = &self.queues[RX_QUEUE];
        if (q.ready != 1 or q.num == 0) return;

        while (self.rx_len > 0) {
            const avail_idx = readU16(memory, base, q.avail + 2) orelse return;
            if (q.last_avail == avail_idx) return; // no buffer posted
            const slot = q.last_avail % @as(u16, @intCast(q.num));
            const head = readU16(memory, base, q.avail + 4 + @as(u64, slot) * 2) orelse return;
            const written = self.fillChain(memory, base, q, head);
            // A chain that took nothing must still complete, or it is retried
            // forever against the same unconsumed byte.
            q.last_avail +%= 1;
            self.completeUsed(memory, base, q, head, written);
        }
    }

    /// Fill a chain's device-writable descriptors; returns bytes written.
    fn fillChain(self: *VirtioConsole, memory: []u8, base: u64, q: *Queue, head: u16) u32 {
        var idx = head;
        var total: u32 = 0;
        var hops: u32 = 0;
        while (hops <= q.num) : (hops += 1) {
            if (idx >= q.num) return total;
            const d = q.desc + @as(u64, idx) * DESC_BYTES;
            const addr = readU64(memory, base, d) orelse return total;
            const len = readU32(memory, base, d + 8) orelse return total;
            const flags: DescFlags = @bitCast(readU16(memory, base, d + 12) orelse return total);
            // Readable descriptor on the receive queue: the driver's mistake.
            if (flags.write) {
                if (guestSlice(memory, base, addr, len)) |buf| {
                    for (buf) |*out| {
                        if (self.rx_len == 0) return total;
                        out.* = self.rx[self.rx_head];
                        self.rx_head = (self.rx_head + 1) % RX_FIFO;
                        self.rx_len -= 1;
                        self.bytes_in += 1;
                        total += 1;
                    }
                }
            }
            if (!flags.next) return total;
            idx = readU16(memory, base, d + 14) orelse return total;
        }
        return total;
    }

    /// The guest kicked a queue. A receive kick means buffers were just posted.
    pub fn notify(self: *VirtioConsole, queue: u32, memory: []u8, base: u64) void {
        if (queue == RX_QUEUE) return self.serviceRx(memory, base);
        if (queue != TX_QUEUE) return;
        if (!Status.fromBits(self.status).driver_ok) return;
        const q = &self.queues[TX_QUEUE];
        if (q.ready != 1 or q.num == 0) return;

        const avail_idx = readU16(memory, base, q.avail + 2) orelse return;
        while (q.last_avail != avail_idx) : (q.last_avail +%= 1) {
            const slot = q.last_avail % @as(u16, @intCast(q.num));
            const head = readU16(memory, base, q.avail + 4 + @as(u64, slot) * 2) orelse return;
            const written = self.writeChain(memory, base, q, head);
            self.completeUsed(memory, base, q, head, written);
        }
    }

    /// Walk a chain into the sink; returns the length consumed.
    fn writeChain(self: *VirtioConsole, memory: []u8, base: u64, q: *Queue, head: u16) u32 {
        var idx = head;
        var total: u32 = 0;
        // A circular chain must not spin: the ring cannot exceed its depth.
        var hops: u32 = 0;
        while (hops <= q.num) : (hops += 1) {
            if (idx >= q.num) return total;
            const d = q.desc + @as(u64, idx) * DESC_BYTES;
            const addr = readU64(memory, base, d) orelse return total;
            const len = readU32(memory, base, d + 8) orelse return total;
            const flags: DescFlags = @bitCast(readU16(memory, base, d + 12) orelse return total);
            // Writable descriptor on the transmit queue: a misfiled receive
            // buffer, not something the guest meant to send.
            if (!flags.write) {
                if (guestSlice(memory, base, addr, len)) |bytes| {
                    if (bytes.len > 0) {
                        self.out.write(self.out.ctx, bytes);
                        self.bytes_out += bytes.len;
                    }
                    total += @intCast(bytes.len);
                }
            }
            if (!flags.next) return total;
            idx = readU16(memory, base, d + 14) orelse return total;
        }
        return total;
    }

    fn completeUsed(self: *VirtioConsole, memory: []u8, base: u64, q: *Queue, head: u16, len: u32) void {
        const slot = q.used_idx % @as(u16, @intCast(q.num));
        const entry = q.used + 4 + @as(u64, slot) * 8;
        writeU32(memory, base, entry, head);
        writeU32(memory, base, entry + 4, len);
        q.used_idx +%= 1;
        writeU16(memory, base, q.used + 2, q.used_idx);
        var isr = InterruptStatus.fromBits(self.interrupt_status);
        isr.used_buffer_notification = true;
        self.interrupt_status = isr.toBits();
        self.irq_line = true;
    }

    /// Level-style, as the UART and block device are: true while unacknowledged.
    pub fn irqAsserted(self: *const VirtioConsole) bool {
        return self.irq_line;
    }
};

// ---- guest memory helpers -------------------------------------------------
// Null rather than a trap: a driver bug must not fault the host.

fn guestSlice(memory: []u8, base: u64, addr: u64, len: u64) ?[]u8 {
    if (addr < base) return null;
    const off = addr - base;
    if (!bits.inBounds(off, len, memory.len)) return null;
    return memory[@intCast(off)..][0..@intCast(len)];
}

fn readU16(memory: []u8, base: u64, addr: u64) ?u16 {
    const s = guestSlice(memory, base, addr, 2) orelse return null;
    return bits.u16le(s, 0);
}

fn readU32(memory: []u8, base: u64, addr: u64) ?u32 {
    const s = guestSlice(memory, base, addr, 4) orelse return null;
    return bits.u32le(s, 0);
}

fn readU64(memory: []u8, base: u64, addr: u64) ?u64 {
    const s = guestSlice(memory, base, addr, 8) orelse return null;
    return bits.u64le(s, 0);
}

fn writeU16(memory: []u8, base: u64, addr: u64, v: u16) void {
    const s = guestSlice(memory, base, addr, 2) orelse return;
    std.mem.writeInt(u16, s[0..2], v, .little);
}

fn writeU32(memory: []u8, base: u64, addr: u64, v: u32) void {
    const s = guestSlice(memory, base, addr, 4) orelse return;
    std.mem.writeInt(u32, s[0..4], v, .little);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const TEST_BASE: u64 = 0;

/// A `Sink` that keeps what it is given, so tests can assert on the bytes.
const Capture = struct {
    buf: [256]u8 = @splat(0),
    len: usize = 0,

    fn sink(self: *Capture) Sink {
        return .{ .ctx = self, .write = &onWrite };
    }

    fn onWrite(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        // Truncate rather than panic inside the harness.
        const room = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..room], bytes[0..room]);
        self.len += room;
    }

    fn captured(self: *const Capture) []const u8 {
        return self.buf[0..self.len];
    }
};

test "vconsole: identifies as a modern virtio console" {
    var c = VirtioConsole{};
    try testing.expectEqual(@as(u64, MAGIC), try c.load(0x000, 4));
    try testing.expectEqual(@as(u64, 2), try c.load(0x004, 4));
    try testing.expectEqual(@as(u64, 3), try c.load(0x008, 4)); // console
    try testing.expectEqual(@as(u64, QUEUE_SIZE), try c.load(0x034, 4));
    // VIRTIO_F_VERSION_1 lives in the high feature word, and only there.
    try c.store(0x014, 4, 0);
    try testing.expectEqual(@as(u64, 0), try c.load(0x010, 4));
    try c.store(0x014, 4, 1);
    try testing.expectEqual(@as(u64, 1), try c.load(0x010, 4));
}

test "vconsole: a transmit chain reaches the host and is completed once" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    var c = VirtioConsole{};
    // Bring the queue up the way a driver does.
    try c.store(0x030, 4, TX_QUEUE); // queue_sel
    try c.store(0x038, 4, 4); // queue_num
    try c.store(0x080, 4, 0x1000); // desc
    try c.store(0x090, 4, 0x2000); // avail
    try c.store(0x0a0, 4, 0x3000); // used
    try c.store(0x044, 4, 1); // ready
    try c.store(0x070, 4, @as(u32, @bitCast(Status{
        .acknowledge = true,
        .driver = true,
        .features_ok = true,
        .driver_ok = true,
    })));

    // One descriptor covering four bytes of payload.
    const payload = "hi!\n";
    @memcpy(ram[0x800..][0..payload.len], payload);
    std.mem.writeInt(u64, ram[0x1000..][0..8], 0x800, .little); // addr
    std.mem.writeInt(u32, ram[0x1008..][0..4], payload.len, .little); // len
    std.mem.writeInt(u16, ram[0x100c..][0..2], 0, .little); // flags: no next
    std.mem.writeInt(u16, ram[0x2004..][0..2], 0, .little); // avail.ring[0] = 0
    std.mem.writeInt(u16, ram[0x2002..][0..2], 1, .little); // avail.idx = 1

    var got: Capture = .{};
    c.out = got.sink();

    c.notify(TX_QUEUE, ram, TEST_BASE);

    try testing.expectEqualStrings(payload, got.captured());
    try testing.expectEqual(@as(u64, payload.len), c.bytes_out);
    try testing.expect(c.irqAsserted());
    // Used ring: one entry, naming the head descriptor and its length.
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x3002..][0..2], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ram[0x3004..][0..4], .little));
    try testing.expectEqual(@as(u32, payload.len), std.mem.readInt(u32, ram[0x3008..][0..4], .little));

    // A second kick with no new avail entry must not re-send or re-complete.
    c.notify(TX_QUEUE, ram, TEST_BASE);
    try testing.expectEqual(@as(u64, payload.len), c.bytes_out);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x3002..][0..2], .little));
}

/// Bring a queue up the way a driver does. Used by the receive tests, which
/// need two queues configured rather than the one the transmit tests set up.
fn bringUp(c: *VirtioConsole, ram: []u8, queue: u32, num: u32, desc: u32, avail: u32, used: u32) !void {
    try c.store(0x030, 4, queue);
    try c.store(0x038, 4, num);
    try c.store(0x080, 4, desc);
    try c.store(0x090, 4, avail);
    try c.store(0x0a0, 4, used);
    try c.store(0x044, 4, 1);
    _ = ram;
}

test "vconsole: queued input fills a posted receive buffer and completes it once" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    var c = VirtioConsole{};
    try bringUp(&c, ram, RX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try c.store(0x070, 4, @as(u32, @bitCast(Status{
        .acknowledge = true, .driver = true, .features_ok = true, .driver_ok = true,
    })));

    // Type before the guest posts anything: input must wait, not vanish.
    for ("hi!") |ch| try testing.expect(c.pushInput(ch));
    c.serviceRx(ram, TEST_BASE);
    try testing.expectEqual(@as(u64, 0), c.bytes_in);

    // Now the driver posts one 8-byte device-writable buffer.
    std.mem.writeInt(u64, ram[0x1000..][0..8], 0x800, .little); // addr
    std.mem.writeInt(u32, ram[0x1008..][0..4], 8, .little); // len
    std.mem.writeInt(u16, ram[0x100c..][0..2], @as(u16, @bitCast(DescFlags{ .write = true })), .little);
    std.mem.writeInt(u16, ram[0x2004..][0..2], 0, .little); // avail.ring[0] = desc 0
    std.mem.writeInt(u16, ram[0x2002..][0..2], 1, .little); // avail.idx = 1

    c.serviceRx(ram, TEST_BASE);

    try testing.expectEqualStrings("hi!", ram[0x800..0x803]);
    try testing.expectEqual(@as(u64, 3), c.bytes_in);
    try testing.expect(c.irqAsserted());
    // Used ring names the head and the count actually written, not the capacity.
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x3002..][0..2], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, ram[0x3008..][0..4], .little));

    // Nothing left to give: a second pass must not re-complete the buffer.
    c.serviceRx(ram, TEST_BASE);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x3002..][0..2], .little));
}

test "vconsole: a full input FIFO drops rather than blocking, and says so" {
    var c = VirtioConsole{};
    for (0..RX_FIFO) |i| try testing.expect(c.pushInput(@truncate(i)));
    try testing.expect(!c.pushInput('x'));
    try testing.expectEqual(@as(u64, 1), c.rx_dropped);
    try testing.expectEqual(@as(usize, RX_FIFO), c.rx_len);
}

test "vconsole: input goes nowhere until the driver is up" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    var c = VirtioConsole{};
    try bringUp(&c, ram, RX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    // Buffer posted, input waiting — but status lacks DRIVER_OK.
    std.mem.writeInt(u64, ram[0x1000..][0..8], 0x800, .little);
    std.mem.writeInt(u32, ram[0x1008..][0..4], 8, .little);
    std.mem.writeInt(u16, ram[0x100c..][0..2], @as(u16, @bitCast(DescFlags{ .write = true })), .little);
    std.mem.writeInt(u16, ram[0x2004..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[0x2002..][0..2], 1, .little);
    try testing.expect(c.pushInput('z'));
    c.serviceRx(ram, TEST_BASE);
    try testing.expectEqual(@as(u64, 0), c.bytes_in);
    try testing.expectEqual(@as(usize, 1), c.rx_len); // still queued, not lost
}

test "vconsole: a device-readable descriptor on the receive queue is skipped" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    var c = VirtioConsole{};
    try bringUp(&c, ram, RX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try c.store(0x070, 4, @as(u32, @bitCast(Status{
        .acknowledge = true, .driver = true, .features_ok = true, .driver_ok = true,
    })));
    // Misfiled: readable, not writable. Must not be written into.
    std.mem.writeInt(u64, ram[0x1000..][0..8], 0x800, .little);
    std.mem.writeInt(u32, ram[0x1008..][0..4], 8, .little);
    std.mem.writeInt(u16, ram[0x100c..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[0x2004..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[0x2002..][0..2], 1, .little);
    try testing.expect(c.pushInput('q'));
    c.serviceRx(ram, TEST_BASE);
    try testing.expectEqual(@as(u8, 0), ram[0x800]); // untouched
    try testing.expectEqual(@as(u64, 0), c.bytes_in);
    // Completed with length 0 so the ring still advances and cannot wedge.
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x3002..][0..2], .little));
}

test "vconsole: acknowledging the interrupt drops the line" {
    var c = VirtioConsole{};
    c.interrupt_status = 1;
    c.irq_line = true;
    try c.store(0x064, 4, 1); // interrupt_ack
    try testing.expectEqual(@as(u32, 0), c.interrupt_status);
    try testing.expect(!c.irqAsserted());
}

test "vconsole: a split queue address takes both halves, written in either order" {
    var c = VirtioConsole{};
    try c.store(0x030, 4, TX_QUEUE);

    // Low then high. A transposed mask would drop one half or shift it into the
    // other, and both mistakes still produce a plausible-looking address.
    try c.store(0x080, 4, 0x8000_1000); // desc low
    try c.store(0x084, 4, 0x0000_0007); // desc high
    try testing.expectEqual(@as(u64, 0x0000_0007_8000_1000), c.queues[TX_QUEUE].desc);

    // High then low: the guest may write them in either order, so the half that
    // arrives first has to survive the second write.
    try c.store(0x094, 4, 0x0000_0009); // avail high
    try c.store(0x090, 4, 0xdead_b000); // avail low
    try testing.expectEqual(@as(u64, 0x0000_0009_dead_b000), c.queues[TX_QUEUE].avail);

    // Rewriting one half must leave the other standing.
    try c.store(0x0a0, 4, 0x1111_1000); // used low
    try c.store(0x0a4, 4, 0x2222_2222); // used high
    try c.store(0x0a0, 4, 0x3333_3000); // used low again
    try testing.expectEqual(@as(u64, 0x2222_2222_3333_3000), c.queues[TX_QUEUE].used);
}

test "vconsole: interrupt ack clears only the bits that exist" {
    var c = VirtioConsole{};
    c.interrupt_status = 1;
    c.irq_line = true;

    // An ack carrying only reserved bits must not disturb a pending completion.
    try c.store(0x064, 4, 0xffff_fffc);
    try testing.expectEqual(@as(u32, 1), c.interrupt_status);
    try testing.expect(c.irqAsserted());

    try c.store(0x064, 4, 1);
    try testing.expectEqual(@as(u32, 0), c.interrupt_status);
    try testing.expect(!c.irqAsserted());
}

test "vconsole: a guest-chosen queue index cannot escape the array" {
    var c = VirtioConsole{};
    try c.store(0x030, 4, 99); // queue_sel far out of range
    // Must answer rather than fault, and must not have touched a real queue.
    _ = try c.load(0x044, 4);
    try c.store(0x038, 4, 8);
    try testing.expectEqual(@as(u32, 0), c.queues[RX_QUEUE].num);
    try testing.expectEqual(@as(u32, 0), c.queues[TX_QUEUE].num);
}

test "vconsole: a circular descriptor chain terminates" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    var c = VirtioConsole{};
    try c.store(0x030, 4, TX_QUEUE);
    try c.store(0x038, 4, 2);
    try c.store(0x080, 4, 0x1000);
    try c.store(0x090, 4, 0x2000);
    try c.store(0x0a0, 4, 0x3000);
    try c.store(0x044, 4, 1);
    try c.store(0x070, 4, @as(u32, @bitCast(Status{
        .acknowledge = true,
        .driver = true,
        .features_ok = true,
        .driver_ok = true,
    })));

    // desc[0] -> desc[1] -> desc[0] ...
    std.mem.writeInt(u64, ram[0x1000..][0..8], 0x800, .little);
    std.mem.writeInt(u32, ram[0x1008..][0..4], 0, .little);
    std.mem.writeInt(u16, ram[0x100c..][0..2], 1, .little); // next
    std.mem.writeInt(u16, ram[0x100e..][0..2], 1, .little);
    std.mem.writeInt(u64, ram[0x1010..][0..8], 0x800, .little);
    std.mem.writeInt(u32, ram[0x1018..][0..4], 0, .little);
    std.mem.writeInt(u16, ram[0x101c..][0..2], 1, .little); // next
    std.mem.writeInt(u16, ram[0x101e..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[0x2004..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[0x2002..][0..2], 1, .little);

    // Nothing is asserted about the bytes; the default sink discards them.
    c.notify(TX_QUEUE, ram, TEST_BASE); // must return, not hang
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x3002..][0..2], .little));
}
