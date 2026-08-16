//! A local APIC (xAPIC) whose timer is scheduled against a caller-supplied
//! clock rather than a real one.
//!
//! Every entry point that depends on time takes `now` as an argument, so the
//! model never reads a clock itself and a caller can drive it from any
//! monotonic source.
//!
//! Two timer modes are modelled. In **TSC-deadline** mode the guest names an
//! absolute point in time and the timer fires when `now` reaches it. In the
//! classic mode an initial count decrements at the APIC bus clock, scaled by
//! `tsc_per_bus_tick` and the guest-programmed divisor, one-shot or periodic.
//!
//! Also modelled: the register window, the interrupt request and in-service
//! state behind `raise`/`accept`/`pendingVector`, and the spurious-interrupt
//! and priority registers a guest reads during bring-up.

const std = @import("std");

/// An MMIO register within the 4 KiB APIC window (Intel SDM Vol 3, 11.4.1).
/// Non-exhaustive: the three
/// `*_base` entries head a 0x80 window of eight 32-bit words on a 0x10 stride,
/// which is a range rather than a value and so is decoded in `else` — see
/// `bitmapWindow`. Unmodelled offsets land there too and read as zero.
pub const Reg = enum(usize) {
    id = 0x020,
    version = 0x030,
    tpr = 0x080, // task priority
    ppr = 0x0A0, // processor priority (read-only)
    eoi = 0x0B0, // end of interrupt (write-only)
    ldr = 0x0D0, // logical destination
    dfr = 0x0E0, // destination format
    svr = 0x0F0, // spurious interrupt vector
    isr_base = 0x100, // 8 x 32-bit, stride 0x10
    tmr_base = 0x180,
    irr_base = 0x200,
    esr = 0x280, // error status
    icr_low = 0x300,
    icr_high = 0x310,
    lvt_timer = 0x320,
    lvt_thermal = 0x330,
    lvt_perf = 0x340,
    lvt_lint0 = 0x350,
    lvt_lint1 = 0x360,
    lvt_error = 0x370,
    timer_icr = 0x380, // initial count
    timer_ccr = 0x390, // current count (read-only)
    timer_dcr = 0x3E0, // divide configuration
    _,
};

/// Bytes spanned by one 256-bit bitmap register (8 words, 0x10 apart).
const BITMAP_SPAN = 0x80;

/// Offset within the bitmap window headed by `base`, or null if `offset` is
/// outside it.
fn bitmapWindow(offset: usize, base: Reg) ?usize {
    const b = @intFromEnum(base);
    if (offset < b or offset >= b + BITMAP_SPAN) return null;
    return offset - b;
}

/// Timer operating mode, LVT_TIMER bits 18:17.
pub const TimerMode = enum(u2) {
    one_shot = 0b00,
    periodic = 0b01,
    tsc_deadline = 0b10,
    /// 0b11 is reserved. A guest can still write it, so the enum stays open.
    _,
};

/// One Local Vector Table entry (SDM Vol 3, Figure 11-8).
///
/// A single layout covers all six entries; fields that apply to only some of
/// them read back as whatever the guest wrote. `timer_mode` is meaningful only
/// in LVT_TIMER, and `polarity`/`remote_irr`/`trigger_mode` only in LINT0/1.
pub const LvtEntry = packed struct(u32) {
    vector: u8 = 0,
    delivery_mode: u3 = 0,
    _rsvd11: u1 = 0,
    delivery_status: u1 = 0,
    polarity: u1 = 0,
    remote_irr: u1 = 0,
    trigger_mode: u1 = 0,
    /// Bit 16. Set at reset, which is why every entry defaults to masked.
    masked: bool = true,
    timer_mode: TimerMode = .one_shot,
    _rsvd19: u13 = 0,
};

/// Spurious-interrupt vector register (0x0F0).
pub const Svr = packed struct(u32) {
    vector: u8 = 0xFF,
    /// Bit 8 — software enable. The APIC comes out of reset with it clear.
    apic_enabled: bool = false,
    focus_checking: bool = false,
    _rsvd10: u2 = 0,
    suppress_eoi_broadcast: bool = false,
    _rsvd13: u19 = 0,
};

/// Task- and processor-priority registers. Only the priority *class* (the top
/// nibble of the low byte) gates delivery; the sub-class is stored and ignored.
pub const Priority = packed struct(u32) {
    sub_class: u4 = 0,
    class: u4 = 0,
    _rsvd8: u24 = 0,
};

/// Divide-configuration register (0x3E0).
///
/// The divisor is encoded across bits [3,1:0] — **bit 2 is not part of it**.
/// Splitting the field into `low`/`high` around a named reserved bit is the
/// point of modelling this one as a struct: the hardware's oddity becomes
/// structural instead of a comment above a mask that is easy to get wrong.
pub const DivideConfig = packed struct(u32) {
    low: u2 = 0,
    _rsvd2: u1 = 0,
    high: u1 = 0,
    _rsvd4: u28 = 0,

    /// log2 of the divisor. The two halves concatenate to a 3-bit value;
    /// 0b111 means "divide by 1", every other value is 2^(n+1).
    fn shift(self: DivideConfig) u5 {
        const encoded: u3 = (@as(u3, self.high) << 2) | self.low;
        return if (encoded == 0b111) 0 else @as(u5, encoded) + 1;
    }

    fn divisor(self: DivideConfig) u64 {
        return @as(u64, 1) << self.shift();
    }
};

/// Version register (0x030), read-only.
pub const Version = packed struct(u32) {
    version: u8 = 0x14, // integrated APIC
    _rsvd8: u8 = 0,
    max_lvt_entry: u8 = 5, // what a modern LAPIC advertises
    suppress_eoi_broadcast: bool = false,
    _rsvd25: u7 = 0,
};

/// Where a vector lives in the 256-bit IRR/ISR bitmaps: which of the eight
/// 32-bit words, and which bit within it.
const VectorBit = packed struct(u8) {
    bit: u5,
    word: u3,
};

/// The same 8 bits viewed as a priority (SDM Vol 3, 11.8.3.1).
const VectorPriority = packed struct(u8) {
    sub_class: u4,
    class: u4,
};

/// A vector's priority class — the top 4 bits.
fn priorityClass(vector: u8) u4 {
    return @as(VectorPriority, @bitCast(vector)).class;
}

pub const Lapic = struct {
    /// Clock ticks per APIC bus-clock tick, before the guest's divisor. Supplied
    /// rather than derived here: it relates two frequencies the machine chooses.
    /// An inexact ratio truncates, so every period the guest programs lands
    /// slightly short of what it asked for and the error accumulates — assert
    /// the division is exact where the two frequencies are declared.
    tsc_per_bus_tick: u64,
    svr: Svr = .{},
    tpr: Priority = .{},
    /// Stored verbatim: nothing here decodes them, so there is nothing to model.
    ldr: u32 = 0,
    dfr: u32 = 0xFFFF_FFFF,
    esr: u32 = 0,
    lvt_timer: LvtEntry = .{},
    lvt_thermal: LvtEntry = .{},
    lvt_perf: LvtEntry = .{},
    lvt_lint0: LvtEntry = .{},
    lvt_lint1: LvtEntry = .{},
    lvt_error: LvtEntry = .{},

    timer_icr: u32 = 0,
    timer_dcr: DivideConfig = .{},
    /// Absolute value on the caller's clock at which the timer fires. Null =
    /// disarmed.
    deadline: ?u64 = null,
    /// Last value the guest wrote to IA32_TSC_DEADLINE, so a read-back returns
    /// what it wrote. Zero means disarmed.
    tsc_deadline_msr: u64 = 0,

    /// Interrupt request / in-service registers, 256 bits each.
    irr: [8]u32 = @splat(0),
    isr: [8]u32 = @splat(0),

    /// Whether the guest has software-enabled the APIC (SVR bit 8).
    pub fn enabled(self: *const Lapic) bool {
        return self.svr.apic_enabled;
    }

    // ---- timer ------------------------------------------------------------

    /// Clock ticks one full initial-count period takes.
    fn periodTicks(self: *const Lapic) u64 {
        const count: u64 = self.timer_icr;
        return count * self.tsc_per_bus_tick * self.timer_dcr.divisor();
    }

    fn periodic(self: *const Lapic) bool {
        return self.lvt_timer.timer_mode == .periodic;
    }

    /// TSC-deadline mode: the timer is armed by writing an absolute TSC value
    /// to IA32_TSC_DEADLINE rather than by counting down an initial count.
    fn tscDeadlineMode(self: *const Lapic) bool {
        return self.lvt_timer.timer_mode == .tsc_deadline;
    }

    /// Guest wrote IA32_TSC_DEADLINE (0x6E0). The value is an absolute point on
    /// the caller's clock; zero disarms.
    ///
    pub fn writeTscDeadline(self: *Lapic, value: u64) void {
        self.tsc_deadline_msr = value;
        self.deadline = if (value == 0) null else value;
    }

    /// The deadline a caller should act on, or null.
    ///
    /// Null is routine rather than exceptional, and there are three ways to it:
    /// the guest wrote zero, which disarms; the LVT entry is masked; or the
    /// timer just fired, since TSC-deadline mode is one-shot and `expireTimer`
    /// consumes the deadline. The last happens on EVERY tick, between delivery
    /// and the handler re-arming.
    ///
    /// A masked entry still counts down and still expires — it just delivers
    /// nothing — so the mask is filtered HERE and not in `deadline` or
    /// `expireTimer`. The timer goes on behaving normally while a caller asking
    /// what is worth waiting for is told there is nothing.
    pub fn interruptDeadline(self: *const Lapic) ?u64 {
        if (self.lvt_timer.masked) return null;
        return self.deadline;
    }

    pub fn readTscDeadline(self: *const Lapic) u64 {
        return self.tsc_deadline_msr;
    }

    /// (Re)arm from the current initial count, or disarm when the count is zero
    /// or the LVT entry is masked — writing 0 to the initial count is precisely
    /// how the guest stops the timer.
    fn armTimer(self: *Lapic, now: u64) void {
        if (self.timer_icr == 0 or self.lvt_timer.masked) {
            self.deadline = null;
            return;
        }
        self.deadline = now + self.periodTicks();
    }

    /// The timer's current count, derived from how far the clock has
    /// advanced. Reading it must not have side effects.
    fn currentCount(self: *const Lapic, now: u64) u32 {
        const deadline = self.deadline orelse return 0;
        if (now >= deadline) return 0;
        const remaining = deadline - now;
        const per_tick = self.tsc_per_bus_tick * self.timer_dcr.divisor();
        return @intCast(@min(remaining / per_tick, std.math.maxInt(u32)));
    }

    /// If the timer is due at `now`, raise its vector and re-arm (periodic) or
    /// disarm (one-shot). Returns true when it fired.
    ///
    pub fn expireTimer(self: *Lapic, now: u64) bool {
        const deadline = self.deadline orelse return false;
        if (now < deadline) return false;

        if (!self.lvt_timer.masked) self.raise(self.lvt_timer.vector);

        if (self.tscDeadlineMode()) {
            // One-shot by architecture: the deadline is consumed on expiry and
            // the guest re-arms by writing the MSR again.
            self.tsc_deadline_msr = 0;
            self.deadline = null;
            return true;
        }

        if (self.periodic()) {
            // Advance by whole periods rather than restarting from `now`, so a
            // late expiry does not shift the phase of every subsequent tick.
            const period = self.periodTicks();
            if (period == 0) {
                self.deadline = null;
            } else {
                var next = deadline;
                while (next <= now) next += period;
                self.deadline = next;
            }
        } else {
            self.deadline = null;
        }
        return true;
    }

    // ---- interrupt state --------------------------------------------------

    /// Mark `vector` as requested. Vectors below 16 are reserved by the
    /// architecture for exceptions and are not deliverable through the APIC.
    pub fn raise(self: *Lapic, vector: u8) void {
        if (vector < 16) return;
        const at: VectorBit = @bitCast(vector);
        self.irr[at.word] |= @as(u32, 1) << at.bit;
    }

    fn highestSet(bits: *const [8]u32) ?u8 {
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            if (bits[i] == 0) continue;
            const at = VectorBit{
                .word = @intCast(i),
                .bit = @intCast(31 - @clz(bits[i])),
            };
            return @bitCast(at);
        }
        return null;
    }

    /// Processor priority (SDM Vol 3, 11.8.3.1): the MAXIMUM of the task
    /// priority and the highest in-service class. Returning the in-service class
    /// alone would report a priority *below* TPR whenever the guest has raised
    /// TPR above whatever is in service.
    ///
    /// When TPR wins it is returned whole, sub-class included; when the
    /// in-service class wins the sub-class reads zero.
    fn processorPriority(self: *const Lapic) Priority {
        const isr_class = if (highestSet(&self.isr)) |v| priorityClass(v) else 0;
        if (self.tpr.class >= isr_class) return self.tpr;
        return .{ .class = isr_class };
    }

    /// The highest-priority requested vector that is eligible for delivery, or
    /// null. Priority is the vector's top 4 bits; an interrupt is blocked by
    /// anything of equal or higher priority already in service, and by TPR.
    pub fn pendingVector(self: *const Lapic) ?u8 {
        if (!self.enabled()) return null;
        const candidate = highestSet(&self.irr) orelse return null;

        const candidate_prio = priorityClass(candidate);
        if (candidate_prio <= self.tpr.class) return null;
        if (highestSet(&self.isr)) |in_service| {
            if (candidate_prio <= priorityClass(in_service)) return null;
        }
        return candidate;
    }

    /// Move `vector` from requested to in-service — call once it has actually
    /// been injected into the vCPU.
    pub fn accept(self: *Lapic, vector: u8) void {
        const at: VectorBit = @bitCast(vector);
        const bit = @as(u32, 1) << at.bit;
        self.irr[at.word] &= ~bit;
        self.isr[at.word] |= bit;
    }

    /// End-of-interrupt: clear the highest in-service vector.
    fn eoi(self: *Lapic) void {
        if (highestSet(&self.isr)) |vector| {
            const at: VectorBit = @bitCast(vector);
            self.isr[at.word] &= ~(@as(u32, 1) << at.bit);
        }
    }

    // ---- MMIO -------------------------------------------------------------

    /// Read a 32-bit APIC register. `now` is the current clock value, needed
    /// only for the timer's current-count register.
    ///
    /// This and `write` are the only places the register structs meet the raw
    /// dwords the guest sees, so they are the only places that `@bitCast`.
    pub fn read(self: *const Lapic, offset: usize, now: u64) u32 {
        return switch (@as(Reg, @enumFromInt(offset))) {
            .id => 0, // single vCPU, APIC id 0 (bits 31:24)
            .version => @bitCast(Version{}),
            .tpr => @bitCast(self.tpr),
            .ppr => @bitCast(self.processorPriority()),
            .ldr => self.ldr,
            .dfr => self.dfr,
            .svr => @bitCast(self.svr),
            .esr => self.esr,
            .lvt_timer => @bitCast(self.lvt_timer),
            .lvt_thermal => @bitCast(self.lvt_thermal),
            .lvt_perf => @bitCast(self.lvt_perf),
            .lvt_lint0 => @bitCast(self.lvt_lint0),
            .lvt_lint1 => @bitCast(self.lvt_lint1),
            .lvt_error => @bitCast(self.lvt_error),
            .timer_icr => self.timer_icr,
            .timer_ccr => self.currentCount(now),
            .timer_dcr => @bitCast(self.timer_dcr),
            else => if (bitmapWindow(offset, .isr_base)) |rel|
                self.bitmapRead(&self.isr, rel)
            else if (bitmapWindow(offset, .irr_base)) |rel|
                self.bitmapRead(&self.irr, rel)
            else
                0, // trigger-mode (tmr_base) reads edge-only, as does anything unmodelled
        };
    }

    fn bitmapRead(self: *const Lapic, bits: *const [8]u32, rel: usize) u32 {
        _ = self;
        // The 8 words are spaced 16 bytes apart; anything off-stride reads 0.
        if (rel % 0x10 != 0) return 0;
        return bits[rel / 0x10];
    }

    /// Write a 32-bit APIC register. `now` is the current clock value, used to
    /// anchor timer deadlines.
    pub fn write(self: *Lapic, offset: usize, value: u32, now: u64) void {
        switch (@as(Reg, @enumFromInt(offset))) {
            .tpr => self.tpr = @bitCast(value),
            .eoi => self.eoi(),
            .ldr => self.ldr = value,
            .dfr => self.dfr = value,
            .esr => self.esr = 0, // any write clears
            .svr => self.svr = @bitCast(value),
            .lvt_thermal => self.lvt_thermal = @bitCast(value),
            .lvt_perf => self.lvt_perf = @bitCast(value),
            .lvt_lint0 => self.lvt_lint0 = @bitCast(value),
            .lvt_lint1 => self.lvt_lint1 = @bitCast(value),
            .lvt_error => self.lvt_error = @bitCast(value),
            .lvt_timer => {
                const was_masked = self.lvt_timer.masked;
                self.lvt_timer = @bitCast(value);
                // Unmasking with a count already loaded starts the timer;
                // masking stops it.
                if (self.lvt_timer.masked) {
                    self.deadline = null;
                } else if (self.tscDeadlineMode()) {
                    // Deadlines come from the MSR in this mode; the initial
                    // count is meaningless and must not re-arm anything.
                    self.deadline = if (self.tsc_deadline_msr == 0) null else self.tsc_deadline_msr;
                } else if (was_masked and self.timer_icr != 0) {
                    self.armTimer(now);
                }
            },
            .timer_icr => {
                self.timer_icr = value;
                // Ignored in TSC-deadline mode (SDM: the initial-count register
                // has no effect there).
                if (!self.tscDeadlineMode()) self.armTimer(now);
            },
            .timer_dcr => {
                self.timer_dcr = @bitCast(value);
                if (self.deadline != null) self.armTimer(now);
            },
            // ICR (IPIs) is accepted and dropped. Inter-processor interrupts
            // are not modelled, so a multi-processor guest needs this filling in.
            Reg.icr_low, .icr_high => {},
            else => {},
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// The guest writes raw dwords, so the tests do too — building them from the
/// register structs keeps the intent readable without bypassing the decode.
fn lvt(entry: LvtEntry) u32 {
    return @bitCast(entry);
}

/// Divide by 1 (the 0b111 special case, encoded as bits [3,1:0] = 0b1_11).
const DIVIDE_BY_1: u32 = @bitCast(DivideConfig{ .low = 0b11, .high = 1 });

// A tick ratio for the tests. Any exact ratio does; the model only multiplies
// by it, so the value is arbitrary as long as the arithmetic below uses the
// same one.
const TSC_PER_BUS_TICK: u64 = 24;

fn enabledLapic() Lapic {
    return .{ .tsc_per_bus_tick = TSC_PER_BUS_TICK, .svr = .{ .apic_enabled = true } };
}

test "divide configuration decodes the split-bit encoding" {
    const shiftOf = struct {
        fn f(raw: u32) u5 {
            return @as(DivideConfig, @bitCast(raw)).shift();
        }
    }.f;

    // Bit 2 is skipped: the divisor is bits [3,1:0]. 0b111 is the special
    // "divide by 1" case, everything else is 2^(n+1).
    try testing.expectEqual(@as(u5, 1), shiftOf(0b0000)); // divide by 2
    try testing.expectEqual(@as(u5, 2), shiftOf(0b0001)); // by 4
    try testing.expectEqual(@as(u5, 3), shiftOf(0b0010)); // by 8
    try testing.expectEqual(@as(u5, 0), shiftOf(0b1011)); // by 1
    // Bit 2 must be ignored, not folded into the divisor.
    try testing.expectEqual(shiftOf(0b0000), shiftOf(0b0100));
    // The struct-built constant and the raw encoding must agree.
    try testing.expectEqual(@as(u32, 0b1011), DIVIDE_BY_1);
}

test "a one-shot timer fires exactly once, at the deadline" {
    var lapic = enabledLapic();
    lapic.write(@intFromEnum(Reg.lvt_timer), lvt(.{ .vector = 0x30, .masked = false }), 0);
    lapic.write(@intFromEnum(Reg.timer_dcr), DIVIDE_BY_1, 0);
    lapic.write(@intFromEnum(Reg.timer_icr), 1000, 0);

    const expected = 1000 * TSC_PER_BUS_TICK;
    try testing.expectEqual(@as(?u64, expected), lapic.deadline);

    // One tick early: nothing.
    try testing.expect(!lapic.expireTimer(expected - 1));
    try testing.expectEqual(@as(?u8, null), lapic.pendingVector());

    try testing.expect(lapic.expireTimer(expected));
    try testing.expectEqual(@as(?u8, 0x30), lapic.pendingVector());
    // One-shot: disarmed, and it does not fire again.
    try testing.expectEqual(@as(?u64, null), lapic.deadline);
    try testing.expect(!lapic.expireTimer(expected * 10));
}

test "a periodic timer keeps its phase when serviced late" {
    var lapic = enabledLapic();
    lapic.write(@intFromEnum(Reg.timer_dcr), DIVIDE_BY_1, 0);
    lapic.write(@intFromEnum(Reg.lvt_timer), lvt(.{
        .vector = 0x30,
        .masked = false,
        .timer_mode = .periodic,
    }), 0);
    lapic.write(@intFromEnum(Reg.timer_icr), 100, 0);

    const period = 100 * TSC_PER_BUS_TICK;
    try testing.expectEqual(@as(?u64, period), lapic.deadline);

    // Service it two and a half periods late. The next deadline must sit on
    // the original grid, not `now + period` — otherwise every late tick would
    // permanently shift the phase and the guest's clock would drift.
    try testing.expect(lapic.expireTimer(period * 2 + period / 2));
    try testing.expectEqual(@as(?u64, period * 3), lapic.deadline);
}

test "writing zero to the initial count disarms the timer" {
    var lapic = enabledLapic();
    lapic.write(@intFromEnum(Reg.lvt_timer), lvt(.{ .vector = 0x30, .masked = false }), 0);
    lapic.write(@intFromEnum(Reg.timer_icr), 500, 0);
    try testing.expect(lapic.deadline != null);
    lapic.write(@intFromEnum(Reg.timer_icr), 0, 0);
    try testing.expectEqual(@as(?u64, null), lapic.deadline);
}

test "masking the LVT entry stops the timer" {
    var lapic = enabledLapic();
    lapic.write(@intFromEnum(Reg.lvt_timer), lvt(.{ .vector = 0x30, .masked = false }), 0);
    lapic.write(@intFromEnum(Reg.timer_icr), 500, 0);
    try testing.expect(lapic.deadline != null);
    lapic.write(@intFromEnum(Reg.lvt_timer), lvt(.{ .vector = 0x30, .masked = true }), 0);
    try testing.expectEqual(@as(?u64, null), lapic.deadline);
}

test "current count counts down with the clock, without side effects" {
    var lapic = enabledLapic();
    lapic.write(@intFromEnum(Reg.timer_dcr), DIVIDE_BY_1, 0);
    lapic.write(@intFromEnum(Reg.lvt_timer), lvt(.{ .vector = 0x30, .masked = false }), 0);
    lapic.write(@intFromEnum(Reg.timer_icr), 1000, 0);

    try testing.expectEqual(@as(u32, 1000), lapic.read(@intFromEnum(Reg.timer_ccr), 0));
    try testing.expectEqual(@as(u32, 750), lapic.read(@intFromEnum(Reg.timer_ccr), 250 * TSC_PER_BUS_TICK));
    try testing.expectEqual(@as(u32, 0), lapic.read(@intFromEnum(Reg.timer_ccr), 1000 * TSC_PER_BUS_TICK));
    // Reading must not have disturbed the deadline.
    try testing.expectEqual(@as(?u64, 1000 * TSC_PER_BUS_TICK), lapic.deadline);
}

test "delivery respects APIC enable, priority and in-service state" {
    var lapic = Lapic{ .tsc_per_bus_tick = TSC_PER_BUS_TICK };
    lapic.raise(0x30);
    // SVR enable bit clear ⇒ nothing is deliverable.
    try testing.expectEqual(@as(?u8, null), lapic.pendingVector());

    lapic.svr.apic_enabled = true;
    try testing.expectEqual(@as(?u8, 0x30), lapic.pendingVector());

    // Higher vector wins.
    lapic.raise(0x50);
    try testing.expectEqual(@as(?u8, 0x50), lapic.pendingVector());

    // Once in service, an equal-or-lower priority vector is blocked...
    lapic.accept(0x50);
    try testing.expectEqual(@as(?u8, null), lapic.pendingVector());
    // ...but a higher-priority one still gets through.
    lapic.raise(0x70);
    try testing.expectEqual(@as(?u8, 0x70), lapic.pendingVector());

    // EOI retires the in-service vector and unblocks the rest.
    lapic.accept(0x70);
    lapic.write(@intFromEnum(Reg.eoi), 0, 0);
    lapic.write(@intFromEnum(Reg.eoi), 0, 0);
    try testing.expectEqual(@as(?u8, 0x30), lapic.pendingVector());
}

test "PPR is the maximum of TPR and the in-service class" {
    var lapic = enabledLapic();
    const ppr = struct {
        fn of(l: *Lapic) u32 {
            return l.read(@intFromEnum(Reg.ppr), 0);
        }
    }.of;

    // Nothing in service: PPR is TPR, sub-class and all.
    lapic.write(@intFromEnum(Reg.tpr), 0x35, 0);
    try testing.expectEqual(@as(u32, 0x35), ppr(&lapic));

    // A higher in-service class wins, and zeroes the sub-class.
    lapic.raise(0x70);
    lapic.accept(0x70);
    try testing.expectEqual(@as(u32, 0x70), ppr(&lapic));

    // A LOWER in-service class must not pull PPR down below TPR: PPR is the
    // maximum of TPR and the in-service class, not whichever was set last.
    var l2 = enabledLapic();
    l2.write(@intFromEnum(Reg.tpr), 0x80, 0);
    l2.raise(0x30);
    l2.accept(0x30);
    try testing.expectEqual(@as(u32, 0x80), ppr(&l2));
}

test "TPR masks interrupts at or below its priority class" {
    var lapic = enabledLapic();
    lapic.raise(0x30);
    lapic.write(@intFromEnum(Reg.tpr), 0x30, 0); // class 3 blocks vector class 3
    try testing.expectEqual(@as(?u8, null), lapic.pendingVector());
    lapic.write(@intFromEnum(Reg.tpr), 0x20, 0);
    try testing.expectEqual(@as(?u8, 0x30), lapic.pendingVector());
}

test "vectors below 16 are not deliverable" {
    var lapic = enabledLapic();
    lapic.raise(15);
    try testing.expectEqual(@as(?u8, null), lapic.pendingVector());
}
