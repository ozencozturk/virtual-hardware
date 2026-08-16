const std = @import("std");

// A minimal ACPI PM1 register block: the fixed-event registers (status, enable)
// and the control register. Status and latch only — no SCI is raised, so nothing
// here drives an interrupt.

// Layout of the contiguous PM1 window: PM1a_EVT_BLK (status + enable) immediately
// followed by PM1a_CNT_BLK (control), so a single I/O window covers both. The
// block lengths the FADT advertises are derived from this struct.
const Pm1Regs = extern struct {
    status: u16, //  PM1_STATUS  (W1C; always reads 0 here — no events pending)
    enable: u16, //  PM1_ENABLE
    control: u16, // PM1_CONTROL
};

pub const EVT_LEN = @offsetOf(Pm1Regs, "control"); // PM1_EVT_LEN: status(2) + enable(2)
pub const CNT_LEN = @sizeOf(Pm1Regs) - EVT_LEN; //   PM1_CNT_LEN: control(2)
pub const LEN = @sizeOf(Pm1Regs); //                 one contiguous I/O window over both blocks

// PM1_CONTROL bit fields (ACPI §4.8.3.2.1).
const Pm1Control = packed struct(u16) {
    sci_en: bool = false, //   bit 0: ACPI mode enabled
    _rsvd0: u9 = 0, //         bits 1-9
    slp_typ: u3 = 0, //        bits 10-12: sleep state (the DSDT's \_S5 encodes 7)
    slp_en: bool = false, //   bit 13: commit the SLP_TYP transition
    _rsvd1: u2 = 0, //         bits 14-15
};
// `slp_typ` is never decoded: no suspend states are modelled, so any committed
// sleep transition is treated as a power-off request.

pub const AcpiPm = struct {
    enable: u16 = 0, //                          PM1_ENABLE — ACPICA writes 0 here to disable all fixed events
    control: Pm1Control = .{ .sci_en = true }, // PM1_CONTROL — sci_en reads set, so acpi_hw_get_mode() sees ACPI mode

    /// Read the register at `offset` within the block. Widths are the ACPI
    /// register widths (16-bit); `size` is accepted but the value is the whole
    /// register (ACPICA reads each PM1 register at its natural width).
    pub fn read(self: *const AcpiPm, offset: usize, size: usize) u32 {
        _ = size;
        return switch (offset) {
            @offsetOf(Pm1Regs, "status") => 0, //  no wake/power events are ever pending
            @offsetOf(Pm1Regs, "enable") => self.enable,
            @offsetOf(Pm1Regs, "control") => @as(u16, @bitCast(self.control)),
            else => 0,
        };
    }

    /// Write the register at `offset`. PM1_STATUS is write-1-to-clear over an
    /// all-zero status and so a no-op; ENABLE and CONTROL latch, with `sci_en`
    /// pinned set so the mode never reads as legacy. Returns true when the write
    /// commits a sleep transition, which the caller treats as a power-off request.
    pub fn write(self: *AcpiPm, offset: usize, value: u32) bool {
        switch (offset) {
            @offsetOf(Pm1Regs, "enable") => self.enable = @truncate(value),
            @offsetOf(Pm1Regs, "control") => {
                var c: Pm1Control = @bitCast(@as(u16, @truncate(value)));
                const power_off = c.slp_en; // committed sleep ⇒ power off
                c.sci_en = true; //            pin sci_en
                self.control = c;
                return power_off;
            },
            else => {}, //                     PM1_STATUS (W1C, nothing set) / gaps
        }
        return false;
    }
};

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

// Offsets and control-bit patterns expressed through the layout types.
const STATUS = @offsetOf(Pm1Regs, "status");
const ENABLE = @offsetOf(Pm1Regs, "enable");
const CONTROL = @offsetOf(Pm1Regs, "control");

fn ctrl(bits: Pm1Control) u32 {
    return @as(u16, @bitCast(bits));
}

test "AcpiPm: PM1_STATUS reads zero (no events pending)" {
    const pm = AcpiPm{};
    try testing.expectEqual(@as(u32, 0), pm.read(STATUS, 2));
}

test "AcpiPm: PM1_ENABLE latches what ACPICA writes (fixed-event init writes 0)" {
    var pm = AcpiPm{};
    try testing.expect(!pm.write(ENABLE, 0x0300)); // e.g. enable a couple of fixed events
    try testing.expectEqual(@as(u32, 0x0300), pm.read(ENABLE, 2));
    try testing.expect(!pm.write(ENABLE, 0x0000)); // init disables all
    try testing.expectEqual(@as(u32, 0), pm.read(ENABLE, 2));
}

test "AcpiPm: PM1_CONTROL reads sci_en set and keeps it pinned across writes" {
    var pm = AcpiPm{};
    try testing.expectEqual(ctrl(.{ .sci_en = true }), pm.read(CONTROL, 2)); // ACPI mode looks enabled
    // A SLP_TYP write with no slp_en latches and pins sci_en without committing.
    try testing.expect(!pm.write(CONTROL, ctrl(.{ .slp_typ = 7 })));
    try testing.expectEqual(ctrl(.{ .sci_en = true, .slp_typ = 7 }), pm.read(CONTROL, 2));
}

test "AcpiPm: PM1_CONTROL with slp_en set requests power off" {
    var pm = AcpiPm{};
    try testing.expect(pm.write(CONTROL, ctrl(.{ .slp_typ = 7, .slp_en = true }))); // S5 committed
    // A control write without slp_en never trips it, whatever slp_typ holds.
    try testing.expect(!pm.write(CONTROL, ctrl(.{ .slp_typ = 7 })));
    // Writes to the other PM1 registers never request power off.
    try testing.expect(!pm.write(ENABLE, ctrl(.{ .slp_en = true }))); // PM1_ENABLE, not CONTROL
    try testing.expect(!pm.write(STATUS, ctrl(.{ .slp_en = true }))); // PM1_STATUS (W1C)
}
