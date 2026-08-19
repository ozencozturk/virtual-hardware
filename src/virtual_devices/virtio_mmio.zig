//! The virtio-mmio transport (virtio 1.x, transport version 2): the register
//! file every virtio device on this bus answers, and the queues behind it.
//!
//! Modern layout only (VIRTIO_F_VERSION_1), so there is no legacy transitional
//! path. A device owns its configuration space and what its buffers mean; this
//! owns everything below `CONFIG_BASE`.

const std = @import("std");
const virtqueue = @import("virtqueue.zig");

const Queue = virtqueue.Queue;

/// Register offsets.
pub const Reg = enum(usize) {
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

/// Bits the driver writes to the status register as it brings a device up.
pub const Status = packed struct(u32) {
    acknowledge: bool = false,
    driver: bool = false,
    driver_ok: bool = false,
    features_ok: bool = false,
    _rsvd4: u2 = 0,
    needs_reset: bool = false,
    failed: bool = false,
    _rsvd8: u24 = 0,

    pub fn fromBits(v: u32) Status {
        return @bitCast(v);
    }

    pub fn toBits(self: Status) u32 {
        return @bitCast(self);
    }
};

/// Why a device is pulling its interrupt line.
pub const InterruptStatus = packed struct(u32) {
    used_buffer_notification: bool = false,
    config_change: bool = false,
    _rsvd: u30 = 0,

    pub fn fromBits(v: u32) InterruptStatus {
        return @bitCast(v);
    }

    pub fn toBits(self: InterruptStatus) u32 {
        return @bitCast(self);
    }

    /// Bits write-1-to-clear may touch, derived so it cannot drift.
    pub const W1C_MASK = (InterruptStatus{
        .used_buffer_notification = true,
        .config_change = true,
    }).toBits();
};

/// A 64-bit value the transport splits across two 32-bit registers. Fields
/// rather than shifts, because the two halves are otherwise transposable.
pub const Addr = packed struct(u64) {
    low: u32 = 0,
    hi: u32 = 0,

    pub fn fromBits(v: u64) Addr {
        return @bitCast(v);
    }

    pub fn toBits(self: Addr) u64 {
        return @bitCast(self);
    }
};

pub const MAGIC: u32 = 0x7472_6976; // "virt"
pub const VERSION: u32 = 2;
pub const VENDOR_ID: u32 = 0x554d_4551;
pub const VIRTIO_F_VERSION_1: u6 = 32;

/// The modern layout, which every device here offers on top of its own bits.
pub const BASE_FEATURES: u64 = @as(u64, 1) << VIRTIO_F_VERSION_1;

/// Width of the memory-mapped window a device answers on.
pub const MMIO_SIZE = 0x1000;

/// Where device configuration space begins; below it the transport answers.
pub const CONFIG_BASE = 0x100;

/// What a store asks of the device beyond updating transport state.
pub const Action = union(enum) {
    none,
    /// The driver kicked this queue.
    notify: u32,
    /// The driver wrote status zero, which resets the device.
    reset,
};

/// What distinguishes one device's transport from another's.
pub const Params = struct {
    /// Device type, as the driver reads it from the device-id register.
    device_id: u32,
    num_queues: usize,
    /// Ring depth offered to the driver. Power of two, as the spec requires.
    queue_size: u32,
    /// Device-type feature bits, offered alongside `BASE_FEATURES`.
    features: u64 = 0,
};

/// The transport register file and its queues, for a device of shape `p`.
pub fn Transport(comptime p: Params) type {
    return struct {
        const Self = @This();

        pub const DEVICE_ID = p.device_id;
        pub const NUM_QUEUES = p.num_queues;
        pub const QUEUE_SIZE = p.queue_size;
        /// Everything this device offers; `Addr` splits it for the transport.
        pub const FEATURES = BASE_FEATURES | p.features;

        status: u32 = 0,
        device_features_sel: u32 = 0,
        driver_features_sel: u32 = 0,
        driver_features: u64 = 0,
        queue_sel: u32 = 0,
        interrupt_status: u32 = 0,
        queues: [p.num_queues]Queue = @splat(.{}),

        /// Read a transport register. Offsets it does not define read zero.
        pub fn load(self: *const Self, offset: usize) u32 {
            return switch (@as(Reg, @enumFromInt(offset))) {
                .magic => MAGIC,
                .version => VERSION,
                .device_id => DEVICE_ID,
                .vendor_id => VENDOR_ID,
                .device_features => blk: {
                    const f = Addr.fromBits(FEATURES);
                    break :blk if (self.device_features_sel == 1) f.hi else f.low;
                },
                .queue_num_max => QUEUE_SIZE,
                .queue_ready => if (self.selected()) |q| q.ready else 0,
                .interrupt_status => self.interrupt_status,
                .status => self.status,
                else => 0,
            };
        }

        /// Write a transport register, answering what the device must do next.
        pub fn store(self: *Self, offset: usize, v: u32) Action {
            switch (@as(Reg, @enumFromInt(offset))) {
                .device_features_sel => self.device_features_sel = v,
                .driver_features_sel => self.driver_features_sel = v,
                .driver_features => {
                    var f = Addr.fromBits(self.driver_features);
                    if (self.driver_features_sel == 1) f.hi = v else f.low = v;
                    self.driver_features = f.toBits();
                },
                .queue_sel => self.queue_sel = v,
                .queue_num => (self.selectedMut() orelse return .none).num = v,
                .queue_ready => (self.selectedMut() orelse return .none).ready = v,
                .queue_desc_low => setHalf(&(self.selectedMut() orelse return .none).desc, .low, v),
                .queue_desc_high => setHalf(&(self.selectedMut() orelse return .none).desc, .hi, v),
                .queue_driver_low => setHalf(&(self.selectedMut() orelse return .none).avail, .low, v),
                .queue_driver_high => setHalf(&(self.selectedMut() orelse return .none).avail, .hi, v),
                .queue_device_low => setHalf(&(self.selectedMut() orelse return .none).used, .low, v),
                .queue_device_high => setHalf(&(self.selectedMut() orelse return .none).used, .hi, v),
                .queue_notify => return .{ .notify = v },
                // Write-1-to-clear, masked to the bits that exist: an ack into
                // reserved positions must not disturb a pending completion.
                .interrupt_ack => self.interrupt_status &= ~(v & InterruptStatus.W1C_MASK),
                .status => {
                    self.status = v;
                    if (v == 0) return .reset;
                },
                else => {},
            }
            return .none;
        }

        /// Whether the driver has finished bringing the device up.
        pub fn driverOk(self: *const Self) bool {
            return Status.fromBits(self.status).driver_ok;
        }

        /// Whether the driver accepted a feature this device offered.
        pub fn negotiated(self: *const Self, bit: u6) bool {
            return self.driver_features & (@as(u64, 1) << bit) != 0;
        }

        /// Queue `i`, or null when the index is outside this device's set.
        pub fn queue(self: *Self, i: u32) ?*Queue {
            return if (i < p.num_queues) &self.queues[@intCast(i)] else null;
        }

        /// Record a completed chain and raise the interrupt line.
        pub fn complete(self: *Self, i: u32, g: virtqueue.Guest, head: u16, len: u32) void {
            (self.queue(i) orelse return).complete(g, head, len);
            var isr = InterruptStatus.fromBits(self.interrupt_status);
            isr.used_buffer_notification = true;
            self.interrupt_status = isr.toBits();
        }

        /// Level-style: true while a completion is unacknowledged.
        pub fn irqAsserted(self: *const Self) bool {
            return self.interrupt_status != 0;
        }

        /// The queue `queue_sel` names, or null when it names none.
        fn selected(self: *const Self) ?*const Queue {
            return if (self.queue_sel < p.num_queues) &self.queues[@intCast(self.queue_sel)] else null;
        }

        /// The same, for writing. `queue_sel` is guest data: an out-of-range
        /// select must not index the array or fall back to a real queue.
        fn selectedMut(self: *Self) ?*Queue {
            return if (self.queue_sel < p.num_queues) &self.queues[@intCast(self.queue_sel)] else null;
        }
    };
}

/// Read `size` bytes of a device's configuration space.
///
/// Transport registers are 32-bit only; configuration space is read at each
/// field's own width, so a six-byte address arrives as six byte reads. Past the
/// end of the structure reads zero.
pub fn configRead(bytes: []const u8, offset: usize, size: usize) !u64 {
    if (size != 1 and size != 2 and size != 4) return error.AccessFault;
    if (offset % size != 0) return error.AccessFault;
    if (offset + size > bytes.len) return 0;
    return switch (size) {
        1 => bytes[offset],
        2 => std.mem.readInt(u16, bytes[offset..][0..2], .little),
        else => std.mem.readInt(u32, bytes[offset..][0..4], .little),
    };
}

/// Write `size` bytes into a device's configuration space. A write past the
/// end of the structure is dropped.
pub fn configWrite(bytes: []u8, offset: usize, size: usize, value: u64) !void {
    if (size != 1 and size != 2 and size != 4) return error.AccessFault;
    if (offset % size != 0) return error.AccessFault;
    if (offset + size > bytes.len) return;
    switch (size) {
        1 => bytes[offset] = @truncate(value),
        2 => std.mem.writeInt(u16, bytes[offset..][0..2], @truncate(value), .little),
        else => std.mem.writeInt(u32, bytes[offset..][0..4], @truncate(value), .little),
    }
}

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

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

const TestTransport = Transport(.{ .device_id = 3, .num_queues = 2, .queue_size = 64 });

test "transport: the probe registers read their fixed constants" {
    var t = TestTransport{};
    try testing.expectEqual(MAGIC, t.load(0x000));
    try testing.expectEqual(@as(u32, 2), t.load(0x004));
    try testing.expectEqual(@as(u32, 3), t.load(0x008));
    try testing.expectEqual(VENDOR_ID, t.load(0x00c));
    try testing.expectEqual(@as(u32, 64), t.load(0x034));
    try testing.expectEqual(@as(u32, 0), t.load(0x0fc));
}

test "transport: the feature words split across the two selectable halves" {
    var t = TestTransport{};
    _ = t.store(0x014, 0);
    try testing.expectEqual(@as(u32, 0), t.load(0x010));
    _ = t.store(0x014, 1);
    try testing.expectEqual(@as(u32, 1), t.load(0x010)); // VIRTIO_F_VERSION_1

    const WithBits = Transport(.{ .device_id = 2, .num_queues = 1, .queue_size = 8, .features = 0x220 });
    var w = WithBits{};
    _ = w.store(0x014, 0);
    try testing.expectEqual(@as(u32, 0x220), w.load(0x010));
    _ = w.store(0x014, 1);
    try testing.expectEqual(@as(u32, 1), w.load(0x010));
}

test "transport: negotiated reports what the driver wrote back" {
    var t = TestTransport{};
    try testing.expect(!t.negotiated(9));
    _ = t.store(0x024, 0);
    _ = t.store(0x020, 1 << 9);
    try testing.expect(t.negotiated(9));
    try testing.expect(!t.negotiated(10));
}

test "transport: the driver's feature words land in the half it selected" {
    var t = TestTransport{};
    _ = t.store(0x024, 0);
    _ = t.store(0x020, 0x1234);
    _ = t.store(0x024, 1);
    _ = t.store(0x020, 1);
    try testing.expectEqual(@as(u64, (@as(u64, 1) << 32) | 0x1234), t.driver_features);
}

test "transport: queue registers land in the selected queue only" {
    var t = TestTransport{};
    _ = t.store(0x030, 1); // queue_sel
    _ = t.store(0x038, 8); // queue_num
    _ = t.store(0x080, 0x1000); // desc low
    _ = t.store(0x084, 7); // desc high
    _ = t.store(0x044, 1); // ready

    try testing.expectEqual(@as(u32, 8), t.queues[1].num);
    try testing.expectEqual(@as(u64, 0x0000_0007_0000_1000), t.queues[1].desc);
    try testing.expectEqual(@as(u32, 1), t.load(0x044));
    try testing.expectEqual(@as(u32, 0), t.queues[0].num);
}

test "transport: a select outside the queue set touches nothing" {
    var t = TestTransport{};
    _ = t.store(0x030, 99);
    _ = t.store(0x038, 8);
    _ = t.store(0x044, 1);
    try testing.expectEqual(@as(u32, 0), t.load(0x044));
    try testing.expectEqual(@as(u32, 0), t.queues[0].num);
    try testing.expectEqual(@as(u32, 0), t.queues[1].num);
}

test "transport: a notify answers the queue the driver kicked" {
    var t = TestTransport{};
    try testing.expectEqual(Action{ .notify = 1 }, t.store(0x050, 1));
    try testing.expectEqual(Action.none, t.store(0x038, 4));
}

test "transport: status zero asks for a reset and anything else does not" {
    var t = TestTransport{};
    try testing.expectEqual(Action.none, t.store(0x070, 7));
    try testing.expectEqual(@as(u32, 7), t.load(0x070));
    try testing.expectEqual(Action.reset, t.store(0x070, 0));
}

test "transport: driverOk follows the status bit the driver sets last" {
    var t = TestTransport{};
    try testing.expect(!t.driverOk());
    _ = t.store(0x070, (Status{ .acknowledge = true, .driver = true }).toBits());
    try testing.expect(!t.driverOk());
    _ = t.store(0x070, (Status{ .driver_ok = true }).toBits());
    try testing.expect(t.driverOk());
}

test "transport: an acknowledge clears only the bits that exist" {
    var ram: [0x4000]u8 = @splat(0);
    const g = virtqueue.Guest{ .memory = &ram, .base = 0 };
    var t = TestTransport{};
    t.queues[0] = .{ .num = 4, .ready = 1, .desc = 0x1000, .avail = 0x2000, .used = 0x3000 };

    t.complete(0, g, 0, 16);
    try testing.expect(t.irqAsserted());

    // Reserved bits: the pending completion must survive an ack into them.
    _ = t.store(0x064, ~InterruptStatus.W1C_MASK);
    try testing.expect(t.irqAsserted());

    _ = t.store(0x064, InterruptStatus.W1C_MASK);
    try testing.expect(!t.irqAsserted());
}

test "transport: complete on a queue outside the set does nothing" {
    var ram: [0x4000]u8 = @splat(0);
    const g = virtqueue.Guest{ .memory = &ram, .base = 0 };
    var t = TestTransport{};
    t.complete(9, g, 0, 16);
    try testing.expect(!t.irqAsserted());
}

test "config: a field is readable at the width its driver uses" {
    const c = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x01, 0x00 };
    try testing.expectEqual(@as(u64, 0x52), try configRead(&c, 0, 1));
    try testing.expectEqual(@as(u64, 0x56), try configRead(&c, 5, 1));
    try testing.expectEqual(@as(u64, 0x5452), try configRead(&c, 0, 2));
    try testing.expectEqual(@as(u64, 0x1200_5452), try configRead(&c, 0, 4));
    try testing.expectEqual(@as(u64, 1), try configRead(&c, 6, 2));
}

test "config: a width or alignment no driver uses is refused" {
    const c: [8]u8 = @splat(0);
    try testing.expectError(error.AccessFault, configRead(&c, 0, 3));
    try testing.expectError(error.AccessFault, configRead(&c, 0, 8));
    try testing.expectError(error.AccessFault, configRead(&c, 1, 2));
    try testing.expectError(error.AccessFault, configRead(&c, 2, 4));
}

test "config: past the end of the structure reads zero and drops writes" {
    var c: [8]u8 = @splat(0);
    try testing.expectEqual(@as(u64, 0), try configRead(&c, 8, 4));
    try configWrite(&c, 8, 4, 0xffff_ffff);
    try testing.expectEqual(@as(u64, 0), try configRead(&c, 4, 4));
}

test "config: a write lands at the width it was made" {
    var c: [8]u8 = @splat(0);
    try configWrite(&c, 4, 4, 0xdead_beef);
    try testing.expectEqual(@as(u64, 0xdead_beef), try configRead(&c, 4, 4));
    try configWrite(&c, 0, 1, 0xab);
    try testing.expectEqual(@as(u64, 0xab), try configRead(&c, 0, 1));
}
