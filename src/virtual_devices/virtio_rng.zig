//! virtio-entropy over the memory-mapped transport: bytes drawn from a stream
//! indexed by (seed, position), both of which are device state.
//!
//! The device answers only when the guest posts a buffer and kicks the queue,
//! so the position depends on what the guest asked for and not on when.

const std = @import("std");
const mmio = @import("virtio_mmio.zig");
const virtqueue = @import("virtqueue.zig");

pub const Guest = virtqueue.Guest;

/// The one queue the spec gives an entropy source. Buffers posted here are
/// device-writable and the device fills them.
const REQUEST_QUEUE = 0;

/// Ring depth offered to the driver. Power of two, as the spec requires.
pub const QUEUE_SIZE: u32 = 8;

/// Bytes one draw of the generator yields. The stream is indexed in bytes and
/// blocked in eights, so what the guest gets depends on how far the stream has
/// run and not on the sizes it asked in.
const BLOCK_BYTES = 8;

pub const VirtioRng = struct {
    pub const MMIO_SIZE = mmio.MMIO_SIZE;

    const Transport = mmio.Transport(.{
        .device_id = 4,
        .num_queues = 1,
        .queue_size = QUEUE_SIZE,
    });

    transport: Transport = .{},

    /// Which stream, and how far into it the guest has read. Only `draw` moves
    /// the position.
    seed: u64 = 0,
    position: u64 = 0,

    /// Bytes handed to the guest. A total for the run, so a reset leaves it.
    bytes_out: u64 = 0,

    /// Read a register. Accesses must be aligned words.
    pub fn load(self: *const VirtioRng, offset: usize, size: usize) !u64 {
        // An entropy source has no configuration space; the window past the
        // transport registers reads as zero rather than faulting.
        if (offset >= mmio.CONFIG_BASE) return 0;
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        return self.transport.load(offset);
    }

    /// Write a register, answering what the device must do next.
    pub fn store(self: *VirtioRng, offset: usize, size: usize, value: u64) !mmio.Action {
        if (offset >= mmio.CONFIG_BASE) return .none;
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        const action = self.transport.store(offset, @truncate(value));
        switch (action) {
            .reset => self.reset(),
            else => {},
        }
        return action;
    }

    /// Start stream `seed` from its beginning. The position resets too, so a
    /// seed names a whole stream rather than a suffix of one.
    pub fn reseed(self: *VirtioRng, seed: u64) void {
        self.seed = seed;
        self.position = 0;
    }

    /// Fill every buffer posted to `queue` since the last kick.
    pub fn service(self: *VirtioRng, queue: u32, g: Guest) void {
        if (queue != REQUEST_QUEUE or !self.transport.driverOk()) return;
        const q = self.transport.queue(REQUEST_QUEUE) orelse return;
        if (!q.live()) return;
        while (q.nextHead(g)) |head| {
            const written = self.fillChain(g, q.*, head);
            self.transport.complete(REQUEST_QUEUE, g, head, written);
        }
    }

    /// True while a completion is unacknowledged.
    pub fn irqAsserted(self: *const VirtioRng) bool {
        return self.transport.irqAsserted();
    }

    /// Fill a chain's device-writable descriptors; returns bytes written.
    fn fillChain(self: *VirtioRng, g: Guest, q: virtqueue.Queue, head: u16) u32 {
        var total: u32 = 0;
        var c = q.chain(g, head);
        while (c.next()) |d| {
            // Readable descriptor on the request queue: the driver's mistake.
            // Skipped rather than filled, so the position counts only bytes the
            // guest can have read.
            if (!d.flags.write) continue;
            const buf = g.slice(d.addr, d.len) orelse continue;
            self.draw(buf);
            total += @intCast(buf.len);
        }
        return total;
    }

    /// Take the next `dst.len` bytes of the stream. The only place the position
    /// moves.
    fn draw(self: *VirtioRng, dst: []u8) void {
        for (dst) |*out| {
            out.* = byteAt(self.seed, self.position);
            self.position += 1;
            self.bytes_out += 1;
        }
    }

    /// Give up the rings and keep the stream, so a reloaded driver continues
    /// rather than re-reading bytes the guest has already had.
    fn reset(self: *VirtioRng) void {
        const seed = self.seed;
        const position = self.position;
        const out = self.bytes_out;
        self.* = .{};
        self.seed = seed;
        self.position = position;
        self.bytes_out = out;
    }
};

/// The `i`th byte of `seed`'s stream, computed from `i` rather than iterated to,
/// so a position can be resumed without replaying the bytes before it.
///
/// SplitMix64's finalizer over the block index: a permutation, so distinct
/// blocks give distinct states.
fn byteAt(seed: u64, i: u64) u8 {
    var z = seed +% (i / BLOCK_BYTES +% 1) *% 0x9E37_79B9_7F4A_7C15;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    z = z ^ (z >> 31);
    return @truncate(z >> @intCast((i % BLOCK_BYTES) * 8));
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const BASE: u64 = 0;

/// Bring the request queue up the way a driver does.
fn bringUp(v: *VirtioRng, num: u32) !void {
    _ = try v.store(0x030, 4, REQUEST_QUEUE);
    _ = try v.store(0x038, 4, num);
    _ = try v.store(0x080, 4, 0x1000);
    _ = try v.store(0x090, 4, 0x2000);
    _ = try v.store(0x0a0, 4, 0x3000);
    _ = try v.store(0x044, 4, 1);
    _ = try v.store(0x070, 4, (mmio.Status{
        .acknowledge = true,
        .driver = true,
        .features_ok = true,
        .driver_ok = true,
    }).toBits());
}

/// Post one device-writable buffer of `len` bytes at `addr` as chain `n`.
fn post(g: Guest, n: u16, addr: u64, len: u32, write: bool) void {
    const d = 0x1000 + @as(u64, n) * virtqueue.DESC_BYTES;
    g.write(u64, d, addr);
    g.write(u32, d + 8, len);
    g.write(u16, d + 12, @bitCast(virtqueue.DescFlags{ .write = write }));
    g.write(u16, 0x2004 + @as(u64, n) * 2, n);
    g.write(u16, 0x2002, n + 1);
}

test "rng: identifies as a modern virtio entropy source" {
    var v = VirtioRng{};
    try testing.expectEqual(@as(u64, mmio.MAGIC), try v.load(0x000, 4));
    try testing.expectEqual(@as(u64, 2), try v.load(0x004, 4));
    try testing.expectEqual(@as(u64, 4), try v.load(0x008, 4)); // entropy source
    try testing.expectEqual(@as(u64, QUEUE_SIZE), try v.load(0x034, 4));
    // No configuration space.
    try testing.expectEqual(@as(u64, 0), try v.load(0x100, 4));
}

test "rng: an unaligned or wrong-width access is refused" {
    var v = VirtioRng{};
    try testing.expectError(error.AccessFault, v.load(0x002, 4));
    try testing.expectError(error.AccessFault, v.load(0x000, 8));
    try testing.expectError(error.AccessFault, v.store(0x070, 2, 0));
}

test "rng: a posted buffer is filled from the seed's stream and completed once" {
    var ram: [0x4000]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioRng{};
    v.reseed(42);
    try bringUp(&v, 4);
    post(g, 0, 0x800, 16, true);

    v.service(REQUEST_QUEUE, g);

    for (ram[0x800..0x810], 0..) |b, i| try testing.expectEqual(byteAt(42, i), b);
    try testing.expectEqual(@as(u64, 16), v.position);
    try testing.expectEqual(@as(u64, 16), v.bytes_out);
    try testing.expect(v.irqAsserted());
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
    try testing.expectEqual(@as(?u32, 16), g.read(u32, 0x3008));

    // Nothing newly posted: a second kick must not draw again.
    v.service(REQUEST_QUEUE, g);
    try testing.expectEqual(@as(u64, 16), v.position);
}

test "rng: the stream does not depend on how the guest chunks its requests" {
    var whole: [0x4000]u8 = @splat(0);
    var split: [0x4000]u8 = @splat(0);

    var a = VirtioRng{};
    a.reseed(7);
    try bringUp(&a, 4);
    const ga = Guest{ .memory = &whole, .base = BASE };
    post(ga, 0, 0x800, 24, true);
    a.service(REQUEST_QUEUE, ga);

    var b = VirtioRng{};
    b.reseed(7);
    try bringUp(&b, 4);
    const gb = Guest{ .memory = &split, .base = BASE };
    post(gb, 0, 0x800, 8, true);
    b.service(REQUEST_QUEUE, gb);
    post(gb, 1, 0x808, 16, true);
    b.service(REQUEST_QUEUE, gb);

    try testing.expectEqualSlices(u8, whole[0x800..0x818], split[0x800..0x818]);
    try testing.expectEqual(a.position, b.position);
}

test "rng: a new seed starts a new stream, and the same seed repeats one" {
    var first: [0x4000]u8 = @splat(0);
    var again: [0x4000]u8 = @splat(0);
    var other: [0x4000]u8 = @splat(0);

    for ([_]struct { ram: *[0x4000]u8, seed: u64 }{
        .{ .ram = &first, .seed = 1 },
        .{ .ram = &again, .seed = 1 },
        .{ .ram = &other, .seed = 2 },
    }) |run| {
        var v = VirtioRng{};
        v.reseed(run.seed);
        try bringUp(&v, 4);
        const g = Guest{ .memory = run.ram, .base = BASE };
        post(g, 0, 0x800, 16, true);
        v.service(REQUEST_QUEUE, g);
    }

    try testing.expectEqualSlices(u8, first[0x800..0x810], again[0x800..0x810]);
    try testing.expect(!std.mem.eql(u8, first[0x800..0x810], other[0x800..0x810]));
}

test "rng: a device reset gives up the rings but does not rewind the stream" {
    var ram: [0x4000]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioRng{};
    v.reseed(3);
    try bringUp(&v, 4);
    post(g, 0, 0x800, 8, true);
    v.service(REQUEST_QUEUE, g);

    _ = try v.store(0x070, 4, 0);

    try testing.expectEqual(@as(u32, 0), v.transport.queues[0].num);
    try testing.expectEqual(@as(u64, 3), v.seed);
    try testing.expectEqual(@as(u64, 8), v.position);
    try testing.expectEqual(@as(u64, 8), v.bytes_out);
}

test "rng: nothing is filled before the driver is up" {
    var ram: [0x4000]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioRng{};
    try bringUp(&v, 4);
    _ = try v.store(0x070, 4, (mmio.Status{ .acknowledge = true, .driver = true }).toBits());
    post(g, 0, 0x800, 8, true);

    v.service(REQUEST_QUEUE, g);
    try testing.expectEqual(@as(u64, 0), v.position);
    try testing.expectEqual(@as(u8, 0), ram[0x800]);
}

test "rng: a readable descriptor on the request queue is skipped, not filled" {
    var ram: [0x4000]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioRng{};
    try bringUp(&v, 4);
    post(g, 0, 0x800, 8, false); // misfiled: readable, not writable

    v.service(REQUEST_QUEUE, g);
    try testing.expectEqual(@as(u8, 0), ram[0x800]);
    try testing.expectEqual(@as(u64, 0), v.position);
    // Completed with length 0 so the ring still advances and cannot wedge.
    try testing.expectEqual(@as(?u16, 1), g.read(u16, 0x3002));
}

test "rng: a kick on a queue this device does not have fills nothing" {
    var ram: [0x4000]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioRng{};
    try bringUp(&v, 4);
    post(g, 0, 0x800, 8, true);

    v.service(1, g);
    try testing.expectEqual(@as(u64, 0), v.position);
}

test "rng: the byte at a position does not depend on drawing the ones before" {
    var direct: [24]u8 = @splat(0);
    for (&direct, 0..) |*b, i| b.* = byteAt(9, i);

    var v = VirtioRng{};
    v.reseed(9);
    var drawn: [24]u8 = @splat(0);
    v.draw(drawn[0..5]); // an offset that is not a block boundary
    v.draw(drawn[5..24]);

    try testing.expectEqualSlices(u8, &direct, &drawn);
}
