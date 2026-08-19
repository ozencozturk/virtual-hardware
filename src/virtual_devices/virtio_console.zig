//! virtio-console over the memory-mapped transport: a whole write per
//! descriptor chain rather than the two exits per byte a 16550 costs.
//!
//! Both directions are bounded buffers the owner works against: it pushes input
//! in and takes output out, so this model performs no I/O of its own.
//!
//! A transmit chain that does not fit in the output ring is left uncompleted
//! rather than truncated, so a guest writing faster than the owner reads waits
//! instead of losing bytes.
//!
//! `pushInput` and `service` may run on different threads; the caller
//! serializes them.

const std = @import("std");
const mmio = @import("virtio_mmio.zig");
const virtqueue = @import("virtqueue.zig");

pub const Guest = virtqueue.Guest;

/// `struct virtio_console_config`. Geometry only; multiport is not offered, so
/// `max_nr_ports` stays 1.
const Config = extern struct {
    cols: u16 = 80,
    rows: u16 = 25,
    max_nr_ports: u32 = 1,
    emerg_wr: u32 = 0,
};

/// Queue indices fixed by the spec for a console with no multiport support.
const RX_QUEUE = 0;
const TX_QUEUE = 1;
const NUM_QUEUES = 2;

/// Ring depth offered to the driver. Power of two, as the spec requires.
pub const QUEUE_SIZE: u32 = 64;

/// Input waiting for the guest. Sized to absorb a paste, not a stream.
const RX_FIFO = 256;

/// Output waiting for the owner. Sized to hold more than any one chain, so back
/// pressure is what a slow reader causes and not what a large write does.
const TX_RING = 64 * 1024;

pub const VirtioConsole = struct {
    pub const MMIO_SIZE = mmio.MMIO_SIZE;

    const Transport = mmio.Transport(.{
        .device_id = 3,
        .num_queues = NUM_QUEUES,
        .queue_size = QUEUE_SIZE,
    });

    transport: Transport = .{},
    config: Config = .{},
    /// Bytes the guest has written and the owner has taken.
    bytes_out: u64 = 0,
    /// Written by the guest and not yet taken, oldest first.
    tx: [TX_RING]u8 = @splat(0),
    tx_head: usize = 0,
    tx_len: usize = 0,

    /// Input waiting for the guest to post a buffer, oldest first. A full ring
    /// drops the newest byte, as a real receive buffer does on overrun.
    rx: [RX_FIFO]u8 = @splat(0),
    rx_head: usize = 0,
    rx_len: usize = 0,
    /// Bytes handed to the guest.
    bytes_in: u64 = 0,
    /// Dropped because the buffer was full, so an overrun is visible.
    rx_dropped: u64 = 0,

    /// Read a register. Accesses must be aligned words.
    pub fn load(self: *const VirtioConsole, offset: usize, size: usize) !u64 {
        if (offset >= mmio.CONFIG_BASE) {
            return mmio.configRead(std.mem.asBytes(&self.config), offset - mmio.CONFIG_BASE, size);
        }
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        return self.transport.load(offset);
    }

    /// Write a register, answering what the device must do next.
    pub fn store(self: *VirtioConsole, offset: usize, size: usize, value: u64) !mmio.Action {
        if (offset >= mmio.CONFIG_BASE) return .none; // configuration is read-only
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        const action = self.transport.store(offset, @truncate(value));
        switch (action) {
            .reset => self.reset(),
            else => {},
        }
        return action;
    }

    /// Queue one byte for the guest; false when the buffer was full and it was
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

    /// Serve the chains posted to `queue`. A receive kick means buffers were
    /// just posted; a transmit kick means bytes are ready to go out.
    pub fn service(self: *VirtioConsole, queue: u32, g: Guest) void {
        switch (queue) {
            RX_QUEUE => self.serviceRx(g),
            TX_QUEUE => self.serviceTx(g),
            else => {},
        }
    }

    /// Hand queued input to the guest. Does nothing until the driver is up and
    /// has posted a buffer, so input typed before then waits rather than is lost.
    pub fn serviceRx(self: *VirtioConsole, g: Guest) void {
        if (!self.transport.driverOk()) return;
        const q = self.transport.queue(RX_QUEUE) orelse return;
        if (!q.live()) return;
        while (self.rx_len > 0) {
            const head = q.nextHead(g) orelse return;
            // A chain that took nothing must still complete, or it is retried
            // forever against the same unconsumed byte.
            const written = self.fillChain(g, q.*, head);
            self.transport.complete(RX_QUEUE, g, head, written);
        }
    }

    /// True while a completion is unacknowledged.
    pub fn irqAsserted(self: *const VirtioConsole) bool {
        return self.transport.irqAsserted();
    }

    /// What the guest has written and the owner has not taken, oldest first.
    /// One contiguous run at most; call again after `takeOutput` for the rest.
    pub fn output(self: *const VirtioConsole) []const u8 {
        const run = @min(self.tx_len, TX_RING - self.tx_head);
        return self.tx[self.tx_head..][0..run];
    }

    /// Drop the first `n` bytes `output` answered, once they are dealt with.
    pub fn takeOutput(self: *VirtioConsole, n: usize) void {
        const took = @min(n, self.tx_len);
        self.tx_head = (self.tx_head + took) % TX_RING;
        self.tx_len -= took;
        self.bytes_out += took;
    }

    fn serviceTx(self: *VirtioConsole, g: Guest) void {
        if (!self.transport.driverOk()) return;
        const q = self.transport.queue(TX_QUEUE) orelse return;
        if (!q.live()) return;
        while (q.nextHead(g)) |head| {
            // Uncompleted when there is no room, so the guest waits.
            const written = self.writeChain(g, q.*, head) orelse return;
            self.transport.complete(TX_QUEUE, g, head, written);
        }
    }

    /// Fill a chain's device-writable descriptors; returns bytes written.
    fn fillChain(self: *VirtioConsole, g: Guest, q: virtqueue.Queue, head: u16) u32 {
        var total: u32 = 0;
        var c = q.chain(g, head);
        while (c.next()) |d| {
            // Readable descriptor on the receive queue: the driver's mistake.
            if (!d.flags.write) continue;
            const buf = g.slice(d.addr, d.len) orelse continue;
            for (buf) |*out| {
                if (self.rx_len == 0) return total;
                out.* = self.rx[self.rx_head];
                self.rx_head = (self.rx_head + 1) % RX_FIFO;
                self.rx_len -= 1;
                self.bytes_in += 1;
                total += 1;
            }
        }
        return total;
    }

    /// Take a chain's bytes into the output ring; returns the length consumed,
    /// or null when the whole chain does not fit and nothing was taken.
    fn writeChain(self: *VirtioConsole, g: Guest, q: virtqueue.Queue, head: u16) ?u32 {
        var parts: [QUEUE_SIZE][]u8 = undefined;
        var n: usize = 0;
        var total: usize = 0;
        var c = q.chain(g, head);
        while (c.next()) |d| {
            // Writable descriptor on the transmit queue: a misfiled receive
            // buffer, not something the guest meant to send.
            if (d.flags.write or n == parts.len) continue;
            parts[n] = g.slice(d.addr, d.len) orelse continue;
            total += parts[n].len;
            n += 1;
        }
        // All or nothing: a partly taken chain is a torn write.
        if (total > TX_RING - self.tx_len) return null;

        for (parts[0..n]) |part| for (part) |b| {
            self.tx[(self.tx_head + self.tx_len) % TX_RING] = b;
            self.tx_len += 1;
        };
        return @intCast(total);
    }

    fn reset(self: *VirtioConsole) void {
        // Totals and output not yet taken survive; queued input does not, since
        // the buffers it was bound for went with the rings.
        const out = self.bytes_out;
        const in = self.bytes_in;
        const dropped = self.rx_dropped;
        const tx = self.tx;
        const tx_head = self.tx_head;
        const tx_len = self.tx_len;
        self.* = .{};
        self.bytes_out = out;
        self.bytes_in = in;
        self.rx_dropped = dropped;
        self.tx = tx;
        self.tx_head = tx_head;
        self.tx_len = tx_len;
    }
};

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const BASE: u64 = 0;

/// Everything the guest has written, taken out of the ring in runs.
fn drain(c: *VirtioConsole, into: []u8) []const u8 {
    var n: usize = 0;
    while (c.output().len > 0) {
        const run = c.output();
        const take = @min(run.len, into.len - n);
        @memcpy(into[n..][0..take], run[0..take]);
        n += take;
        c.takeOutput(take);
        if (take < run.len) break;
    }
    return into[0..n];
}

/// Bring a queue up the way a driver does.
fn bringUp(c: *VirtioConsole, queue: u32, num: u32, desc: u32, avail: u32, used: u32) !void {
    _ = try c.store(0x030, 4, queue);
    _ = try c.store(0x038, 4, num);
    _ = try c.store(0x080, 4, desc);
    _ = try c.store(0x090, 4, avail);
    _ = try c.store(0x0a0, 4, used);
    _ = try c.store(0x044, 4, 1);
}

/// Set the status bits a driver ends its bring-up with.
fn driverUp(c: *VirtioConsole) !void {
    _ = try c.store(0x070, 4, (mmio.Status{
        .acknowledge = true,
        .driver = true,
        .features_ok = true,
        .driver_ok = true,
    }).toBits());
}

/// One descriptor at table index 0, posted and published.
fn postOne(g: Guest, addr: u64, len: u32, flags: virtqueue.DescFlags) void {
    g.write(u64, 0x1000, addr);
    g.write(u32, 0x1008, len);
    g.write(u16, 0x100c, @bitCast(flags));
    g.write(u16, 0x2004, 0); // avail.ring[0] = descriptor 0
    g.write(u16, 0x2002, 1); // avail.idx = 1
}

test "console: identifies as a modern virtio console" {
    var c = VirtioConsole{};
    try testing.expectEqual(@as(u64, mmio.MAGIC), try c.load(0x000, 4));
    try testing.expectEqual(@as(u64, 2), try c.load(0x004, 4));
    try testing.expectEqual(@as(u64, 3), try c.load(0x008, 4)); // console
    try testing.expectEqual(@as(u64, QUEUE_SIZE), try c.load(0x034, 4));
}

test "console: geometry reads out of configuration space" {
    var c = VirtioConsole{};
    const geometry = try c.load(0x100, 4);
    try testing.expectEqual(@as(u64, 80), geometry & 0xffff);
    try testing.expectEqual(@as(u64, 25), geometry >> 16);
    try testing.expectEqual(@as(u64, 1), try c.load(0x104, 4));
    // Past the structure, and read-only.
    try testing.expectEqual(@as(u64, 0), try c.load(0x200, 4));
    _ = try c.store(0x100, 4, 0);
    try testing.expectEqual(geometry, try c.load(0x100, 4));
}

test "console: a transmit chain reaches the host and is completed once" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, TX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);

    const payload = "hi!\n";
    @memcpy(ram[0x800..][0..payload.len], payload);
    postOne(g, 0x800, payload.len, .{});

    c.service(TX_QUEUE, g);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(payload, drain(&c, &buf));
    try testing.expectEqual(@as(u64, payload.len), c.bytes_out);
    try testing.expect(c.irqAsserted());
    // Used ring: one entry, naming the head descriptor and its length.
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
    try testing.expectEqual(@as(?u32, 0), g.read(u32, 0x3004));
    try testing.expectEqual(@as(?u32, payload.len), g.read(u32, 0x3008));

    // A second kick with no new avail entry must not re-send or re-complete.
    c.service(TX_QUEUE, g);
    try testing.expectEqual(@as(usize, 0), c.output().len);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
}

test "console: queued input fills a posted receive buffer and completes it once" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, RX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);

    // Type before the guest posts anything: input must wait, not vanish.
    for ("hi!") |ch| try testing.expect(c.pushInput(ch));
    c.service(RX_QUEUE, g);
    try testing.expectEqual(@as(u64, 0), c.bytes_in);

    postOne(g, 0x800, 8, .{ .write = true });
    c.service(RX_QUEUE, g);

    try testing.expectEqualStrings("hi!", ram[0x800..0x803]);
    try testing.expectEqual(@as(u64, 3), c.bytes_in);
    try testing.expect(c.irqAsserted());
    // Used ring names the head and the count actually written, not the capacity.
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
    try testing.expectEqual(@as(?u32, 3), g.read(u32, 0x3008));

    // Nothing left to give: a second pass must not re-complete the buffer.
    c.service(RX_QUEUE, g);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
}

test "console: input spanning two descriptors of one chain fills both" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, RX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);
    for ("abcd") |ch| try testing.expect(c.pushInput(ch));

    g.write(u64, 0x1000, 0x800);
    g.write(u32, 0x1008, 2);
    g.write(u16, 0x100c, @bitCast(virtqueue.DescFlags{ .write = true, .next = true }));
    g.write(u16, 0x100e, 1);
    g.write(u64, 0x1010, 0x900);
    g.write(u32, 0x1018, 2);
    g.write(u16, 0x101c, @bitCast(virtqueue.DescFlags{ .write = true }));
    g.write(u16, 0x2004, 0);
    g.write(u16, 0x2002, 1);

    c.service(RX_QUEUE, g);

    try testing.expectEqualStrings("ab", ram[0x800..0x802]);
    try testing.expectEqualStrings("cd", ram[0x900..0x902]);
    try testing.expectEqual(@as(?u32, 4), g.read(u32, 0x3008));
}

test "console: a full input buffer drops rather than blocking, and says so" {
    var c = VirtioConsole{};
    for (0..RX_FIFO) |i| try testing.expect(c.pushInput(@truncate(i)));
    try testing.expect(!c.pushInput('x'));
    try testing.expectEqual(@as(u64, 1), c.rx_dropped);
    try testing.expectEqual(@as(usize, RX_FIFO), c.rx_len);
}

test "console: input goes nowhere until the driver is up" {
    const ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, RX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    postOne(g, 0x800, 8, .{ .write = true });
    try testing.expect(c.pushInput('z'));

    c.service(RX_QUEUE, g);
    try testing.expectEqual(@as(u64, 0), c.bytes_in);
    try testing.expectEqual(@as(usize, 1), c.rx_len); // still queued, not lost
}

test "console: a device-readable descriptor on the receive queue is skipped" {
    const ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, RX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);
    postOne(g, 0x800, 8, .{}); // misfiled: readable, not writable
    try testing.expect(c.pushInput('q'));

    c.service(RX_QUEUE, g);
    try testing.expectEqual(@as(u8, 0), ram[0x800]); // untouched
    try testing.expectEqual(@as(u64, 0), c.bytes_in);
    // Completed with length 0 so the ring still advances and cannot wedge.
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
}

test "console: a writable descriptor on the transmit queue is not sent" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, TX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);
    @memcpy(ram[0x800..][0..2], "no");
    postOne(g, 0x800, 2, .{ .write = true });

    c.service(TX_QUEUE, g);

    try testing.expectEqual(@as(usize, 0), c.output().len);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
}

test "console: acknowledging the interrupt drops the line" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, TX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);
    @memcpy(ram[0x800..][0..2], "hi");
    postOne(g, 0x800, 2, .{});
    c.service(TX_QUEUE, g);
    try testing.expect(c.irqAsserted());

    _ = try c.store(0x064, 4, 1); // interrupt_ack
    try testing.expect(!c.irqAsserted());
}

test "console: a kick on a queue this device does not have serves nothing" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, TX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);
    @memcpy(ram[0x800..][0..2], "hi");
    postOne(g, 0x800, 2, .{});

    c.service(9, g);
    try testing.expectEqual(@as(?u16, 0), g.read(u16, 0x3002));
}

test "console: a reset clears the rings and keeps the totals and the sink" {
    var ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, TX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);
    @memcpy(ram[0x800..][0..2], "hi");
    postOne(g, 0x800, 2, .{});
    c.service(TX_QUEUE, g);
    try testing.expect(c.pushInput('z'));

    _ = try c.store(0x070, 4, 0);

    try testing.expectEqual(@as(u32, 0), c.transport.queues[TX_QUEUE].num);
    try testing.expectEqual(@as(usize, 0), c.rx_len);
    // What the guest already said is a record, and the owner has not had it yet.
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hi", drain(&c, &buf));
}

test "console: output the owner has not taken stops the guest rather than dropping" {
    const ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, TX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);

    // Fill the ring, leaving less room than the next chain needs.
    c.tx_len = TX_RING - 1;
    @memcpy(ram[0x800..][0..2], "hi");
    postOne(g, 0x800, 2, .{});

    c.service(TX_QUEUE, g);
    // Not completed, so the driver is still waiting on it.
    try testing.expectEqual(@as(?u16, 0), g.read(u16, 0x3002));

    c.takeOutput(TX_RING);
    c.service(TX_QUEUE, g);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hi", drain(&c, &buf));
}

test "console: output taken in runs comes back in order across the wrap" {
    const ram = try testing.allocator.alloc(u8, 0x4000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var c = VirtioConsole{};
    try bringUp(&c, TX_QUEUE, 4, 0x1000, 0x2000, 0x3000);
    try driverUp(&c);
    // Start near the end of the ring so the next write straddles it.
    c.tx_head = TX_RING - 2;

    @memcpy(ram[0x800..][0..4], "abcd");
    postOne(g, 0x800, 4, .{});
    c.service(TX_QUEUE, g);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("abcd", drain(&c, &buf));
    try testing.expectEqual(@as(u64, 4), c.bytes_out);
}
