//! virtio-balloon over the memory-mapped transport: memory the guest gives back
//! when the owner asks for it.
//!
//! The owner sets a target; the guest frees that many pages and posts their
//! numbers on the inflate queue. The deflate queue is the way back. This device
//! names the pages and counts them; what to do with them is the owner's.

const std = @import("std");
const mmio = @import("virtio_mmio.zig");
const virtqueue = @import("virtqueue.zig");

pub const Guest = virtqueue.Guest;

/// Page size the page numbers in a request count in, fixed by the spec at
/// 4 KiB whatever the guest's own page size is.
pub const PAGE_BYTES: u64 = 4096;

/// VIRTIO_BALLOON_F_MUST_TELL_HOST: the guest tells the device before it uses a
/// page again, rather than assuming it may.
pub const F_MUST_TELL_HOST: u6 = 0;

/// VIRTIO_BALLOON_F_DEFLATE_ON_OOM: the guest may take pages back when it would
/// otherwise run out, instead of dying with the balloon still inflated.
pub const F_DEFLATE_ON_OOM: u6 = 2;

/// `struct virtio_balloon_config`. Both counts are in pages.
const Config = extern struct {
    /// What the owner is asking for.
    num_pages: u32 = 0,
    /// What the guest has actually given up.
    actual: u32 = 0,
};

/// Queue indices fixed by the spec for a balloon without statistics.
const INFLATE_QUEUE = 0;
const DEFLATE_QUEUE = 1;
const NUM_QUEUES = 2;

/// Ring depth offered to the driver. Power of two, as the spec requires.
pub const QUEUE_SIZE: u32 = 8;

/// Page numbers one request carries at most, so a walk is bounded.
const MAX_PAGES_PER_REQUEST = 256;

pub const VirtioBalloon = struct {
    pub const MMIO_SIZE = mmio.MMIO_SIZE;

    const Transport = mmio.Transport(.{
        .device_id = 5,
        .num_queues = NUM_QUEUES,
        .queue_size = QUEUE_SIZE,
        .features = (@as(u64, 1) << F_MUST_TELL_HOST) | (@as(u64, 1) << F_DEFLATE_ON_OOM),
    });

    transport: Transport = .{},
    config: Config = .{},

    /// Pages given up and taken back over this device's life.
    inflated: u64 = 0,
    deflated: u64 = 0,

    /// Read a register. Accesses must be aligned words.
    pub fn load(self: *const VirtioBalloon, offset: usize, size: usize) !u64 {
        if (offset >= mmio.CONFIG_BASE) {
            return mmio.configRead(std.mem.asBytes(&self.config), offset - mmio.CONFIG_BASE, size);
        }
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        return self.transport.load(offset);
    }

    /// Write a register, answering what the device must do next.
    ///
    /// Unlike the other devices here, configuration space is writable: `actual`
    /// is how the driver reports what it managed to free.
    pub fn store(self: *VirtioBalloon, offset: usize, size: usize, value: u64) !mmio.Action {
        if (offset >= mmio.CONFIG_BASE) {
            // Only what the driver reports back is its to write; the target is
            // the owner's, and a driver that overwrote it would be answering
            // its own question.
            const at = offset - mmio.CONFIG_BASE;
            if (at >= @offsetOf(Config, "actual")) {
                try mmio.configWrite(std.mem.asBytes(&self.config), at, size, value);
            }
            return .none;
        }
        if (size != 4 or offset % 4 != 0) return error.AccessFault;
        const action = self.transport.store(offset, @truncate(value));
        switch (action) {
            .reset => self.reset(),
            else => {},
        }
        return action;
    }

    /// Ask the guest for `want` pages. The guest works toward it in its own
    /// time; nothing here forces it.
    pub fn setTarget(self: *VirtioBalloon, want: u32) void {
        self.config.num_pages = want;
        var isr = mmio.InterruptStatus.fromBits(self.transport.interrupt_status);
        isr.config_change = true;
        self.transport.interrupt_status = isr.toBits();
    }

    /// Pages the owner has asked for.
    pub fn target(self: *const VirtioBalloon) u32 {
        return self.config.num_pages;
    }

    /// Pages the guest says it has given up.
    pub fn given(self: *const VirtioBalloon) u32 {
        return self.config.actual;
    }

    /// Serve the chains posted to `queue`.
    pub fn service(self: *VirtioBalloon, queue: u32, g: Guest) void {
        if (queue != INFLATE_QUEUE and queue != DEFLATE_QUEUE) return;
        if (!self.transport.driverOk()) return;
        const q = self.transport.queue(queue) orelse return;
        if (!q.live()) return;
        while (q.nextHead(g)) |head| {
            const named = count(g, q.*, head);
            if (queue == INFLATE_QUEUE) self.inflated += named else self.deflated += named;
            // The pages are named in driver-readable buffers; nothing goes back.
            self.transport.complete(queue, g, head, 0);
        }
    }

    /// True while a completion is unacknowledged.
    pub fn irqAsserted(self: *const VirtioBalloon) bool {
        return self.transport.irqAsserted();
    }

    /// Where page number `pfn` starts in guest physical memory.
    pub fn addressOf(pfn: u32) u64 {
        return @as(u64, pfn) * PAGE_BYTES;
    }

    /// Call `each` with the guest physical address of every page a chain names;
    /// returns how many there were.
    pub fn eachPage(
        self: *const VirtioBalloon,
        g: Guest,
        queue: u32,
        head: u16,
        ctx: anytype,
        comptime each: fn (@TypeOf(ctx), u64) void,
    ) u32 {
        if (queue >= Transport.NUM_QUEUES) return 0;
        var seen: u32 = 0;
        var c = self.transport.queues[queue].chain(g, head);
        while (c.next()) |d| {
            if (d.flags.write) continue;
            var at: u32 = 0;
            while (at + 4 <= d.len and seen < MAX_PAGES_PER_REQUEST) : (at += 4) {
                const pfn = g.read(u32, d.addr + at) orelse break;
                each(ctx, addressOf(pfn));
                seen += 1;
            }
        }
        return seen;
    }

    fn reset(self: *VirtioBalloon) void {
        // The target is the owner's and the totals describe the run; only what
        // the driver reported having freed goes with the driver.
        const num_pages = self.config.num_pages;
        const inflated = self.inflated;
        const deflated = self.deflated;
        self.* = .{};
        self.config.num_pages = num_pages;
        self.inflated = inflated;
        self.deflated = deflated;
    }
};

/// How many page numbers a chain names.
fn count(g: Guest, q: virtqueue.Queue, head: u16) u32 {
    var seen: u32 = 0;
    var c = q.chain(g, head);
    while (c.next()) |d| {
        if (d.flags.write) continue;
        var at: u32 = 0;
        while (at + 4 <= d.len and seen < MAX_PAGES_PER_REQUEST) : (at += 4) {
            _ = g.read(u32, d.addr + at) orelse break;
            seen += 1;
        }
    }
    return seen;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const BASE: u64 = 0;
const IN_DESC: u64 = 0x1000;
const IN_AVAIL: u64 = 0x2000;
const IN_USED: u64 = 0x3000;
const DE_DESC: u64 = 0x4000;
const DE_AVAIL: u64 = 0x5000;
const DE_USED: u64 = 0x6000;

fn bringUp(b: *VirtioBalloon, queue: u32, num: u32, desc: u32, avail: u32, used: u32) !void {
    _ = try b.store(0x030, 4, queue);
    _ = try b.store(0x038, 4, num);
    _ = try b.store(0x080, 4, desc);
    _ = try b.store(0x090, 4, avail);
    _ = try b.store(0x0a0, 4, used);
    _ = try b.store(0x044, 4, 1);
}

fn driverUp(b: *VirtioBalloon) !void {
    _ = try b.store(0x070, 4, (mmio.Status{
        .acknowledge = true,
        .driver = true,
        .features_ok = true,
        .driver_ok = true,
    }).toBits());
}

/// Post a buffer naming `pfns` as a driver-readable descriptor.
fn postPages(g: Guest, desc: u64, avail: u64, at: u64, pfns: []const u32) void {
    for (pfns, 0..) |pfn, i| g.write(u32, at + @as(u64, i) * 4, pfn);
    g.write(u64, desc, at);
    g.write(u32, desc + 8, @intCast(pfns.len * 4));
    g.write(u16, desc + 12, 0);
    g.write(u16, avail + 4, 0);
    g.write(u16, avail + 2, 1);
}

test "balloon: identifies as a modern virtio balloon" {
    var b = VirtioBalloon{};
    try testing.expectEqual(@as(u64, mmio.MAGIC), try b.load(0x000, 4));
    try testing.expectEqual(@as(u64, 2), try b.load(0x004, 4));
    try testing.expectEqual(@as(u64, 5), try b.load(0x008, 4)); // balloon
    try testing.expectEqual(@as(u64, QUEUE_SIZE), try b.load(0x034, 4));
    _ = try b.store(0x014, 4, 0);
    const offered = (@as(u64, 1) << F_MUST_TELL_HOST) | (@as(u64, 1) << F_DEFLATE_ON_OOM);
    try testing.expectEqual(offered, try b.load(0x010, 4));
}

test "balloon: an unaligned or non-word access faults" {
    var b = VirtioBalloon{};
    try testing.expectError(error.AccessFault, b.load(0x002, 4));
    try testing.expectError(error.AccessFault, b.load(0x000, 2));
    try testing.expectError(error.AccessFault, b.store(0x070, 1, 0));
}

test "balloon: a target the owner sets is what the guest reads" {
    var b = VirtioBalloon{};
    try testing.expectEqual(@as(u32, 0), b.target());
    b.setTarget(512);
    try testing.expectEqual(@as(u64, 512), try b.load(0x100, 4));
    // A target change is something the guest is told about.
    try testing.expect(b.irqAsserted());
}

test "balloon: the driver reports back how much it managed to free" {
    var b = VirtioBalloon{};
    b.setTarget(64);
    _ = try b.store(0x104, 4, 40);
    try testing.expectEqual(@as(u32, 40), b.given());
    try testing.expectEqual(@as(u64, 40), try b.load(0x104, 4));
    // The target is the owner's to set, not the driver's.
    _ = try b.store(0x100, 4, 9999);
    try testing.expectEqual(@as(u32, 64), b.target());
}

test "balloon: inflating counts the pages the guest gave up" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var b = VirtioBalloon{};
    try bringUp(&b, INFLATE_QUEUE, 4, IN_DESC, IN_AVAIL, IN_USED);
    try driverUp(&b);
    b.setTarget(3);
    postPages(g, IN_DESC, IN_AVAIL, 0x8000, &.{ 10, 11, 12 });

    b.service(INFLATE_QUEUE, g);

    try testing.expectEqual(@as(u64, 3), b.inflated);
    try testing.expectEqual(@as(u64, 0), b.deflated);
    // Page numbers are read, never written, so nothing is reported back.
    try testing.expectEqual(@as(?u32, 0), g.read(u32, IN_USED + 8));
    try testing.expectEqual(@as(?u16, 1), g.read(u16, IN_USED + 2));
}

test "balloon: deflating counts the pages the guest took back" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var b = VirtioBalloon{};
    try bringUp(&b, DEFLATE_QUEUE, 4, DE_DESC, DE_AVAIL, DE_USED);
    try driverUp(&b);
    postPages(g, DE_DESC, DE_AVAIL, 0x8000, &.{ 10, 11 });

    b.service(DEFLATE_QUEUE, g);

    try testing.expectEqual(@as(u64, 2), b.deflated);
    try testing.expectEqual(@as(u64, 0), b.inflated);
}

test "balloon: the pages a request names are readable by the owner" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var b = VirtioBalloon{};
    try bringUp(&b, INFLATE_QUEUE, 4, IN_DESC, IN_AVAIL, IN_USED);
    try driverUp(&b);
    postPages(g, IN_DESC, IN_AVAIL, 0x8000, &.{ 2, 5 });

    const Seen = struct {
        var at: [8]u64 = @splat(0);
        var n: usize = 0;
        fn note(_: void, addr: u64) void {
            at[n] = addr;
            n += 1;
        }
    };
    Seen.n = 0;
    const found = b.eachPage(g, INFLATE_QUEUE, 0, {}, Seen.note);

    try testing.expectEqual(@as(u32, 2), found);
    try testing.expectEqual(@as(u64, 2 * PAGE_BYTES), Seen.at[0]);
    try testing.expectEqual(@as(u64, 5 * PAGE_BYTES), Seen.at[1]);
}

test "balloon: nothing is counted before the driver is up" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var b = VirtioBalloon{};
    try bringUp(&b, INFLATE_QUEUE, 4, IN_DESC, IN_AVAIL, IN_USED);
    postPages(g, IN_DESC, IN_AVAIL, 0x8000, &.{ 1, 2 });

    b.service(INFLATE_QUEUE, g);
    try testing.expectEqual(@as(u64, 0), b.inflated);
}

test "balloon: a kick on a queue this device does not have counts nothing" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var b = VirtioBalloon{};
    try bringUp(&b, INFLATE_QUEUE, 4, IN_DESC, IN_AVAIL, IN_USED);
    try driverUp(&b);
    postPages(g, IN_DESC, IN_AVAIL, 0x8000, &.{1});

    b.service(9, g);
    try testing.expectEqual(@as(u64, 0), b.inflated);
}

test "balloon: a reset clears the rings and keeps the target and the totals" {
    const ram = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const g = Guest{ .memory = ram, .base = BASE };

    var b = VirtioBalloon{};
    try bringUp(&b, INFLATE_QUEUE, 4, IN_DESC, IN_AVAIL, IN_USED);
    try driverUp(&b);
    b.setTarget(16);
    postPages(g, IN_DESC, IN_AVAIL, 0x8000, &.{ 1, 2 });
    b.service(INFLATE_QUEUE, g);
    _ = try b.store(0x104, 4, 2);

    _ = try b.store(0x070, 4, 0);

    try testing.expectEqual(@as(u32, 0), b.transport.queues[INFLATE_QUEUE].num);
    try testing.expectEqual(@as(u32, 16), b.target());
    try testing.expectEqual(@as(u64, 2), b.inflated);
    // What the driver had freed went with the driver.
    try testing.expectEqual(@as(u32, 0), b.given());
}
