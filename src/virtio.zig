const std = @import("std");
const testing = std.testing;
const bits = @import("bits");

pub const Virtio = struct {
    pub const VIRTIO_SIZE = 0x1000;
    pub const QUEUE_NUM_MAX = 8;
    pub const MAGIC_VAL = 0x74726976;
    pub const VERSION = 2;
    pub const DEVICE_ID = 2;
    pub const VENDOR_ID = 0x554d4551;

    status: u32 = 0,
    driver_features: u32 = 0,
    queue_num: u32 = 0,
    queue_ready: u32 = 0,
    desc_addr: u64 = 0,
    avail_addr: u64 = 0,
    used_addr: u64 = 0,
    queue_sel: u32 = 0,
    notify_pending: bool = false,
    disk: []u8 = &.{},
    last_avail_index: u16 = 0,
    interrupt_status: u32 = 0,
    used_index: u16 = 0,

    fn setLow(v: *u64, value: u64) void {
        var desc = VirtioAddr.fromBits(v.*);
        desc.low = @truncate(value);
        v.* = desc.toBits();
    }

    fn setHi(v: *u64, value: u64) void {
        var desc = VirtioAddr.fromBits(v.*);
        desc.hi = @truncate(value);
        v.* = desc.toBits();
    }
    pub fn store(self: *Virtio, addr: u64, size: usize, value: u64) !void {
        if (size != 4 or !bits.isAligned(addr, 4)) {
            return error.AccessFault;
        }
        switch (addr) {
            0x70 => self.status = @truncate(value),
            0x20 => self.driver_features = @truncate(value),
            0x38 => self.queue_num = @truncate(value),
            0x80 => setLow(&self.desc_addr, value),
            0x84 => setHi(&self.desc_addr, value),
            0x90 => setLow(&self.avail_addr, value),
            0x94 => setHi(&self.avail_addr, value),
            0xa0 => setLow(&self.used_addr, value),
            0xa4 => setHi(&self.used_addr, value),
            0x44 => self.queue_ready = @truncate(value),
            0x30 => self.queue_sel = @truncate(value),
            0x50 => self.notify_pending = true,
            // write-1-to-clear, masked to the two defined bits
            0x64 => self.interrupt_status &= ~(@as(u32, @truncate(value)) & VirtioInterruptStatus.W1C_MASK),
            else => {},
        }
    }

    pub fn process(self: *Virtio, memory: []u8, comptime memory_base: usize) void {
        if (self.queue_ready != 1) return;
        if (VirtioStatus.fromBits(self.status).driver_ok != 1) return;
        const avail = readAvail(self, memory, memory_base) orelse return;
        while (avail.idx != self.last_avail_index) : (self.last_avail_index +%= 1) {
            const head = avail.ring[self.last_avail_index % QUEUE_NUM_MAX];
            const data_desc = self.serviceChain(memory, head, memory_base);
            const len: u32 = if (data_desc) |d| d.len + 1 else 0;
            self.writeUsed(memory, memory_base, head, len);
            var s = VirtioInterruptStatus.fromBits(self.interrupt_status);
            s.used_buffer_notification = 1; // set the pending bit
            self.interrupt_status = s.toBits();
        }
    }
    fn writeU16(memory: []u8, base: u64, paddr: u64, val: u16) void {
        const s = guest(memory, base, paddr, 2) orelse return;
        std.mem.writeInt(u16, s[0..2], val, .little);
    }
    fn writeU32(memory: []u8, base: u64, paddr: u64, val: u32) void {
        const s = guest(memory, base, paddr, 4) orelse return;
        std.mem.writeInt(u32, s[0..4], val, .little);
    }

    pub fn writeUsed(self: *Virtio, memory: []u8, base: u64, head: u16, len: u32) void {
        const slot = self.used_index % Virtio.QUEUE_NUM_MAX;
        writeU32(memory, base, self.used_addr + 4 + 8 * slot, head);
        writeU32(memory, base, self.used_addr + 4 + 8 * slot + 4, len);
        self.used_index +%= 1;
        writeU16(memory, base, self.used_addr + 2, self.used_index);
    }

    fn guest(memory: []u8, base: u64, paddr: u64, len: u64) ?[]u8 {
        if (paddr < base) return null;
        const off = paddr - base;
        if (!bits.inBounds(off, len, memory.len)) return null;

        return memory[off..][0..len];
    }

    pub fn load(self: *Virtio, addr: u64, size: usize) !u64 {
        if (size != 4 or !bits.isAligned(addr, 4)) {
            return error.AccessFault;
        }
        return switch (addr) {
            0x00 => Virtio.MAGIC_VAL,
            0x04 => Virtio.VERSION,
            0x08 => Virtio.DEVICE_ID,
            0x0c => Virtio.VENDOR_ID,
            0x10 => 0,
            0x70 => self.status,
            0x44 => self.queue_ready,
            0x34 => Virtio.QUEUE_NUM_MAX,
            0x60 => self.interrupt_status,
            else => 0,
        };
    }
    pub fn irqAsserted(self: *const Virtio) bool {
        return self.interrupt_status != 0;
    }
    pub fn hash(self: *const Virtio, h: *std.hash.Wyhash) void {
        h.update(std.mem.asBytes(&self.status));
        h.update(std.mem.asBytes(&self.driver_features));
        h.update(std.mem.asBytes(&self.queue_num));
        h.update(std.mem.asBytes(&self.queue_ready));
        h.update(std.mem.asBytes(&self.desc_addr));
        h.update(std.mem.asBytes(&self.avail_addr));
        h.update(std.mem.asBytes(&self.used_addr));
        h.update(std.mem.asBytes(&self.queue_sel));
        h.update(std.mem.asBytes(&self.notify_pending));
        h.update(std.mem.asBytes(&self.last_avail_index));
        h.update(std.mem.asBytes(&self.interrupt_status));
        h.update(std.mem.asBytes(&self.used_index));
        h.update(self.disk);
    }

    fn readDesc(self: *const Virtio, memory: []u8, i: usize, base: u64) ?VirtioDesc {
        const s = guest(memory, base, self.desc_addr + 16 * i, 16) orelse return null;
        return .{
            .addr = bits.u64le(s, 0),
            .len = bits.u32le(s, 8),
            .flags = bits.u16le(s, 12),
            .next = bits.u16le(s, 14),
        };
    }

    fn readAvail(self: *const Virtio, memory: []u8, base: u64) ?VirtioAvail {
        const s = guest(memory, base, self.avail_addr, 22) orelse return null;

        var res: VirtioAvail = .{
            .flags = bits.u16le(s, 0),
            .idx = bits.u16le(s, 2),
            .unused = bits.u16le(s, 20),
        };
        var i: usize = 0;
        while (i < Virtio.QUEUE_NUM_MAX) : (i += 1) {
            res.ring[i] = bits.u16le(s, 4 + i * 2);
        }

        return res;
    }

    fn serviceChain(self: *const Virtio, memory: []u8, head: u16, base: u64) ?VirtioDesc {
        const head_desc = readDesc(self, memory, head, base) orelse return null;
        const data_desc = readDesc(self, memory, head_desc.next, base) orelse return null;
        const status_desc = readDesc(self, memory, data_desc.next, base) orelse return null;
        const req_header = guest(memory, base, head_desc.addr, head_desc.len) orelse return null;
        const virtio_req_header: VirtioBlkReq = .{
            .type = bits.u32le(req_header, 0),
            .res = bits.u32le(req_header, 4),
            .sector = bits.u64le(req_header, 8),
        };
        const req_type: VirtioBlkReqType = @enumFromInt(virtio_req_header.type);

        const offset = std.math.mul(u64, virtio_req_header.sector, 512) catch return null;
        const end_offset = std.math.add(u64, offset, @as(u64, data_desc.len)) catch return null;

        if (end_offset > self.disk.len) {
            return null;
        }
        const v = guest(memory, base, data_desc.addr, data_desc.len) orelse return null;
        switch (req_type) {
            .in => {
                @memcpy(v, self.disk[offset..][0..data_desc.len]);
            },
            .out => {
                @memcpy(self.disk[offset..][0..data_desc.len], v);
            },
            else => return null,
        }
        const stat = guest(memory, base, status_desc.addr, 1) orelse return null;
        stat[0] = 0;
        return data_desc;
    }
};

const VirtioInterruptStatus = packed struct {
    used_buffer_notification: u1 = 0,
    config_change: u1 = 0,
    _reserved: u30 = 0,
    pub fn fromBits(v: u32) VirtioInterruptStatus {
        return @bitCast(v);
    }
    pub fn toBits(self: VirtioInterruptStatus) u32 {
        return @bitCast(self);
    }

    // Write-1-to-clear mask: only these two bits participate; a write into reserved positions
    // can't disturb them. Applied at the 0x64 store site.
    pub const W1C_MASK = (VirtioInterruptStatus{ .used_buffer_notification = 1, .config_change = 1 }).toBits();
};
const VirtioAddr = packed struct {
    low: u32 = 0,
    hi: u32 = 0,
    pub fn fromBits(v: u64) VirtioAddr {
        return @bitCast(v);
    }
    pub fn toBits(self: VirtioAddr) u64 {
        return @bitCast(self);
    }
};

const VirtioStatus = packed struct {
    acknowledge: u1 = 0,
    driver: u1 = 0,
    driver_ok: u1 = 0,
    features_ok: u1 = 0,
    _res: u28 = 0,
    pub fn fromBits(v: u32) VirtioStatus {
        return @bitCast(v);
    }
};

const VirtioDesc = struct {
    addr: u64 = 0,
    len: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};

const VirtioAvail = struct {
    flags: u16 = 0,
    idx: u16 = 0,
    ring: [Virtio.QUEUE_NUM_MAX]u16 = @splat(0),
    unused: u16 = 0,
};

const VirtioBlkReq = struct {
    type: u32,
    res: u32,
    sector: u64,
};
const VirtioBlkReqType = enum(u32) {
    in = 0,
    out = 1,
    _,
};

// ---- test helpers: hand-build a virtqueue in a RAM buffer (the harness plays the driver) ----
// Shared layout convention for the queue tests: guest base = 0x8000_0000, descriptor table at
// base + 0x100 (entry i at 0x100 + 16*i), avail ring at base + 0x80 (idx @ 0x82, ring[j] @ 0x84+2j).
const seed = struct {
    fn desc(b: []u8, i: usize, addr: u64, len: u32, flags: u16, next: u16) void {
        const o = 0x100 + 16 * i;
        std.mem.writeInt(u64, b[o..][0..8], addr, .little);
        std.mem.writeInt(u32, b[o + 8 ..][0..4], len, .little);
        std.mem.writeInt(u16, b[o + 12 ..][0..2], flags, .little);
        std.mem.writeInt(u16, b[o + 14 ..][0..2], next, .little);
    }
    fn hdr(b: []u8, off: usize, typ: u32, sector: u64) void {
        std.mem.writeInt(u32, b[off..][0..4], typ, .little);
        std.mem.writeInt(u32, b[off + 4 ..][0..4], 0, .little);
        std.mem.writeInt(u64, b[off + 8 ..][0..8], sector, .little);
    }
    fn availIdx(b: []u8, idx: u16) void {
        std.mem.writeInt(u16, b[0x82..][0..2], idx, .little);
    }
    fn availRing(b: []u8, slot: usize, head: u16) void {
        std.mem.writeInt(u16, b[0x84 + 2 * slot ..][0..2], head, .little);
    }
};

test "virtio comp" {
    _ = Virtio{};
    try testing.expectEqual(0x74726976, Virtio.MAGIC_VAL);
}

// The probe reads return their exact constants — a wrong value is what triggers xv6's "could not
// find virtio disk" panic. Also: QueueNumMax = 8, DeviceFeatures = 0, Status/QueueReady read back
// stored state, and an in-window hole reads 0.
test "load: probe constants + stored reads + hole" {
    var v: Virtio = .{};

    // the identity probe
    try testing.expectEqual(0x74726976, try v.load(0x00, 4)); // MagicValue
    try testing.expectEqual(2, try v.load(0x04, 4)); // Version
    try testing.expectEqual(2, try v.load(0x08, 4)); // DeviceId
    try testing.expectEqual(0x554d4551, try v.load(0x0c, 4)); // VendorId

    // advertise no features; max queue depth
    try testing.expectEqual(0, try v.load(0x10, 4)); // DeviceFeatures
    try testing.expectEqual(8, try v.load(0x34, 4)); // QueueNumMax

    // read back latched state
    v.status = 0x0F;
    v.queue_ready = 1;
    try testing.expectEqual(0x0F, try v.load(0x70, 4)); // Status
    try testing.expectEqual(1, try v.load(0x44, 4)); // QueueReady

    // permissive in-window hole (e.g. QueueNotify, not modelled) reads 0
    try testing.expectEqual(0, try v.load(0x50, 4));

    // word-only tripwire: sub-word / misaligned faults
    try testing.expectError(error.AccessFault, v.load(0x00, 1));
    try testing.expectError(error.AccessFault, v.load(0x02, 4));
}

// Writes latch into the right fields and read back through load. Covers the Status handshake walk,
// the order-independent low/high address assembly, and the queue latches.
test "store: status walk + address assembly + latches" {
    var v: Virtio = .{};

    // Status handshake progression: each write reads back verbatim.
    for ([_]u64{ 0, 1, 3, 0x0B, 0x0F }) |s| {
        try v.store(0x70, 4, s);
        try testing.expectEqual(s, try v.load(0x70, 4));
    }

    // desc_addr assembled low-then-high (items 16-17).
    try v.store(0x80, 4, 0x1111_2222); // QueueDescLow
    try v.store(0x84, 4, 0x3333_4444); // QueueDescHigh
    try testing.expectEqual(@as(u64, 0x3333_4444_1111_2222), v.desc_addr);

    // avail_addr assembled high-then-low → same result (order independence of the lens).
    try v.store(0x94, 4, 0xAAAA_BBBB); // DriverDescHigh first
    try v.store(0x90, 4, 0xCCCC_DDDD); // DriverDescLow second
    try testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDDD), v.avail_addr);

    // used_addr both halves (items 20-21).
    try v.store(0xa0, 4, 0x0000_0100);
    try v.store(0xa4, 4, 0x0000_0000);
    try testing.expectEqual(@as(u64, 0x0000_0000_0000_0100), v.used_addr);

    // a high-half write must not disturb the already-written low half (mask correctness):
    // desc_addr low is still 0x1111_2222 after overwriting only the high half.
    try v.store(0x84, 4, 0x5555_6666);
    try testing.expectEqual(@as(u64, 0x5555_6666_1111_2222), v.desc_addr);

    // driver_features latch — currently unused, no load case; assert the field.
    try v.store(0x20, 4, 0xABCD);
    try testing.expectEqual(@as(u32, 0xABCD), v.driver_features);

    // queue latches: queue_num, queue_sel, and QueueReady 1-after.
    try v.store(0x38, 4, 8); // QueueNum
    try v.store(0x30, 4, 0); // QueueSel
    try v.store(0x44, 4, 1); // QueueReady
    try testing.expectEqual(@as(u32, 8), v.queue_num);
    try testing.expectEqual(@as(u32, 0), v.queue_sel);
    try testing.expectEqual(1, try v.load(0x44, 4));

    // permissive in-window hole on the write path (QueueNotify 0x50, not modelled):
    // must be ignored, not faulted, and must not corrupt neighbouring state.
    try v.store(0x50, 4, 0x123);
    try testing.expectEqual(@as(u32, 8), v.queue_num); // untouched

    // word-only tripwire on the write path too.
    try testing.expectError(error.AccessFault, v.store(0x70, 1, 1));
    try testing.expectError(error.AccessFault, v.store(0x82, 4, 1));
}

// guest() translates a guest-physical addr to a bounds-checked ram slice.
// The returned slice aliases the backing buffer (DMA writes land in guest RAM); out-of-range
// and below-base return null (the deterministic-skip signal, not a fault).
test "guest: bounds check + slice aliases ram" {
    var buf: [32]u8 = @splat(0);
    const base: u64 = 0x8000_0000;

    // in-range: right length, and it's a VIEW onto buf (writes flow through).
    const s = Virtio.guest(&buf, base, base + 4, 8).?;
    try testing.expectEqual(@as(usize, 8), s.len);
    s[0] = 0xAB;
    try testing.expectEqual(@as(u8, 0xAB), buf[4]); // DMA write landed at offset 4

    // paddr == base (offset 0) and a full-buffer span both valid.
    try testing.expect(Virtio.guest(&buf, base, base, 32) != null);

    // exact fit at the tail: off+len == memory.len is in-bounds.
    try testing.expect(Virtio.guest(&buf, base, base + 24, 8) != null);

    // one byte past the end → null.
    try testing.expect(Virtio.guest(&buf, base, base + 25, 8) == null);

    // below base → null.
    try testing.expect(Virtio.guest(&buf, base, base - 1, 1) == null);

    // wildly-out-of-range paddr → null, no overflow/panic (the subtraction-form bound).
    try testing.expect(Virtio.guest(&buf, base, base + 1_000_000, 4) == null);
}

// readDesc decodes a 16-byte virtq_desc out of guest RAM at desc_addr + 16*i.
// Having a real CALLER is the point — an unreferenced private fn isn't fully analysed, so this is
// what actually proves readDesc compiles and reads the right offsets (0/8/12/14, little-endian).
test "readDesc: decodes a descriptor at desc_addr + 16*i" {
    var buf: [512]u8 = @splat(0);
    const base: u64 = 0x8000_0000;

    var v: Virtio = .{};
    v.desc_addr = base + 0x100; // descriptor table lives 0x100 into RAM

    // hand-write descriptor index 2 → buffer offset 0x100 + 16*2 = 0x120 (little-endian).
    const doff = 0x100 + 16 * 2;
    std.mem.writeInt(u64, buf[doff..][0..8], 0x8000_5000, .little); // addr
    std.mem.writeInt(u32, buf[doff + 8 ..][0..4], 1024, .little); // len
    std.mem.writeInt(u16, buf[doff + 12 ..][0..2], 3, .little); // flags = WRITE|NEXT
    std.mem.writeInt(u16, buf[doff + 14 ..][0..2], 5, .little); // next

    const d = v.readDesc(&buf, 2, base).?;
    try testing.expectEqual(@as(u64, 0x8000_5000), d.addr);
    try testing.expectEqual(@as(u32, 1024), d.len);
    try testing.expectEqual(@as(u16, 3), d.flags);
    try testing.expectEqual(@as(u16, 5), d.next);

    // out-of-range: a desc whose 16 bytes run past RAM end → null (deterministic skip).
    v.desc_addr = base + buf.len - 8; // only 8 bytes left, need 16
    try testing.expect(v.readDesc(&buf, 0, base) == null);
}

// readAvail decodes the 22-byte virtq_avail (idx + ring heads) out of guest
// RAM at avail_addr. Caller forces analysis and proves the offsets (idx@2, ring[j]@4+2*j).
test "readAvail: decodes idx and ring heads" {
    var buf: [512]u8 = @splat(0);
    const base: u64 = 0x8000_0000;

    var v: Virtio = .{};
    v.avail_addr = base + 0x100; // avail ring lives 0x100 into RAM
    const aoff = 0x100;

    std.mem.writeInt(u16, buf[aoff + 2 ..][0..2], 3, .little); // idx = 3 (producer count)
    std.mem.writeInt(u16, buf[aoff + 4 ..][0..2], 7, .little); // ring[0] = head 7
    std.mem.writeInt(u16, buf[aoff + 6 ..][0..2], 2, .little); // ring[1] = head 2

    const av = v.readAvail(&buf, base).?;
    try testing.expectEqual(@as(u16, 3), av.idx);
    try testing.expectEqual(@as(u16, 7), av.ring[0]);
    try testing.expectEqual(@as(u16, 2), av.ring[1]);
    try testing.expectEqual(@as(u16, 0), av.ring[2]); // untouched slot reads 0

    // out-of-range: avail whose 22 bytes run past RAM end → null.
    v.avail_addr = base + buf.len - 8; // only 8 bytes left, need 22
    try testing.expect(v.readAvail(&buf, base) == null);
}

// serviceChain walks a hand-built 3-descriptor T_IN chain, parses the virtio_blk_req header, copies
// the sector bytes from the backing disk into the guest data buffer, and writes status 0. Calling
// the private fn is the whole point — it forces analysis of the .in datapath (offsets, bounds,
// memcpy direction) that an unreferenced fn skips. Mutation target: breaking sector*512, the copy
// length, or the copy direction turns the slice compare red.
test "serviceChain: T_IN copies sector bytes into guest buffer and clears status" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);

    // backing disk: sector 2 (byte offset 2*512 = 1024) holds a known 1024-byte pattern.
    var disk: [4096]u8 = @splat(0);
    for (0..1024) |j| disk[1024 + j] = @truncate(j);

    var v: Virtio = .{};
    v.desc_addr = base + 0x100; // descriptor table 0x100 into RAM
    v.disk = &disk;

    // 3-descriptor chain: header(idx 0) → data(idx 1) → status(idx 2), each at desc_addr + 16*i.
    // header desc @ index 0
    std.mem.writeInt(u64, buf[0x100..][0..8], base + 0x200, .little); // addr → header buffer
    std.mem.writeInt(u32, buf[0x108..][0..4], 16, .little); // len = sizeof(virtio_blk_req)
    std.mem.writeInt(u16, buf[0x10c..][0..2], 1, .little); // flags = NEXT
    std.mem.writeInt(u16, buf[0x10e..][0..2], 1, .little); // next = 1
    // data desc @ index 1
    std.mem.writeInt(u64, buf[0x110..][0..8], base + 0x300, .little); // addr → guest data buffer
    std.mem.writeInt(u32, buf[0x118..][0..4], 1024, .little); // len = BSIZE
    std.mem.writeInt(u16, buf[0x11c..][0..2], 3, .little); // flags = WRITE|NEXT
    std.mem.writeInt(u16, buf[0x11e..][0..2], 2, .little); // next = 2
    // status desc @ index 2
    std.mem.writeInt(u64, buf[0x120..][0..8], base + 0x800, .little); // addr → status byte
    std.mem.writeInt(u32, buf[0x128..][0..4], 1, .little); // len = 1
    std.mem.writeInt(u16, buf[0x12c..][0..2], 2, .little); // flags = WRITE
    std.mem.writeInt(u16, buf[0x12e..][0..2], 0, .little); // next = 0 (chain end)

    // virtio_blk_req header @ 0x200: type = T_IN(0), reserved = 0, sector = 2.
    std.mem.writeInt(u32, buf[0x200..][0..4], 0, .little); // type = T_IN
    std.mem.writeInt(u32, buf[0x204..][0..4], 0, .little); // reserved
    std.mem.writeInt(u64, buf[0x208..][0..8], 2, .little); // sector = 2

    // driver presets status to 0xff; the device must overwrite it with 0 on success.
    buf[0x800] = 0xff;

    _ = v.serviceChain(&buf, 0, base);

    // the guest data buffer received exactly sector 2's 1024 bytes (right sector, right length,
    // right direction) ...
    try testing.expectEqualSlices(u8, disk[1024..2048], buf[0x300..][0..1024]);
    // ... and the status byte was cleared to 0.
    try testing.expectEqual(@as(u8, 0), buf[0x800]);
}

// The T_OUT arm — mirror of the T_IN test. The guest data
// buffer holds the pattern; serviceChain must copy it OUT to disk[sector*512..] (direction
// reversed) and clear status. Asserts the .out memcpy that the T_IN test leaves unexercised.
test "serviceChain: T_OUT copies guest buffer out to disk and clears status" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);

    // guest data buffer @ 0x300 holds a known 1024-byte pattern to be written to disk.
    for (0..1024) |j| buf[0x300 + j] = @truncate(j *% 3 + 1);

    // disk starts zeroed; sector 3 (byte offset 3*512 = 1536) is the write target.
    var disk: [4096]u8 = @splat(0);

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.disk = &disk;

    // 3-descriptor chain: header(0) → data(1) → status(2).
    // header desc @ index 0
    std.mem.writeInt(u64, buf[0x100..][0..8], base + 0x200, .little); // addr → header buffer
    std.mem.writeInt(u32, buf[0x108..][0..4], 16, .little); // len
    std.mem.writeInt(u16, buf[0x10c..][0..2], 1, .little); // flags = NEXT
    std.mem.writeInt(u16, buf[0x10e..][0..2], 1, .little); // next = 1
    // data desc @ index 1 — device-READABLE on a write, so flags = NEXT only (no WRITE bit)
    std.mem.writeInt(u64, buf[0x110..][0..8], base + 0x300, .little); // addr → guest data buffer
    std.mem.writeInt(u32, buf[0x118..][0..4], 1024, .little); // len = BSIZE
    std.mem.writeInt(u16, buf[0x11c..][0..2], 1, .little); // flags = NEXT
    std.mem.writeInt(u16, buf[0x11e..][0..2], 2, .little); // next = 2
    // status desc @ index 2
    std.mem.writeInt(u64, buf[0x120..][0..8], base + 0x800, .little); // addr → status byte
    std.mem.writeInt(u32, buf[0x128..][0..4], 1, .little); // len = 1
    std.mem.writeInt(u16, buf[0x12c..][0..2], 2, .little); // flags = WRITE
    std.mem.writeInt(u16, buf[0x12e..][0..2], 0, .little); // next = 0 (chain end)

    // virtio_blk_req header @ 0x200: type = T_OUT(1), reserved = 0, sector = 3.
    std.mem.writeInt(u32, buf[0x200..][0..4], 1, .little); // type = T_OUT
    std.mem.writeInt(u32, buf[0x204..][0..4], 0, .little); // reserved
    std.mem.writeInt(u64, buf[0x208..][0..8], 3, .little); // sector = 3

    buf[0x800] = 0xff; // driver preset

    _ = v.serviceChain(&buf, 0, base);

    // sector 3 of the disk received exactly the guest buffer's bytes (reversed direction) ...
    try testing.expectEqualSlices(u8, buf[0x300..][0..1024], disk[1536..2560]);
    // ... and the status byte was cleared to 0.
    try testing.expectEqual(@as(u8, 0), buf[0x800]);
}

// process consumes the avail ring from last_avail_index up to
// avail.idx, servicing every queued chain, and advances the cursor. Two T_IN requests submitted
// in one shot (avail.idx = 2) must BOTH be serviced and the cursor land on 2. Calling process is
// what forces analysis of the ready gate + cursor loop (the fn is otherwise unreferenced here).
test "process: services every queued chain and advances the cursor" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);

    // backing disk: sector 2 → pattern A, sector 4 → pattern B (distinct so a swap would show).
    var disk: [4096]u8 = @splat(0);
    for (0..1024) |j| disk[1024 + j] = @truncate(j); // sector 2  @ 2*512 = 1024
    for (0..1024) |j| disk[2048 + j] = @truncate(j *% 5 + 9); // sector 4  @ 4*512 = 2048

    // chain 0: header(0)→data(1)→status(2); chain 1: header(3)→data(4)→status(5). NEXT=1, WRITE=2.
    seed.desc(&buf, 0, base + 0x200, 16, 1, 1); // header 0
    seed.desc(&buf, 1, base + 0x300, 1024, 3, 2); // data 0
    seed.desc(&buf, 2, base + 0x700, 1, 2, 0); // status 0
    seed.desc(&buf, 3, base + 0x800, 16, 1, 4); // header 1
    seed.desc(&buf, 4, base + 0x900, 1024, 3, 5); // data 1
    seed.desc(&buf, 5, base + 0xd00, 1, 2, 0); // status 1

    seed.hdr(&buf, 0x200, 0, 2); // chain 0: T_IN, sector 2
    seed.hdr(&buf, 0x800, 0, 4); // chain 1: T_IN, sector 4

    // avail ring: idx = 2, ring[0] = head 0, ring[1] = head 3.
    seed.availIdx(&buf, 2);
    seed.availRing(&buf, 0, 0);
    seed.availRing(&buf, 1, 3);

    buf[0x700] = 0xff; // driver presets both status bytes
    buf[0xd00] = 0xff;

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.avail_addr = base + 0x80;
    v.disk = &disk;
    v.queue_ready = 1; // pass the ready gate
    v.status = 0x4; // DRIVER_OK (bit 2) set

    v.process(&buf, base);

    // both chains serviced: each data buffer holds its sector, each status cleared ...
    try testing.expectEqualSlices(u8, disk[1024..2048], buf[0x300..][0..1024]);
    try testing.expectEqualSlices(u8, disk[2048..3072], buf[0x900..][0..1024]);
    try testing.expectEqual(@as(u8, 0), buf[0x700]);
    try testing.expectEqual(@as(u8, 0), buf[0xd00]);
    // ... and the cursor advanced past both entries.
    try testing.expectEqual(@as(u16, 2), v.last_avail_index);
}

// The ready gate: a well-formed request is queued and available, but queue_ready==0,
// so process must ignore the notify entirely — no transfer, no cursor movement. DRIVER_OK is set
// to prove queue_ready alone does the gating.
test "process: ready gate blocks a notify when queue_ready == 0" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);
    var disk: [4096]u8 = @splat(0);
    for (0..1024) |j| disk[1024 + j] = @truncate(j);

    seed.desc(&buf, 0, base + 0x200, 16, 1, 1);
    seed.desc(&buf, 1, base + 0x300, 1024, 3, 2);
    seed.desc(&buf, 2, base + 0x700, 1, 2, 0);
    seed.hdr(&buf, 0x200, 0, 2);
    seed.availIdx(&buf, 1);
    seed.availRing(&buf, 0, 0);
    buf[0x700] = 0xff;

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.avail_addr = base + 0x80;
    v.disk = &disk;
    v.queue_ready = 0; // NOT ready
    v.status = 0x4; // DRIVER_OK set

    v.process(&buf, base);

    // nothing moved: buffer untouched, status still the driver's preset, cursor unmoved.
    try testing.expect(std.mem.allEqual(u8, buf[0x300..][0..1024], 0));
    try testing.expectEqual(@as(u8, 0xff), buf[0x700]);
    try testing.expectEqual(@as(u16, 0), v.last_avail_index);
}

// The cursor is persistent state across notifies. Service one chain, then submit a
// second and notify again — only the NEW chain runs. Proven by poisoning the first chain's buffer
// after it's serviced: if the cursor reset, process would re-service it and overwrite the poison.
test "process: cursor persists across notifies — only the new chain is serviced" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);
    var disk: [4096]u8 = @splat(0);
    for (0..1024) |j| disk[1024 + j] = @truncate(j); // sector 2
    for (0..1024) |j| disk[2048 + j] = @truncate(j *% 5 + 9); // sector 4

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.avail_addr = base + 0x80;
    v.disk = &disk;
    v.queue_ready = 1;
    v.status = 0x4;

    // --- first notify: chain 0 (head 0, sector 2) ---
    seed.desc(&buf, 0, base + 0x200, 16, 1, 1);
    seed.desc(&buf, 1, base + 0x300, 1024, 3, 2);
    seed.desc(&buf, 2, base + 0x700, 1, 2, 0);
    seed.hdr(&buf, 0x200, 0, 2);
    seed.availIdx(&buf, 1);
    seed.availRing(&buf, 0, 0);
    v.process(&buf, base);
    try testing.expectEqual(@as(u16, 1), v.last_avail_index);

    // poison chain 0's data buffer: survives iff chain 0 is NOT re-serviced.
    @memset(buf[0x300..][0..1024], 0xAA);

    // --- second notify: chain 1 (head 3, sector 4) at ring slot 1, idx -> 2 ---
    seed.desc(&buf, 3, base + 0x800, 16, 1, 4);
    seed.desc(&buf, 4, base + 0x900, 1024, 3, 5);
    seed.desc(&buf, 5, base + 0xd00, 1, 2, 0);
    seed.hdr(&buf, 0x800, 0, 4);
    seed.availIdx(&buf, 2);
    seed.availRing(&buf, 1, 3);
    v.process(&buf, base);

    // only the new chain ran: chain 1 landed, chain 0's poison intact, cursor at 2.
    try testing.expectEqualSlices(u8, disk[2048..3072], buf[0x900..][0..1024]);
    try testing.expect(std.mem.allEqual(u8, buf[0x300..][0..1024], 0xAA));
    try testing.expectEqual(@as(u16, 2), v.last_avail_index);
}

// Malformed input must be a deterministic skip, never a host crash. A T_IN request
// whose sector is far past the disk end makes serviceChain bail before copying — but the cursor
// still advances so one bad entry can't wedge the ring.
test "process: malformed request is skipped deterministically, cursor still advances" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);
    var disk: [4096]u8 = @splat(0);

    seed.desc(&buf, 0, base + 0x200, 16, 1, 1);
    seed.desc(&buf, 1, base + 0x300, 1024, 3, 2);
    seed.desc(&buf, 2, base + 0x700, 1, 2, 0);
    seed.hdr(&buf, 0x200, 0, 0xffff_ffff); // sector*512 far past disk.len
    seed.availIdx(&buf, 1);
    seed.availRing(&buf, 0, 0);
    buf[0x700] = 0xff;

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.avail_addr = base + 0x80;
    v.disk = &disk;
    v.queue_ready = 1;
    v.status = 0x4;

    v.process(&buf, base); // must not panic

    // copy skipped (buffer + status untouched), cursor advanced so the ring doesn't wedge.
    try testing.expect(std.mem.allEqual(u8, buf[0x300..][0..1024], 0));
    try testing.expectEqual(@as(u8, 0xff), buf[0x700]);
    try testing.expectEqual(@as(u16, 1), v.last_avail_index);
}

// The chain is a linked list, walked via `next`, not head/head+1/head+2. Scatter the
// descriptors (head=5 -> data=2 -> status=7) and assert the bytes still land — proves next-following.
test "process: chain walk follows next, not head+1 (non-contiguous descriptors)" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);
    var disk: [4096]u8 = @splat(0);
    for (0..1024) |j| disk[1024 + j] = @truncate(j); // sector 2

    seed.desc(&buf, 5, base + 0x200, 16, 1, 2); // header, next -> 2
    seed.desc(&buf, 2, base + 0x300, 1024, 3, 7); // data,   next -> 7
    seed.desc(&buf, 7, base + 0x700, 1, 2, 0); // status
    seed.hdr(&buf, 0x200, 0, 2);
    seed.availIdx(&buf, 1);
    seed.availRing(&buf, 0, 5); // ring head = 5 (not 0)
    buf[0x700] = 0xff;

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.avail_addr = base + 0x80;
    v.disk = &disk;
    v.queue_ready = 1;
    v.status = 0x4;

    v.process(&buf, base);

    // bytes landed despite the scattered indices → the walk follows `next`.
    try testing.expectEqualSlices(u8, disk[1024..2048], buf[0x300..][0..1024]);
    try testing.expectEqual(@as(u8, 0), buf[0x700]);
}

// InterruptStatus register semantics. 0x60 reads the pending bits;
// 0x64 is write-1-to-clear, masked to the two defined bits (bit0 used-notify, bit1 config-change);
// irqAsserted() tracks non-zero. The device sets the bit itself — 0x60 is read-only, no store path
// sets it — so seed interrupt_status directly to stand in for a completion.
test "interrupt status: read 0x60, write-1-to-clear 0x64, irqAsserted tracks non-zero" {
    var v: Virtio = .{};
    try testing.expect(!v.irqAsserted());

    // a completion sets used_buffer_notification (bit 0).
    v.interrupt_status = 0x1;
    try testing.expectEqual(@as(u64, 0x1), try v.load(0x60, 4)); // driver reads pending bits
    try testing.expect(v.irqAsserted());

    // partial ACK: both bits pending, clear only bit 0 → bit 1 survives, line stays asserted.
    v.interrupt_status = 0x3;
    try v.store(0x64, 4, 0x1);
    try testing.expectEqual(@as(u32, 0x2), v.interrupt_status);
    try testing.expect(v.irqAsserted());

    // ACK carrying only upper garbage bits clears nothing (masked to bits 0-1).
    v.interrupt_status = 0x1;
    try v.store(0x64, 4, 0xFFFF_FFFC);
    try testing.expectEqual(@as(u32, 0x1), v.interrupt_status);

    // full ACK of the pending bit → cleared, line lowers.
    try v.store(0x64, 4, 0x1);
    try testing.expectEqual(@as(u32, 0x0), v.interrupt_status);
    try testing.expect(!v.irqAsserted());
}

// writeUsed publishes {id, len} at used_addr + 4 + 8*(used_index%NUM), bumps the device-side
// used_index, and mirrors used->idx into guest RAM @+2. Calling it forces analysis of the
// previously-unreferenced function. Two calls prove the slot stride and cursor.
test "writeUsed: publishes elem at the right slot and advances used->idx" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);

    var v: Virtio = .{};
    v.used_addr = base + 0x400; // used ring 0x400 into RAM

    // first completion: writeUsed stores len verbatim (process computes payload+status = 1025).
    v.writeUsed(&buf, base, 5, 1025);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[0x402..][0..2], .little)); // used->idx
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, buf[0x404..][0..4], .little)); // ring[0].id
    try testing.expectEqual(@as(u32, 1025), std.mem.readInt(u32, buf[0x408..][0..4], .little)); // ring[0].len
    try testing.expectEqual(@as(u16, 1), v.used_index);

    // second completion: head 3 → slot 1 (elem at +4+8), used->idx → 2.
    v.writeUsed(&buf, base, 3, 1024);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[0x402..][0..2], .little)); // used->idx
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[0x40c..][0..4], .little)); // ring[1].id
    try testing.expectEqual(@as(u16, 2), v.used_index);
}

// process closes the loop — after servicing a chain it publishes a
// used entry and raises the interrupt bit. Non-contiguous head (5) so ring[0].id is distinctive.
test "process: publishes a used entry and raises the interrupt on completion" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);
    var disk: [4096]u8 = @splat(0);
    for (0..1024) |j| disk[1024 + j] = @truncate(j); // sector 2

    // T_IN chain head=5 → data=6 → status=7.
    seed.desc(&buf, 5, base + 0x200, 16, 1, 6);
    seed.desc(&buf, 6, base + 0x300, 1024, 3, 7);
    seed.desc(&buf, 7, base + 0x700, 1, 2, 0);
    seed.hdr(&buf, 0x200, 0, 2);
    seed.availIdx(&buf, 1);
    seed.availRing(&buf, 0, 5);

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.avail_addr = base + 0x80;
    v.used_addr = base + 0x900;
    v.disk = &disk;
    v.queue_ready = 1;
    v.status = 0x4; // DRIVER_OK

    v.process(&buf, base);

    // completion published to the used ring (idx bumped, elem = {head, payload+status}) ...
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[0x902..][0..2], .little)); // used->idx
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, buf[0x904..][0..4], .little)); // ring[0].id = head
    try testing.expectEqual(@as(u32, 1025), std.mem.readInt(u32, buf[0x908..][0..4], .little)); // ring[0].len
    // ... and the used-buffer interrupt is now pending.
    try testing.expect(v.irqAsserted());
    try testing.expectEqual(@as(u32, 0x1), v.interrupt_status);
}

// Two chains in one notify → two used entries, used->idx == 2, and a single
// level interrupt bit (not two).
test "process: two chains publish two used entries and one interrupt" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);
    var disk: [4096]u8 = @splat(0);
    for (0..1024) |j| {
        disk[1024 + j] = @truncate(j); // sector 2
        disk[2048 + j] = @truncate(j *% 5 + 9); // sector 4
    }

    // chain 0: 0→1→2 (sector 2); chain 1: 3→4→5 (sector 4).
    seed.desc(&buf, 0, base + 0x200, 16, 1, 1);
    seed.desc(&buf, 1, base + 0x300, 1024, 3, 2);
    seed.desc(&buf, 2, base + 0x700, 1, 2, 0);
    seed.desc(&buf, 3, base + 0x800, 16, 1, 4);
    seed.desc(&buf, 4, base + 0x900, 1024, 3, 5);
    seed.desc(&buf, 5, base + 0xd00, 1, 2, 0);
    seed.hdr(&buf, 0x200, 0, 2);
    seed.hdr(&buf, 0x800, 0, 4);
    seed.availIdx(&buf, 2);
    seed.availRing(&buf, 0, 0);
    seed.availRing(&buf, 1, 3);

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.avail_addr = base + 0x80;
    v.used_addr = base + 0xe00;
    v.disk = &disk;
    v.queue_ready = 1;
    v.status = 0x4;

    v.process(&buf, base);

    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[0xe02..][0..2], .little)); // used->idx
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[0xe04..][0..4], .little)); // ring[0].id
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[0xe0c..][0..4], .little)); // ring[1].id
    try testing.expectEqual(@as(u16, 2), v.used_index);
    try testing.expectEqual(@as(u32, 0x1), v.interrupt_status); // one level bit, not two
}

// A malformed chain must still be COMPLETED — a used entry is published
// (with len 0) so the driver's descriptor isn't leaked and it doesn't hang. Sector past the disk end
// makes serviceChain bail before copying.
test "process: malformed chain still publishes a used entry (completes, no leak)" {
    const base: u64 = 0x8000_0000;
    var buf: [4096]u8 = @splat(0);
    var disk: [4096]u8 = @splat(0);

    seed.desc(&buf, 0, base + 0x200, 16, 1, 1);
    seed.desc(&buf, 1, base + 0x300, 1024, 3, 2);
    seed.desc(&buf, 2, base + 0x700, 1, 2, 0);
    seed.hdr(&buf, 0x200, 0, 0xffff_ffff); // sector far past disk → serviceChain returns null
    seed.availIdx(&buf, 1);
    seed.availRing(&buf, 0, 0);

    var v: Virtio = .{};
    v.desc_addr = base + 0x100;
    v.avail_addr = base + 0x80;
    v.used_addr = base + 0x900;
    v.disk = &disk;
    v.queue_ready = 1;
    v.status = 0x4;

    v.process(&buf, base); // must not panic

    // completion still published (id = head, len = 0) → descriptor returned, no driver hang ...
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[0x902..][0..2], .little)); // used->idx
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[0x904..][0..4], .little)); // ring[0].id
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[0x908..][0..4], .little)); // len = 0 (failed)
    // ... cursor advanced and the interrupt is raised.
    try testing.expectEqual(@as(u16, 1), v.last_avail_index);
    try testing.expect(v.irqAsserted());
}
