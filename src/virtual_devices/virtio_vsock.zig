//! virtio-vsock over the memory-mapped transport: packets between a guest and
//! whoever owns the device, addressed by context id and port rather than by an
//! address a network assigns.
//!
//! This model carries whole packets, header included. The stream protocol they
//! describe — connection setup, credit, shutdown — belongs to whoever is on the
//! other end.

const std = @import("std");
const mmio = @import("virtio_mmio.zig");
const virtqueue = @import("virtqueue.zig");
const packet_fifo = @import("packet_fifo.zig");

pub const Guest = virtqueue.Guest;

/// Context id every guest reserves for the host it is running on.
pub const HOST_CID: u64 = 2;

/// `struct virtio_vsock_config`.
const Config = extern struct {
    /// Which guest this is, as both ends address it.
    guest_cid: u64 = 3,
};

/// `struct virtio_vsock_hdr`, in front of every packet in either direction.
pub const PacketHeader = extern struct {
    src_cid: u64 = 0,
    dst_cid: u64 = 0,
    src_port: u32 = 0,
    dst_port: u32 = 0,
    len: u32 = 0,
    type: u16 = 0,
    op: u16 = 0,
    flags: u32 = 0,
    buf_alloc: u32 = 0,
    fwd_cnt: u32 = 0,

    pub const BYTES = 44;
};

/// Queue indices fixed by the spec.
const RX_QUEUE = 0;
const TX_QUEUE = 1;
const EVENT_QUEUE = 2;
const NUM_QUEUES = 3;

/// Ring depth offered to the driver. Power of two, as the spec requires.
pub const QUEUE_SIZE: u32 = 64;

/// Longest packet carried, header included.
pub const MAX_PACKET = PacketHeader.BYTES + 4096;

/// Packets each direction holds before it drops. An owner that takes what it is
/// given whenever the guest exits never fills them.
const RX_PACKETS = 8;
const TX_PACKETS = 8;

/// The only event this device raises: the other end went away, and every
/// connection with it.
pub const EVENT_TRANSPORT_RESET: u32 = 0;

pub const VirtioVsock = struct {
    pub const MMIO_SIZE = mmio.MMIO_SIZE;

    const Transport = mmio.Transport(.{
        .device_id = 19,
        .num_queues = NUM_QUEUES,
        .queue_size = QUEUE_SIZE,
    });

    transport: Transport = .{},
    config: Config = .{},

    /// Packets waiting for the guest to post a buffer.
    rx: packet_fifo.Fifo(RX_PACKETS, MAX_PACKET) = .{},
    /// Packets the guest has sent, waiting for the owner to take them.
    tx: packet_fifo.Fifo(TX_PACKETS, MAX_PACKET) = .{},

    /// Packets handed over in each direction.
    packets_in: u64 = 0,
    packets_out: u64 = 0,

    /// A transport reset the guest has not been told about yet.
    reset_pending: bool = false,

    /// Read a register. Accesses must be aligned words.
    pub fn load(self: *const VirtioVsock, offset: usize, size: usize) !u64 {
        if (offset >= mmio.CONFIG_BASE) {
            return mmio.configRead(std.mem.asBytes(&self.config), offset - mmio.CONFIG_BASE, size);
        }
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        return self.transport.load(offset);
    }

    /// Write a register, answering what the device must do next.
    pub fn store(self: *VirtioVsock, offset: usize, size: usize, value: u64) !mmio.Action {
        if (offset >= mmio.CONFIG_BASE) return .none; // configuration is read-only
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        const action = self.transport.store(offset, @truncate(value));
        switch (action) {
            .reset => self.reset(),
            else => {},
        }
        return action;
    }

    /// Which guest this is, as packets address it.
    pub fn guestCid(self: *const VirtioVsock) u64 {
        return self.config.guest_cid;
    }

    /// Set the context id. Before the driver comes up: a guest reads it once.
    pub fn setGuestCid(self: *VirtioVsock, cid: u64) void {
        self.config.guest_cid = cid;
    }

    /// Queue a packet for the guest, header included; false when the queue was
    /// full and it was dropped.
    pub fn pushPacket(self: *VirtioVsock, packet: []const u8) bool {
        return self.rx.push(packet);
    }

    /// The oldest packet the guest has sent, header included, or null when it
    /// has sent none. Valid until the next call that changes this device.
    pub fn peekPacket(self: *const VirtioVsock) ?[]const u8 {
        return self.tx.peek();
    }

    /// Drop the packet `peekPacket` answered, once it has been dealt with.
    pub fn dropPacket(self: *VirtioVsock) void {
        self.tx.pop();
    }

    /// Read a packet's header, or null when it is too short to have one.
    pub fn headerOf(packet: []const u8) ?PacketHeader {
        if (packet.len < PacketHeader.BYTES) return null;
        var h: PacketHeader = .{};
        @memcpy(std.mem.asBytes(&h)[0..PacketHeader.BYTES], packet[0..PacketHeader.BYTES]);
        return h;
    }

    /// Tell the guest every connection it had is gone. Delivered on the event
    /// queue as soon as the driver has posted a buffer for one.
    pub fn resetTransport(self: *VirtioVsock) void {
        self.reset_pending = true;
    }

    /// Serve the chains posted to `queue`.
    pub fn service(self: *VirtioVsock, queue: u32, g: Guest) void {
        switch (queue) {
            RX_QUEUE => self.serviceRx(g),
            TX_QUEUE => self.serviceTx(g),
            EVENT_QUEUE => self.serviceEvent(g),
            else => {},
        }
    }

    /// Hand queued packets to the guest, and any event waiting with them.
    pub fn serviceRx(self: *VirtioVsock, g: Guest) void {
        if (!self.transport.driverOk()) return;
        const q = self.transport.queue(RX_QUEUE) orelse return;
        if (!q.live()) return;
        while (self.rx.peek()) |packet| {
            const head = q.nextHead(g) orelse return;
            const written = fill(g, q.*, head, packet);
            // A buffer too small still completes, or the queue is retried
            // forever against a packet that can never fit.
            self.rx.pop();
            if (written != 0) self.packets_in += 1;
            self.transport.complete(RX_QUEUE, g, head, written);
        }
    }

    /// True while a completion is unacknowledged.
    pub fn irqAsserted(self: *const VirtioVsock) bool {
        return self.transport.irqAsserted();
    }

    fn serviceTx(self: *VirtioVsock, g: Guest) void {
        if (!self.transport.driverOk()) return;
        const q = self.transport.queue(TX_QUEUE) orelse return;
        if (!q.live()) return;
        while (q.nextHead(g)) |head| {
            if (self.collect(g, q.*, head)) self.packets_out += 1;
            // Transmit buffers are driver-readable, so nothing is written back.
            self.transport.complete(TX_QUEUE, g, head, 0);
        }
    }

    fn serviceEvent(self: *VirtioVsock, g: Guest) void {
        if (!self.transport.driverOk() or !self.reset_pending) return;
        const q = self.transport.queue(EVENT_QUEUE) orelse return;
        if (!q.live()) return;
        const head = q.nextHead(g) orelse return;
        var event: [4]u8 = undefined;
        std.mem.writeInt(u32, &event, EVENT_TRANSPORT_RESET, .little);
        const written = fill(g, q.*, head, &event);
        if (written == 0) return;
        self.reset_pending = false;
        self.transport.complete(EVENT_QUEUE, g, head, written);
    }

    /// Write `msg` across a chain's writable descriptors; returns the bytes
    /// written, or zero when the chain has no room for all of it.
    fn fill(g: Guest, q: virtqueue.Queue, head: u16, msg: []const u8) u32 {
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
        if (room < msg.len) return 0;

        var left = msg;
        for (buffers[0..n]) |buf| {
            if (left.len == 0) break;
            const take = @min(buf.len, left.len);
            @memcpy(buf[0..take], left[0..take]);
            left = left[take..];
        }
        return @intCast(msg.len);
    }

    /// Take one packet out of a chain's readable descriptors. False when the
    /// chain is too short to hold a header.
    fn collect(self: *VirtioVsock, g: Guest, q: virtqueue.Queue, head: u16) bool {
        var staged: [MAX_PACKET]u8 = undefined;
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
        if (have < PacketHeader.BYTES) return false;
        return self.tx.push(staged[0..have]);
    }

    fn reset(self: *VirtioVsock) void {
        // The address and the totals describe the machine, not the driver's
        // incarnation of it; packets in flight went with the rings.
        const config = self.config;
        const in = self.packets_in;
        const out = self.packets_out;
        self.* = .{};
        self.config = config;
        self.packets_in = in;
        self.packets_out = out;
    }
};

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const BASE: u64 = 0;
const RX_DESC: u64 = 0x1000;
const RX_AVAIL: u64 = 0x2000;
const RX_USED: u64 = 0x3000;
const TX_DESC: u64 = 0x4000;
const TX_AVAIL: u64 = 0x5000;
const TX_USED: u64 = 0x6000;
const EV_DESC: u64 = 0x7000;
const EV_AVAIL: u64 = 0x8000;
const EV_USED: u64 = 0x9000;

/// Bring a queue up the way a driver does.
fn bringUp(v: *VirtioVsock, queue: u32, num: u32, desc: u32, avail: u32, used: u32) !void {
    _ = try v.store(0x030, 4, queue);
    _ = try v.store(0x038, 4, num);
    _ = try v.store(0x080, 4, desc);
    _ = try v.store(0x090, 4, avail);
    _ = try v.store(0x0a0, 4, used);
    _ = try v.store(0x044, 4, 1);
}

fn driverUp(v: *VirtioVsock) !void {
    _ = try v.store(0x070, 4, (mmio.Status{
        .acknowledge = true,
        .driver = true,
        .features_ok = true,
        .driver_ok = true,
    }).toBits());
}

fn postOne(g: Guest, desc: u64, avail: u64, addr: u64, len: u32, write: bool) void {
    g.write(u64, desc, addr);
    g.write(u32, desc + 8, len);
    g.write(u16, desc + 12, @bitCast(virtqueue.DescFlags{ .write = write }));
    g.write(u16, avail + 4, 0);
    g.write(u16, avail + 2, 1);
}

/// A packet with a header naming its ports and a payload after it.
fn packetOf(buf: []u8, src_port: u32, dst_port: u32, payload: []const u8) []u8 {
    const h = PacketHeader{
        .src_cid = 3,
        .dst_cid = HOST_CID,
        .src_port = src_port,
        .dst_port = dst_port,
        .len = @intCast(payload.len),
    };
    @memcpy(buf[0..PacketHeader.BYTES], std.mem.asBytes(&h)[0..PacketHeader.BYTES]);
    @memcpy(buf[PacketHeader.BYTES..][0..payload.len], payload);
    return buf[0 .. PacketHeader.BYTES + payload.len];
}

test "vsock: identifies as a modern virtio socket device" {
    var v = VirtioVsock{};
    try testing.expectEqual(@as(u64, mmio.MAGIC), try v.load(0x000, 4));
    try testing.expectEqual(@as(u64, 2), try v.load(0x004, 4));
    try testing.expectEqual(@as(u64, 19), try v.load(0x008, 4)); // socket
    try testing.expectEqual(@as(u64, QUEUE_SIZE), try v.load(0x034, 4));
}

test "vsock: the context id reads out of configuration space, and is read-only" {
    var v = VirtioVsock{};
    v.setGuestCid(42);
    try testing.expectEqual(@as(u64, 42), try v.load(0x100, 4));
    try testing.expectEqual(@as(u64, 0), try v.load(0x104, 4));
    _ = try v.store(0x100, 4, 7);
    try testing.expectEqual(@as(u64, 42), v.guestCid());
}

test "vsock: an unaligned or non-word access faults" {
    var v = VirtioVsock{};
    try testing.expectError(error.AccessFault, v.load(0x002, 4));
    try testing.expectError(error.AccessFault, v.load(0x000, 2));
    try testing.expectError(error.AccessFault, v.store(0x070, 1, 0));
}

test "vsock: a pushed packet fills a posted buffer whole" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    try bringUp(&v, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&v);

    var buf: [MAX_PACKET]u8 = undefined;
    const packet = packetOf(&buf, 1024, 5000, "hello");
    try testing.expect(v.pushPacket(packet));
    postOne(g, RX_DESC, RX_AVAIL, 0xa000, 256, true);
    v.service(RX_QUEUE, g);

    try testing.expectEqualStrings("hello", ram[0xa000 + PacketHeader.BYTES ..][0..5]);
    const got = VirtioVsock.headerOf(ram[0xa000..][0..PacketHeader.BYTES]).?;
    try testing.expectEqual(@as(u32, 5000), got.dst_port);
    try testing.expectEqual(@as(u64, 1), v.packets_in);
    try testing.expectEqual(@as(?u32, @intCast(packet.len)), g.read(u32, RX_USED + 8));
}

test "vsock: a packet arriving before the driver is up waits" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    try bringUp(&v, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    var buf: [MAX_PACKET]u8 = undefined;
    try testing.expect(v.pushPacket(packetOf(&buf, 1, 2, "x")));
    postOne(g, RX_DESC, RX_AVAIL, 0xa000, 256, true);

    v.service(RX_QUEUE, g);
    try testing.expectEqual(@as(u64, 0), v.packets_in);

    try driverUp(&v);
    v.service(RX_QUEUE, g);
    try testing.expectEqual(@as(u64, 1), v.packets_in);
}

test "vsock: a buffer too small for the packet completes empty and drops it" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    try bringUp(&v, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&v);
    var buf: [MAX_PACKET]u8 = undefined;
    try testing.expect(v.pushPacket(packetOf(&buf, 1, 2, "payload")));
    postOne(g, RX_DESC, RX_AVAIL, 0xa000, 8, true);

    v.service(RX_QUEUE, g);
    try testing.expectEqual(@as(u64, 0), v.packets_in);
    try testing.expectEqual(@as(?u32, 0), g.read(u32, RX_USED + 8));
    try testing.expectEqual(@as(?u16, 1), g.read(u16, RX_USED + 2));
}

test "vsock: a transmitted chain becomes a packet the owner can take" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    try bringUp(&v, TX_QUEUE, 4, TX_DESC, TX_AVAIL, TX_USED);
    try driverUp(&v);

    var buf: [MAX_PACKET]u8 = undefined;
    const packet = packetOf(&buf, 1024, 5000, "outbound");
    @memcpy(ram[0xa000..][0..packet.len], packet);
    postOne(g, TX_DESC, TX_AVAIL, 0xa000, @intCast(packet.len), false);

    v.service(TX_QUEUE, g);

    const got = v.peekPacket().?;
    try testing.expectEqualStrings("outbound", got[PacketHeader.BYTES..]);
    try testing.expectEqual(@as(u32, 1024), VirtioVsock.headerOf(got).?.src_port);
    try testing.expectEqual(@as(u64, 1), v.packets_out);

    v.dropPacket();
    try testing.expectEqual(@as(?[]const u8, null), v.peekPacket());
}

test "vsock: a chain too short to hold a header carries no packet" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    try bringUp(&v, TX_QUEUE, 4, TX_DESC, TX_AVAIL, TX_USED);
    try driverUp(&v);
    postOne(g, TX_DESC, TX_AVAIL, 0xa000, PacketHeader.BYTES - 1, false);

    v.service(TX_QUEUE, g);
    try testing.expectEqual(@as(?[]const u8, null), v.peekPacket());
    try testing.expectEqual(@as(?u16, 1), g.read(u16, TX_USED + 2));
}

test "vsock: a transport reset reaches the guest on the event queue, once" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    try bringUp(&v, EVENT_QUEUE, 4, EV_DESC, EV_AVAIL, EV_USED);
    try driverUp(&v);
    postOne(g, EV_DESC, EV_AVAIL, 0xa000, 4, true);

    // Nothing to report yet.
    v.service(EVENT_QUEUE, g);
    try testing.expectEqual(@as(?u16, 0), g.read(u16, EV_USED + 2));

    v.resetTransport();
    v.service(EVENT_QUEUE, g);
    try testing.expectEqual(@as(?u32, EVENT_TRANSPORT_RESET), g.read(u32, 0xa000));
    try testing.expectEqual(@as(?u16, 1), g.read(u16, EV_USED + 2));

    // Reported once, not on every pass.
    v.service(EVENT_QUEUE, g);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, EV_USED + 2));
}

test "vsock: a reset waiting for a buffer is delivered when one is posted" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    try bringUp(&v, EVENT_QUEUE, 4, EV_DESC, EV_AVAIL, EV_USED);
    try driverUp(&v);
    v.resetTransport();
    v.service(EVENT_QUEUE, g); // no buffer posted, so it waits

    postOne(g, EV_DESC, EV_AVAIL, 0xa000, 4, true);
    v.service(EVENT_QUEUE, g);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, EV_USED + 2));
}

test "vsock: a kick on a queue this device does not have serves nothing" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    try bringUp(&v, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&v);
    var buf: [MAX_PACKET]u8 = undefined;
    try testing.expect(v.pushPacket(packetOf(&buf, 1, 2, "x")));
    postOne(g, RX_DESC, RX_AVAIL, 0xa000, 256, true);

    v.service(9, g);
    try testing.expectEqual(@as(u64, 0), v.packets_in);
}

test "vsock: a reset clears the rings and keeps the address and the totals" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var v = VirtioVsock{};
    v.setGuestCid(9);
    try bringUp(&v, RX_QUEUE, 4, RX_DESC, RX_AVAIL, RX_USED);
    try driverUp(&v);
    var buf: [MAX_PACKET]u8 = undefined;
    try testing.expect(v.pushPacket(packetOf(&buf, 1, 2, "x")));
    postOne(g, RX_DESC, RX_AVAIL, 0xa000, 256, true);
    v.service(RX_QUEUE, g);

    _ = try v.store(0x070, 4, 0);

    try testing.expectEqual(@as(u32, 0), v.transport.queues[RX_QUEUE].num);
    try testing.expectEqual(@as(u64, 9), v.guestCid());
    try testing.expectEqual(@as(u64, 1), v.packets_in);
}
