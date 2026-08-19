//! virtio-blk over the memory-mapped transport: a disk image in host memory,
//! read and written by descriptor chains.
//!
//! A request chain is a readable header, zero or more data descriptors, and a
//! one-byte writable status. The image is a slice the owner supplies, so this
//! model performs no I/O of its own.
//!
//! Writes land in a volatile cache and reach the image on a flush. `powerCut`
//! discards what no flush claimed, leaving the image as a machine that lost
//! power would.

const std = @import("std");
const mmio = @import("virtio_mmio.zig");
const virtqueue = @import("virtqueue.zig");

pub const Guest = virtqueue.Guest;

/// Sector size the request header's sector number counts in.
pub const SECTOR_BYTES = 512;

/// `struct virtio_blk_req` header, ahead of the data in every chain.
const Header = struct {
    type: u32,
    reserved: u32,
    sector: u64,

    const BYTES = 16;
};

/// Request types this model serves.
const RequestType = enum(u32) {
    in = 0,
    out = 1,
    flush = 4,
    _,
};

/// The status byte a request completes with.
pub const Status = enum(u8) {
    ok = 0,
    io_error = 1,
    unsupported = 2,
};

/// VIRTIO_BLK_F_FLUSH: the device has a write cache and honours flush requests.
pub const F_FLUSH: u6 = 9;

/// The one queue a block device without multiqueue offers.
const REQUEST_QUEUE = 0;

/// Longest chain this model walks: the ring is this deep, so no valid chain is.
const MAX_DESCRIPTORS = 8;

/// Writes the cache holds before it must put some on the image.
const CACHE_ENTRIES = 64;

/// Bytes the cache stages. A real write cache is bounded too, and writes past
/// its depth reach the platter before any flush asks them to.
const CACHE_BYTES = 64 * 1024;

/// A write the driver has been told completed, still only in the cache.
pub const Pending = struct {
    sector: u64 = 0,
    len: u32 = 0,
    /// Where its bytes are staged.
    at: u32 = 0,
};

pub const VirtioBlk = struct {
    pub const MMIO_SIZE = mmio.MMIO_SIZE;

    const Transport = mmio.Transport(.{
        .device_id = 2,
        .num_queues = 1,
        .queue_size = MAX_DESCRIPTORS,
        .features = @as(u64, 1) << F_FLUSH,
    });

    transport: Transport = .{},
    /// The disk image, borrowed from the owner.
    disk: []u8 = &.{},

    /// Staged writes, oldest first, and the bytes behind them.
    cached: [CACHE_ENTRIES]Pending = @splat(.{}),
    cached_count: u32 = 0,
    staging: [CACHE_BYTES]u8 = @splat(0),
    staged: u32 = 0,

    /// Read a register. Accesses must be aligned words.
    pub fn load(self: *const VirtioBlk, offset: usize, size: usize) !u64 {
        if (offset >= mmio.CONFIG_BASE) {
            // `struct virtio_blk_config`: capacity in sectors, and nothing
            // else, since no feature that adds a field is offered.
            var config: [8]u8 = undefined;
            std.mem.writeInt(u64, &config, self.disk.len / SECTOR_BYTES, .little);
            return mmio.configRead(&config, offset - mmio.CONFIG_BASE, size);
        }
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        return self.transport.load(offset);
    }

    /// Write a register, answering what the device must do next.
    pub fn store(self: *VirtioBlk, offset: usize, size: usize, value: u64) !mmio.Action {
        if (offset >= mmio.CONFIG_BASE) return .none; // configuration is read-only
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        const action = self.transport.store(offset, @truncate(value));
        switch (action) {
            .reset => self.reset(),
            else => {},
        }
        return action;
    }

    /// Serve every chain the driver has posted to `queue`.
    pub fn service(self: *VirtioBlk, queue: u32, g: Guest) void {
        if (queue != REQUEST_QUEUE or !self.transport.driverOk()) return;
        const q = self.transport.queue(REQUEST_QUEUE) orelse return;
        if (!q.live()) return;
        while (q.nextHead(g)) |head| {
            const written = self.serve(g, q.*, head);
            self.transport.complete(REQUEST_QUEUE, g, head, written);
        }
    }

    /// Writes the driver believes completed that are not on the image yet,
    /// oldest first.
    pub fn pending(self: *const VirtioBlk) []const Pending {
        return self.cached[0..self.cached_count];
    }

    /// Discard the write cache, putting the first `n` of its writes on the
    /// image first. Everything a flush already claimed is unaffected.
    pub fn powerCut(self: *VirtioBlk, n: usize) void {
        for (self.cached[0..@min(n, self.cached_count)]) |e| self.putOnDisk(e);
        self.cached_count = 0;
        self.staged = 0;
    }

    /// True while a completion is unacknowledged.
    pub fn irqAsserted(self: *const VirtioBlk) bool {
        return self.transport.irqAsserted();
    }

    /// Fold this device's state into a digest.
    pub fn hash(self: *const VirtioBlk, h: *std.hash.Wyhash) void {
        h.update(std.mem.asBytes(&self.transport.status));
        h.update(std.mem.asBytes(&self.transport.device_features_sel));
        h.update(std.mem.asBytes(&self.transport.driver_features_sel));
        h.update(std.mem.asBytes(&self.transport.driver_features));
        h.update(std.mem.asBytes(&self.transport.queue_sel));
        h.update(std.mem.asBytes(&self.transport.interrupt_status));
        for (&self.transport.queues) |*q| {
            h.update(std.mem.asBytes(&q.num));
            h.update(std.mem.asBytes(&q.ready));
            h.update(std.mem.asBytes(&q.desc));
            h.update(std.mem.asBytes(&q.avail));
            h.update(std.mem.asBytes(&q.used));
            h.update(std.mem.asBytes(&q.last_avail));
            h.update(std.mem.asBytes(&q.used_idx));
        }
        h.update(std.mem.asBytes(&self.cached_count));
        h.update(std.mem.asBytes(&self.staged));
        for (self.pending()) |e| {
            h.update(std.mem.asBytes(&e.sector));
            h.update(std.mem.asBytes(&e.len));
            h.update(std.mem.asBytes(&e.at));
        }
        h.update(self.staging[0..self.staged]);
        h.update(self.disk);
    }

    /// The image survives, the cache does not: staged writes carried across a
    /// reset would reach the image under a driver that never asked for them.
    fn reset(self: *VirtioBlk) void {
        const disk = self.disk;
        self.* = .{};
        self.disk = disk;
    }

    /// Serve one chain; returns the length to report in the used ring. A chain
    /// this model cannot parse completes with length zero and no status byte.
    fn serve(self: *VirtioBlk, g: Guest, q: virtqueue.Queue, head: u16) u32 {
        var descs: [MAX_DESCRIPTORS]virtqueue.Descriptor = undefined;
        var n: usize = 0;
        var c = q.chain(g, head);
        while (c.next()) |d| : (n += 1) {
            if (n == descs.len) return 0;
            descs[n] = d;
        }
        // At least a header and a status; a flush carries nothing between them.
        if (n < 2) return 0;

        const req = readHeader(g, descs[0]) orelse return 0;
        const written = self.perform(g, req, descs[1 .. n - 1]) orelse return 0;

        const status = g.slice(descs[n - 1].addr, 1) orelse return 0;
        status[0] = @intFromEnum(Status.ok);
        // The status byte counts toward what the device wrote.
        return written + 1;
    }

    /// Carry out a request; returns the bytes written into the guest's buffers,
    /// or null when the request cannot be served at all.
    fn perform(
        self: *VirtioBlk,
        g: Guest,
        req: Header,
        data: []const virtqueue.Descriptor,
    ) ?u32 {
        const kind: RequestType = @enumFromInt(req.type);
        switch (kind) {
            .flush => {
                if (data.len != 0) return null;
                self.commitAll();
                return 0;
            },
            .in, .out => if (data.len == 0) return null,
            else => return null,
        }

        var total: u32 = 0;
        for (data) |d| total = std.math.add(u32, total, d.len) catch return null;
        const from = std.math.mul(u64, req.sector, SECTOR_BYTES) catch return null;
        const to = std.math.add(u64, from, total) catch return null;
        if (to > self.disk.len) return null;

        // Resolved up front, so a request is served whole or not at all.
        var buffers: [MAX_DESCRIPTORS][]u8 = undefined;
        for (data, 0..) |d, i| buffers[i] = g.slice(d.addr, d.len) orelse return null;

        var at = from;
        for (buffers[0..data.len]) |buf| {
            switch (kind) {
                .in => self.readInto(at, buf),
                else => self.write(at, buf),
            }
            at += buf.len;
        }
        // A read fills the guest's buffers; a write only writes the status byte.
        return if (kind == .in) total else 0;
    }

    /// Read into `dst` from offset `at`, through the cache, so a write the
    /// driver was told completed reads back before it is flushed.
    fn readInto(self: *const VirtioBlk, at: u64, dst: []u8) void {
        @memcpy(dst, self.disk[@intCast(at)..][0..dst.len]);
        for (self.pending()) |e| {
            const start = e.sector * SECTOR_BYTES;
            const overlap_at = @max(start, at);
            const overlap_to = @min(start + e.len, at + dst.len);
            if (overlap_at >= overlap_to) continue;
            const len: usize = @intCast(overlap_to - overlap_at);
            const from: usize = @intCast(overlap_at - start);
            @memcpy(dst[@intCast(overlap_at - at)..][0..len], self.staging[e.at + from ..][0..len]);
        }
    }

    /// Take a write into the cache, or straight to the image when the driver
    /// never accepted a flush to get it out again.
    fn write(self: *VirtioBlk, at: u64, src: []const u8) void {
        if (!self.transport.negotiated(F_FLUSH) or src.len > CACHE_BYTES) {
            self.commitAll();
            @memcpy(self.disk[@intCast(at)..][0..src.len], src);
            return;
        }
        if (self.cached_count == CACHE_ENTRIES or self.staged + src.len > CACHE_BYTES) {
            self.commitAll();
        }
        @memcpy(self.staging[self.staged..][0..src.len], src);
        self.cached[self.cached_count] = .{
            .sector = at / SECTOR_BYTES,
            .len = @intCast(src.len),
            .at = self.staged,
        };
        self.cached_count += 1;
        self.staged += @intCast(src.len);
    }

    /// Put every staged write on the image, oldest first.
    fn commitAll(self: *VirtioBlk) void {
        for (self.pending()) |e| self.putOnDisk(e);
        self.cached_count = 0;
        self.staged = 0;
    }

    fn putOnDisk(self: *VirtioBlk, e: Pending) void {
        const at = e.sector * SECTOR_BYTES;
        if (at + e.len > self.disk.len) return;
        @memcpy(self.disk[@intCast(at)..][0..e.len], self.staging[e.at..][0..e.len]);
    }
};

/// Parse a request header, or null when its descriptor cannot hold one.
fn readHeader(g: Guest, desc: virtqueue.Descriptor) ?Header {
    if (desc.len < Header.BYTES) return null;
    return .{
        .type = g.read(u32, desc.addr) orelse return null,
        .reserved = g.read(u32, desc.addr + 4) orelse return null,
        .sector = g.read(u64, desc.addr + 8) orelse return null,
    };
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const BASE: u64 = 0x8000_0000;
const DESC_AT: u64 = BASE + 0x1000;
const AVAIL_AT: u64 = BASE + 0x2000;
const USED_AT: u64 = BASE + 0x3000;
const HEADER_AT: u64 = BASE + 0x400;
const DATA_AT: u64 = BASE + 0x800;
const STATUS_AT: u64 = BASE + 0xc00;

/// Bring the request queue up the way a driver that accepts flush does.
fn bringUp(v: *VirtioBlk, num: u32) !void {
    _ = try v.store(0x024, 4, 0);
    _ = try v.store(0x020, 4, @as(u64, 1) << F_FLUSH);
    try bringUpNoFlush(v, num);
}

/// The same, for a driver that took no feature the device offered.
fn bringUpNoFlush(v: *VirtioBlk, num: u32) !void {
    _ = try v.store(0x030, 4, REQUEST_QUEUE);
    _ = try v.store(0x038, 4, num);
    _ = try v.store(0x080, 4, DESC_AT & 0xffff_ffff);
    _ = try v.store(0x084, 4, DESC_AT >> 32);
    _ = try v.store(0x090, 4, AVAIL_AT & 0xffff_ffff);
    _ = try v.store(0x094, 4, AVAIL_AT >> 32);
    _ = try v.store(0x0a0, 4, USED_AT & 0xffff_ffff);
    _ = try v.store(0x0a4, 4, USED_AT >> 32);
    _ = try v.store(0x044, 4, 1);
    _ = try v.store(0x070, 4, (mmio.Status{
        .acknowledge = true,
        .driver = true,
        .features_ok = true,
        .driver_ok = true,
    }).toBits());
}

fn putDesc(g: Guest, i: u16, addr: u64, len: u32, flags: virtqueue.DescFlags, next: u16) void {
    const at = DESC_AT + @as(u64, i) * virtqueue.DESC_BYTES;
    g.write(u64, at, addr);
    g.write(u32, at + 8, len);
    g.write(u16, at + 12, @bitCast(flags));
    g.write(u16, at + 14, next);
}

fn putHeader(g: Guest, kind: u32, sector: u64) void {
    g.write(u32, HEADER_AT, kind);
    g.write(u32, HEADER_AT + 4, 0);
    g.write(u64, HEADER_AT + 8, sector);
}

/// A header/data/status chain, posted as the `n`th request and published.
fn postRequest(g: Guest, n: u16, kind: u32, sector: u64, len: u32) void {
    putHeader(g, kind, sector);
    putDesc(g, 0, HEADER_AT, Header.BYTES, .{ .next = true }, 1);
    putDesc(g, 1, DATA_AT, len, .{ .next = true, .write = kind == 0 }, 2);
    putDesc(g, 2, STATUS_AT, 1, .{ .write = true }, 0);
    g.write(u16, AVAIL_AT + 4 + @as(u64, n % 4) * 2, 0);
    g.write(u16, AVAIL_AT + 2, n + 1);
}

/// A flush chain: a header and a status, with nothing in between.
fn postFlush(g: Guest, n: u16) void {
    putHeader(g, @intFromEnum(RequestType.flush), 0);
    putDesc(g, 0, HEADER_AT, Header.BYTES, .{ .next = true }, 1);
    putDesc(g, 1, STATUS_AT, 1, .{ .write = true }, 0);
    g.write(u16, AVAIL_AT + 4 + @as(u64, n % 4) * 2, 0);
    g.write(u16, AVAIL_AT + 2, n + 1);
}

test "blk: identifies as a modern virtio block device that can flush" {
    var v = VirtioBlk{};
    try testing.expectEqual(@as(u64, mmio.MAGIC), try v.load(0x000, 4));
    try testing.expectEqual(@as(u64, 2), try v.load(0x004, 4));
    try testing.expectEqual(@as(u64, 2), try v.load(0x008, 4)); // block
    try testing.expectEqual(@as(u64, MAX_DESCRIPTORS), try v.load(0x034, 4));
    _ = try v.store(0x014, 4, 0);
    try testing.expectEqual(@as(u64, 1) << F_FLUSH, try v.load(0x010, 4));
}

test "blk: an unaligned or non-word access faults" {
    var v = VirtioBlk{};
    try testing.expectError(error.AccessFault, v.load(0x002, 4));
    try testing.expectError(error.AccessFault, v.load(0x000, 2));
    try testing.expectError(error.AccessFault, v.store(0x070, 1, 0));
}

test "blk: capacity is the image size in sectors, split across two registers" {
    var disk: [3 * SECTOR_BYTES]u8 = @splat(0);
    var v = VirtioBlk{ .disk = &disk };
    try testing.expectEqual(@as(u64, 3), try v.load(0x100, 4));
    try testing.expectEqual(@as(u64, 0), try v.load(0x104, 4));
    // Configuration space is read-only.
    _ = try v.store(0x100, 4, 99);
    try testing.expectEqual(@as(u64, 3), try v.load(0x100, 4));
}

test "blk: a read copies sectors from the image into the guest buffer" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(disk[SECTOR_BYTES..], 0xab);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 0, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(u8, 0xab), ram[0x800]);
    try testing.expectEqual(@as(u8, 0xab), ram[0x800 + SECTOR_BYTES - 1]);
    try testing.expectEqual(@as(u8, @intFromEnum(Status.ok)), ram[0xc00]);
    try testing.expect(v.irqAsserted());
    // Used ring: the head descriptor, and the data plus the status byte.
    try testing.expectEqual(@as(?u32, 0), g.read(u32, USED_AT + 4));
    try testing.expectEqual(@as(?u32, SECTOR_BYTES + 1), g.read(u32, USED_AT + 8));
}

test "blk: a request spanning several data descriptors is served in order" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(disk[0..8], 0x11);
    @memset(disk[8..16], 0x22);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    putHeader(g, 0, 0);
    putDesc(g, 0, HEADER_AT, Header.BYTES, .{ .next = true }, 1);
    putDesc(g, 1, DATA_AT, 8, .{ .next = true, .write = true }, 2);
    putDesc(g, 2, DATA_AT + 8, 8, .{ .next = true, .write = true }, 3);
    putDesc(g, 3, STATUS_AT, 1, .{ .write = true }, 0);
    g.write(u16, AVAIL_AT + 4, 0);
    g.write(u16, AVAIL_AT + 2, 1);

    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(u8, 0x11), ram[0x800]);
    try testing.expectEqual(@as(u8, 0x22), ram[0x808]);
    try testing.expectEqual(@as(u8, @intFromEnum(Status.ok)), ram[0xc00]);
    try testing.expectEqual(@as(?u32, 17), g.read(u32, USED_AT + 8));
}

test "blk: a request past the end of the image moves nothing" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [SECTOR_BYTES]u8 = @splat(0);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0x5a);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 1, 4, SECTOR_BYTES); // sector 4 of a one-sector image
    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(u8, 0), disk[0]);
    // Completed with nothing written, so the driver is not left waiting.
    try testing.expectEqual(@as(?u32, 0), g.read(u32, USED_AT + 8));
    try testing.expectEqual(@as(?u16, 1), g.read(u16, USED_AT + 2));
}

test "blk: a request type this model does not serve moves nothing" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [SECTOR_BYTES]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 4, 0, 16); // flush, which is not offered
    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(?u32, 0), g.read(u32, USED_AT + 8));
    try testing.expectEqual(@as(?u16, 1), g.read(u16, USED_AT + 2));
}

test "blk: a chain too short to be a request is completed and skipped" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [SECTOR_BYTES]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    putHeader(g, 0, 0);
    putDesc(g, 0, HEADER_AT, Header.BYTES, .{ .next = true }, 1);
    putDesc(g, 1, STATUS_AT, 1, .{ .write = true }, 0);
    g.write(u16, AVAIL_AT + 4, 0);
    g.write(u16, AVAIL_AT + 2, 1);

    v.service(REQUEST_QUEUE, g);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, USED_AT + 2));
}

test "blk: nothing is served until the driver says it is ready" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(disk[SECTOR_BYTES..], 0xab);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    _ = try v.store(0x070, 4, (mmio.Status{ .acknowledge = true, .driver = true }).toBits());
    postRequest(g, 0, 0, 1, SECTOR_BYTES);

    v.service(REQUEST_QUEUE, g);
    try testing.expectEqual(@as(u8, 0), ram[0x800]);
    try testing.expect(!v.irqAsserted());
}

test "blk: a second kick with nothing posted serves nothing again" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(disk[SECTOR_BYTES..], 0xab);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 0, 1, SECTOR_BYTES);

    v.service(REQUEST_QUEUE, g);
    v.service(REQUEST_QUEUE, g);
    try testing.expectEqual(@as(?u16, 1), g.read(u16, USED_AT + 2));
}

test "blk: a kick on a queue this device does not have serves nothing" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 0, 1, SECTOR_BYTES);

    v.service(1, g);
    try testing.expectEqual(@as(?u16, 0), g.read(u16, USED_AT + 2));
}

test "blk: a notify store answers the queue and a status of zero resets" {
    var disk: [SECTOR_BYTES]u8 = @splat(0);
    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);

    try testing.expectEqual(mmio.Action{ .notify = 0 }, try v.store(0x050, 4, 0));

    _ = try v.store(0x070, 4, 0);
    try testing.expectEqual(@as(u32, 0), v.transport.queues[0].num);
    // The image belongs to the owner and survives the reset.
    try testing.expectEqual(@as(usize, SECTOR_BYTES), v.disk.len);
}

test "blk: a driver that took no flush feature has no cache to lose" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0x5a);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUpNoFlush(&v, 4);
    postRequest(g, 0, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(u8, 0x5a), disk[SECTOR_BYTES]);
    try testing.expectEqual(@as(u8, 0), disk[0]);
    try testing.expectEqual(@as(usize, 0), v.pending().len);
    try testing.expectEqual(@as(u8, @intFromEnum(Status.ok)), ram[0xc00]);
}

test "blk: a write completes into the cache and is not on the image yet" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0x5a);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(u8, @intFromEnum(Status.ok)), ram[0xc00]);
    try testing.expectEqual(@as(usize, 1), v.pending().len);
    try testing.expectEqual(@as(u64, 1), v.pending()[0].sector);
    try testing.expectEqual(@as(u8, 0), disk[SECTOR_BYTES]);
    // A write fills no guest buffer, so only the status byte is reported.
    try testing.expectEqual(@as(?u32, 1), g.read(u32, USED_AT + 8));
}

test "blk: a flush puts the cache on the image" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0x5a);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);
    postFlush(g, 1);
    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(u8, 0x5a), disk[SECTOR_BYTES]);
    try testing.expectEqual(@as(usize, 0), v.pending().len);
    try testing.expectEqual(@as(u8, @intFromEnum(Status.ok)), ram[0xc00]);
}

test "blk: an unflushed write reads back before it reaches the image" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0x5a);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0);
    postRequest(g, 1, 0, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(u8, 0x5a), ram[0x800]);
    try testing.expectEqual(@as(u8, 0), disk[SECTOR_BYTES]);
}

test "blk: the later of two writes to a sector is what a read of it sees" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0x11);
    postRequest(g, 0, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0x22);
    postRequest(g, 1, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);

    @memset(ram[0x800..][0..SECTOR_BYTES], 0);
    postRequest(g, 2, 0, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);
    try testing.expectEqual(@as(u8, 0x22), ram[0x800]);
}

test "blk: a power cut loses what no flush claimed" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [4 * SECTOR_BYTES]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0xaa);
    postRequest(g, 0, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);
    postFlush(g, 1);
    v.service(REQUEST_QUEUE, g);

    @memset(ram[0x800..][0..SECTOR_BYTES], 0xbb);
    postRequest(g, 2, 1, 2, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);

    v.powerCut(0);

    try testing.expectEqual(@as(u8, 0xaa), disk[SECTOR_BYTES]);
    try testing.expectEqual(@as(u8, 0), disk[2 * SECTOR_BYTES]);
    try testing.expectEqual(@as(usize, 0), v.pending().len);
}

test "blk: a power cut can keep a prefix of what was outstanding" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [4 * SECTOR_BYTES]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0xaa);
    postRequest(g, 0, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0xbb);
    postRequest(g, 1, 1, 2, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);

    try testing.expectEqual(@as(usize, 2), v.pending().len);
    v.powerCut(1);

    try testing.expectEqual(@as(u8, 0xaa), disk[SECTOR_BYTES]);
    try testing.expectEqual(@as(u8, 0), disk[2 * SECTOR_BYTES]);
}

test "blk: the cache puts writes on the image once it is full" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [(CACHE_ENTRIES + 2) * SECTOR_BYTES]u8 = @splat(0);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0xcd);
    for (0..CACHE_ENTRIES + 1) |i| {
        postRequest(g, @intCast(i), 1, i, SECTOR_BYTES);
        v.service(REQUEST_QUEUE, g);
    }

    // The earlier writes were pushed out to make room; the last is still cached.
    try testing.expectEqual(@as(u8, 0xcd), disk[0]);
    try testing.expectEqual(@as(usize, 1), v.pending().len);
    try testing.expectEqual(@as(u64, CACHE_ENTRIES), v.pending()[0].sector);
}

test "blk: a reset drops the cache rather than putting it on the image" {
    var ram: [0x4000]u8 = @splat(0);
    var disk: [2 * SECTOR_BYTES]u8 = @splat(0);
    @memset(ram[0x800..][0..SECTOR_BYTES], 0x5a);
    const g = Guest{ .memory = &ram, .base = BASE };

    var v = VirtioBlk{ .disk = &disk };
    try bringUp(&v, 4);
    postRequest(g, 0, 1, 1, SECTOR_BYTES);
    v.service(REQUEST_QUEUE, g);

    _ = try v.store(0x070, 4, 0);
    try testing.expectEqual(@as(usize, 0), v.pending().len);
    try testing.expectEqual(@as(u8, 0), disk[SECTOR_BYTES]);
}
