//! virtio-net over the memory-mapped transport: frames between a guest and
//! whoever owns the device.
//!
//! Receive holds frames the owner has pushed and fills the buffers the guest
//! posts; transmit collects the frames the guest sends for the owner to take.
//! Both are bounded queues, so this model performs no I/O of its own.
//!
//! `pushFrame` and `peekFrame` deal in frames alone; the twelve-byte virtio
//! header in front of each one is added and stripped here.

const std = @import("std");
const mmio = @import("virtio_mmio.zig");
const virtqueue = @import("virtqueue.zig");
const packet_fifo = @import("packet_fifo.zig");

pub const Guest = virtqueue.Guest;

/// VIRTIO_NET_F_MAC: the address comes from configuration space, so the driver
/// does not invent one.
pub const F_MAC: u6 = 5;

/// `struct virtio_net_config`, as far as the offered features reach.
const Config = extern struct {
    mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 },
    /// Link state; only the "up" bit is defined for what is offered here.
    status: u16 = 0,
};

/// `struct virtio_net_hdr_v1`, in front of every frame in either direction.
const FrameHeader = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    /// Buffers this frame occupies. One, since buffer merging is not offered.
    num_buffers: u16 = 1,

    const BYTES = 12;
};

/// Queue indices fixed by the spec for a device with one pair.
const RX_QUEUE = 0;
const TX_QUEUE = 1;
const NUM_QUEUES = 2;

/// Ring depth offered to the driver. Power of two, as the spec requires.
pub const QUEUE_SIZE: u32 = 64;

/// Longest frame carried, ethernet's own limit.
pub const MAX_FRAME = 1514;

/// Frames each direction holds before it drops. An owner that takes what it is
/// given whenever the guest exits never fills them.
const RX_FRAMES = 8;
const TX_FRAMES = 8;

pub const VirtioNet = struct {
    pub const MMIO_SIZE = mmio.MMIO_SIZE;

    const Transport = mmio.Transport(.{
        .device_id = 1,
        .num_queues = NUM_QUEUES,
        .queue_size = QUEUE_SIZE,
        .features = @as(u64, 1) << F_MAC,
    });

    transport: Transport = .{},
    config: Config = .{},

    /// Frames waiting for the guest to post a buffer.
    rx: packet_fifo.Fifo(RX_FRAMES, MAX_FRAME) = .{},
    /// Frames the guest has sent, waiting for the owner to take them.
    tx: packet_fifo.Fifo(TX_FRAMES, MAX_FRAME) = .{},

    /// Frames handed over in each direction.
    frames_in: u64 = 0,
    frames_out: u64 = 0,

    /// Read a register. Accesses must be aligned words.
    pub fn load(self: *const VirtioNet, offset: usize, size: usize) !u64 {
        if (offset >= mmio.CONFIG_BASE) {
            return mmio.configRead(std.mem.asBytes(&self.config), offset - mmio.CONFIG_BASE, size);
        }
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        return self.transport.load(offset);
    }

    /// Write a register, answering what the device must do next.
    pub fn store(self: *VirtioNet, offset: usize, size: usize, value: u64) !mmio.Action {
        if (offset >= mmio.CONFIG_BASE) return .none; // configuration is read-only
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        const action = self.transport.store(offset, @truncate(value));
        switch (action) {
            .reset => self.reset(),
            else => {},
        }
        return action;
    }

    /// Queue a frame for the guest; false when the queue was full and it was
    /// dropped.
    pub fn pushFrame(self: *VirtioNet, frame: []const u8) bool {
        return self.rx.push(frame);
    }

    /// The oldest frame the guest has sent, or null when it has sent none.
    /// Valid until the next call that changes this device.
    pub fn peekFrame(self: *const VirtioNet) ?[]const u8 {
        return self.tx.peek();
    }

    /// Drop the frame `peekFrame` answered, once it has been dealt with.
    pub fn dropFrame(self: *VirtioNet) void {
        self.tx.pop();
    }

    /// Serve the chains posted to `queue`. A receive kick means buffers were
    /// just posted; a transmit kick means frames are ready to go out.
    pub fn service(self: *VirtioNet, queue: u32, g: Guest) void {
        switch (queue) {
            RX_QUEUE => self.serviceRx(g),
            TX_QUEUE => self.serviceTx(g),
            else => {},
        }
    }

    /// Hand queued frames to the guest. Does nothing until the driver is up and
    /// has posted a buffer, so a frame arriving early waits rather than is lost.
    pub fn serviceRx(self: *VirtioNet, g: Guest) void {
        if (!self.transport.driverOk()) return;
        const q = self.transport.queue(RX_QUEUE) orelse return;
        if (!q.live()) return;
        while (self.rx.peek()) |frame| {
            const head = q.nextHead(g) orelse return;
            const written = deliver(g, q.*, head, frame);
            // A buffer too small still completes, or the queue is retried
            // forever against a frame that can never fit.
            self.rx.pop();
            if (written != 0) self.frames_in += 1;
            self.transport.complete(RX_QUEUE, g, head, written);
        }
    }

    /// True while a completion is unacknowledged.
    pub fn irqAsserted(self: *const VirtioNet) bool {
        return self.transport.irqAsserted();
    }

    /// Whether the link is up, as the guest reads it.
    pub fn linkUp(self: *const VirtioNet) bool {
        return self.config.status & 1 != 0;
    }

    /// Set the link state the guest reads from configuration space.
    pub fn setLinkUp(self: *VirtioNet, up: bool) void {
        self.config.status = if (up) 1 else 0;
        var isr = mmio.InterruptStatus.fromBits(self.transport.interrupt_status);
        isr.config_change = true;
        self.transport.interrupt_status = isr.toBits();
    }

    fn serviceTx(self: *VirtioNet, g: Guest) void {
        if (!self.transport.driverOk()) return;
        const q = self.transport.queue(TX_QUEUE) orelse return;
        if (!q.live()) return;
        while (q.nextHead(g)) |head| {
            const taken = self.collect(g, q.*, head);
            if (taken) self.frames_out += 1;
            // Transmit buffers are driver-readable, so nothing is written back.
            self.transport.complete(TX_QUEUE, g, head, 0);
        }
    }

    /// Write the virtio header and one frame into a chain's writable
    /// descriptors; returns the bytes written, or zero when it does not fit.
    fn deliver(g: Guest, q: virtqueue.Queue, head: u16, frame: []const u8) u32 {
        var buffers: [QUEUE_SIZE][]u8 = undefined;
        var n: usize = 0;
        var room: usize = 0;
        var c = q.chain(g, head);
        while (c.next()) |d| {
            if (!d.flags.write or n == buffers.len) continue;
            buffers[n] = g.slice(d.addr, d.len) orelse continue;
            room += buffers[n].len;
            n += 1;
        }
        if (room < FrameHeader.BYTES + frame.len) return 0;

        const header = FrameHeader{};
        var staged: [FrameHeader.BYTES + MAX_FRAME]u8 = undefined;
        @memcpy(staged[0..FrameHeader.BYTES], std.mem.asBytes(&header)[0..FrameHeader.BYTES]);
        @memcpy(staged[FrameHeader.BYTES..][0..frame.len], frame);

        var left: []const u8 = staged[0 .. FrameHeader.BYTES + frame.len];
        for (buffers[0..n]) |buf| {
            if (left.len == 0) break;
            const take = @min(buf.len, left.len);
            @memcpy(buf[0..take], left[0..take]);
            left = left[take..];
        }
        return @intCast(FrameHeader.BYTES + frame.len);
    }

    /// Take one frame out of a chain's readable descriptors, dropping the
    /// virtio header in front of it. False when the chain holds no frame.
    fn collect(self: *VirtioNet, g: Guest, q: virtqueue.Queue, head: u16) bool {
        var staged: [FrameHeader.BYTES + MAX_FRAME]u8 = undefined;
        var have: usize = 0;
        var c = q.chain(g, head);
        while (c.next()) |d| {
            if (d.flags.write) continue;
            const buf = g.slice(d.addr, d.len) orelse continue;
            const take = @min(buf.len, staged.len - have);
            @memcpy(staged[have..][0..take], buf[0..take]);
            have += take;
            if (have == staged.len) break;
        }
        if (have <= FrameHeader.BYTES) return false;
        return self.tx.push(staged[FrameHeader.BYTES..have]);
    }

    fn reset(self: *VirtioNet) void {
        // Totals and the address describe the machine, not the driver's
        // incarnation of it; frames in flight went with the rings.
        const config = self.config;
        const in = self.frames_in;
        const out = self.frames_out;
        const rx_dropped = self.rx.dropped;
        const tx_dropped = self.tx.dropped;
        self.* = .{};
        self.config = config;
        self.frames_in = in;
        self.frames_out = out;
        self.rx.dropped = rx_dropped;
        self.tx.dropped = tx_dropped;
    }
};

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const BASE: u64 = 0;

/// Bring a queue up the way a driver does.
fn bringUp(n: *VirtioNet, queue: u32, num: u32, desc: u32, avail: u32, used: u32) !void {
    _ = try n.store(0x030, 4, queue);
    _ = try n.store(0x038, 4, num);
    _ = try n.store(0x080, 4, desc);
    _ = try n.store(0x090, 4, avail);
    _ = try n.store(0x0a0, 4, used);
    _ = try n.store(0x044, 4, 1);
}

/// Set the status bits a driver ends its bring-up with.
fn driverUp(n: *VirtioNet) !void {
    _ = try n.store(0x070, 4, (mmio.Status{
        .acknowledge = true,
        .driver = true,
        .features_ok = true,
        .driver_ok = true,
    }).toBits());
}

/// One descriptor at table index 0 of the table at `desc`, posted and published.
fn postOne(g: Guest, desc: u64, avail: u64, addr: u64, len: u32, write: bool) void {
    g.write(u64, desc, addr);
    g.write(u32, desc + 8, len);
    g.write(u16, desc + 12, @bitCast(virtqueue.DescFlags{ .write = write }));
    g.write(u16, avail + 4, 0);
    g.write(u16, avail + 2, 1);
}

const RX_DESC: u64 = 0x1000;
const RX_AVAIL: u64 = 0x2000;
const RX_USED: u64 = 0x3000;
const TX_DESC: u64 = 0x4000;
const TX_AVAIL: u64 = 0x5000;
const TX_USED: u64 = 0x6000;

test "net: identifies as a modern virtio network device with an address" {
    var n = VirtioNet{};
    try testing.expectEqual(@as(u64, mmio.MAGIC), try n.load(0x000, 4));
    try testing.expectEqual(@as(u64, 2), try n.load(0x004, 4));
    try testing.expectEqual(@as(u64, 1), try n.load(0x008, 4)); // network
    try testing.expectEqual(@as(u64, QUEUE_SIZE), try n.load(0x034, 4));
    _ = try n.store(0x014, 4, 0);
    try testing.expectEqual(@as(u64, 1) << F_MAC, try n.load(0x010, 4));
}

test "net: the address reads out of configuration space, and is read-only" {
    var n = VirtioNet{};
    const first = try n.load(0x100, 4);
    try testing.expectEqual(@as(u64, 0x52), first & 0xff);
    try testing.expectEqual(@as(u64, 0x54), (first >> 8) & 0xff);
    _ = try n.store(0x100, 4, 0);
    try testing.expectEqual(first, try n.load(0x100, 4));
    // Past the structure there is nothing to read.
    try testing.expectEqual(@as(u64, 0), try n.load(0x200, 4));
}

test "net: an unaligned or non-word access faults" {
    var n = VirtioNet{};
    try testing.expectError(error.AccessFault, n.load(0x002, 4));
    try testing.expectError(error.AccessFault, n.load(0x000, 2));
    try testing.expectError(error.AccessFault, n.store(0x070, 1, 0));
}

test "net: a pushed frame fills a posted buffer, header first" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&n);

    const frame = "a frame";
    try testing.expect(n.pushFrame(frame));
    postOne(g, RX_DESC, RX_AVAIL, 0x700, 128, true);
    n.service(RX_QUEUE, g);

    try testing.expectEqualStrings(frame, ram[0x700 + FrameHeader.BYTES ..][0..frame.len]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x700 + 10 ..][0..2], .little));
    try testing.expectEqual(@as(u64, 1), n.frames_in);
    try testing.expect(n.irqAsserted());
    try testing.expectEqual(@as(?u32, FrameHeader.BYTES + frame.len), g.read(u32, RX_USED + 8));

    // Nothing left to give: a second pass must not re-complete the buffer.
    n.service(RX_QUEUE, g);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, RX_USED + 2));
}

test "net: a frame arriving before the driver is up waits rather than is lost" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try testing.expect(n.pushFrame("waiting"));
    postOne(g, RX_DESC, RX_AVAIL, 0x700, 128, true);

    n.service(RX_QUEUE, g);
    try testing.expectEqual(@as(u64, 0), n.frames_in);

    try driverUp(&n);
    n.service(RX_QUEUE, g);
    try testing.expectEqual(@as(u64, 1), n.frames_in);
}

test "net: a frame spanning two posted descriptors fills both" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&n);

    const frame = "0123456789abcdef";
    try testing.expect(n.pushFrame(frame));
    g.write(u64, RX_DESC, 0x700);
    g.write(u32, RX_DESC + 8, 16);
    g.write(u16, RX_DESC + 12, @bitCast(virtqueue.DescFlags{ .write = true, .next = true }));
    g.write(u16, RX_DESC + 14, 1);
    g.write(u64, RX_DESC + 16, 0x800);
    g.write(u32, RX_DESC + 24, 64);
    g.write(u16, RX_DESC + 28, @bitCast(virtqueue.DescFlags{ .write = true }));
    g.write(u16, RX_AVAIL + 4, 0);
    g.write(u16, RX_AVAIL + 2, 1);

    n.service(RX_QUEUE, g);

    // Twelve header bytes then four of payload fill the first descriptor.
    try testing.expectEqualStrings("0123", ram[0x70c..0x710]);
    try testing.expectEqualStrings("456789abcdef", ram[0x800..0x80c]);
    try testing.expectEqual(@as(u64, 1), n.frames_in);
}

test "net: a buffer too small for the frame completes empty and drops it" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&n);

    try testing.expect(n.pushFrame("much too long for the buffer posted"));
    postOne(g, RX_DESC, RX_AVAIL, 0x700, 8, true);
    n.service(RX_QUEUE, g);

    try testing.expectEqual(@as(u64, 0), n.frames_in);
    try testing.expectEqual(@as(?u32, 0), g.read(u32, RX_USED + 8));
    // The ring advanced, so the queue cannot wedge on a frame that never fits.
    try testing.expectEqual(@as(?u16, 1), g.read(u16, RX_USED + 2));
}

test "net: a transmitted chain becomes a frame the owner can take" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, TX_QUEUE, 4, TX_DESC, TX_AVAIL, TX_USED);
    try driverUp(&n);

    const frame = "outbound";
    @memcpy(ram[0x700 + FrameHeader.BYTES ..][0..frame.len], frame);
    postOne(g, TX_DESC, TX_AVAIL, 0x700, FrameHeader.BYTES + frame.len, false);

    n.service(TX_QUEUE, g);

    try testing.expectEqualStrings(frame, n.peekFrame().?);
    try testing.expectEqual(@as(u64, 1), n.frames_out);
    // Transmit buffers are read, never written, so nothing is reported back.
    try testing.expectEqual(@as(?u32, 0), g.read(u32, TX_USED + 8));

    n.dropFrame();
    try testing.expectEqual(@as(?[]const u8, null), n.peekFrame());
}

test "net: a transmit chain with only a header carries no frame" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, TX_QUEUE, 4, TX_DESC, TX_AVAIL, TX_USED);
    try driverUp(&n);
    postOne(g, TX_DESC, TX_AVAIL, 0x700, FrameHeader.BYTES, false);

    n.service(TX_QUEUE, g);
    try testing.expectEqual(@as(?[]const u8, null), n.peekFrame());
    try testing.expectEqual(@as(u64, 0), n.frames_out);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, TX_USED + 2));
}

test "net: frames come back in the order they were sent" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, TX_QUEUE, 4, TX_DESC, TX_AVAIL, TX_USED);
    try driverUp(&n);

    for ([_][]const u8{ "one", "two" }, 0..) |frame, i| {
        @memcpy(ram[0x700 + FrameHeader.BYTES ..][0..frame.len], frame);
        g.write(u64, TX_DESC, 0x700);
        g.write(u32, TX_DESC + 8, @intCast(FrameHeader.BYTES + frame.len));
        g.write(u16, TX_DESC + 12, 0);
        g.write(u16, TX_AVAIL + 4 + @as(u64, i) * 2, 0);
        g.write(u16, TX_AVAIL + 2, @intCast(i + 1));
        n.service(TX_QUEUE, g);
    }

    try testing.expectEqualStrings("one", n.peekFrame().?);
    n.dropFrame();
    try testing.expectEqualStrings("two", n.peekFrame().?);
}

test "net: a full receive queue drops rather than blocking, and says so" {
    var n = VirtioNet{};
    for (0..RX_FRAMES) |_| try testing.expect(n.pushFrame("x"));
    try testing.expect(!n.pushFrame("x"));
    try testing.expectEqual(@as(u64, 1), n.rx.dropped);
}

test "net: a frame longer than the link carries is refused" {
    var n = VirtioNet{};
    const oversize: [MAX_FRAME + 1]u8 = @splat(0);
    try testing.expect(!n.pushFrame(&oversize));
    try testing.expectEqual(@as(u64, 1), n.rx.dropped);
}

test "net: the link state is readable by the guest and raises a change" {
    var n = VirtioNet{};
    try testing.expect(!n.linkUp());
    n.setLinkUp(true);
    try testing.expect(n.linkUp());
    // The address takes the first six bytes, so the state is the word's top half.
    try testing.expectEqual(@as(u64, 1), (try n.load(0x104, 4)) >> 16);
    try testing.expect(n.irqAsserted());
}

test "net: a kick on a queue this device does not have serves nothing" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&n);
    try testing.expect(n.pushFrame("frame"));
    postOne(g, RX_DESC, RX_AVAIL, 0x700, 128, true);

    n.service(9, g);
    try testing.expectEqual(@as(u64, 0), n.frames_in);
}

test "net: a reset clears the rings and keeps the address and the totals" {
    const ram = try testing.allocator.alloc(u8, 0x8000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var n = VirtioNet{};
    try bringUp(&n, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&n);
    try testing.expect(n.pushFrame("frame"));
    postOne(g, RX_DESC, RX_AVAIL, 0x700, 128, true);
    n.service(RX_QUEUE, g);
    const mac = n.config.mac;

    _ = try n.store(0x070, 4, 0);

    try testing.expectEqual(@as(u32, 0), n.transport.queues[RX_QUEUE].num);
    try testing.expectEqual(@as(u64, 1), n.frames_in);
    try testing.expectEqualSlices(u8, &mac, &n.config.mac);
}
