const std = @import("std");

// A minimal I/O APIC (82093AA): the device-side interrupt router that turns a
// device's IRQ line into a vector delivered to a local APIC.
//
// Modelled:
//   - the IOREGSEL/IOWIN index-data window,
//   - the ID and VERSION registers,
//   - the 24 redirection-table entries, from which a pin's vector and mask are
//     read.
//
// Two ways to use it. `deliver` routes an asserted pin straight into a local
// APIC; `vectorFor`/`masked` expose the same state for a caller that injects
// through its own path instead.
//
// Edge-triggered only: remote-IRR and EOI reflection are not modelled, which is
// correct for edge-triggered sources and wrong for level-triggered ones.

pub const NUM_RTES = 24;
const MAX_REDIR: u8 = NUM_RTES - 1; // reported in IOAPICVER[16:23]
const VERSION: u8 = 0x11; //           IOAPICVER[0:7]

// IOAPICID (82093AA §3.2.1). The ID sits in bits 27:24, not at the bottom.
const IoapicId = packed struct(u32) {
    _rsvd0: u24 = 0,
    id: u4 = 0,
    _rsvd28: u4 = 0,
};

// IOAPICVER (§3.2.2), read-only.
const IoapicVersion = packed struct(u32) {
    version: u8 = VERSION,
    _rsvd8: u8 = 0,
    max_redir: u8 = MAX_REDIR,
    _rsvd24: u8 = 0,
};

// The guest reaches each 64-bit RTE as two 32-bit halves through IOWIN. This is
// a register-access width split, not a field split — the fields themselves are
// named on RedirectionEntry — so it gets its own struct rather than a pair of
// 64-bit masks.
const Halves = packed struct(u64) {
    low: u32 = 0,
    high: u32 = 0,
};

// MMIO window offsets from IOAPIC_BASE.
pub const IOREGSEL = 0x00; // write: selects the internal register
pub const IOWIN = 0x10; //    read/write: accesses the selected register

// Internal register indices (written to IOREGSEL).
/// The internal register IOREGSEL selects. Non-exhaustive because the 48
/// redirection-entry halves from `rte_base` up are a range, not named values —
/// they fall through to `else` and are decoded arithmetically.
const Reg = enum(u8) {
    id = 0x00,
    ver = 0x01,
    arb = 0x02,
    rte_base = 0x10, // entry n: low = 0x10 + 2n, high = 0x11 + 2n
    _,
};

/// Index of the last redirection-entry half.
const RTE_LAST: u8 = @intFromEnum(Reg.rte_base) + NUM_RTES * 2 - 1;

// One 64-bit redirection-table entry (82093AA §3.2.4). The guest programs it as
// two 32-bit halves through IOWIN, so it is bitcast to and from a u64 for those
// half-width accesses.
pub const RedirectionEntry = packed struct(u64) {
    vector: u8 = 0, //              0-7    interrupt vector
    delivery_mode: u3 = 0, //       8-10   fixed / lowest-priority / NMI / ...
    dest_mode: bool = false, //     11     0 = physical, 1 = logical
    delivery_status: bool = false, //12     (read-only status)
    polarity: bool = false, //      13     0 = active high
    remote_irr: bool = false, //    14     (read-only; level-triggered only)
    trigger: bool = false, //       15     0 = edge, 1 = level
    mask: bool = false, //          16     1 = masked
    _rsvd: u39 = 0, //              17-55
    dest: u8 = 0, //                56-63  destination APIC id
};

pub const Ioapic = struct {
    ioregsel: u8 = 0,
    id: u4 = 0,
    rte: [NUM_RTES]RedirectionEntry = @splat(.{}), // redirection entries
    touched: bool = false, //                         set once the guest programs any RTE

    /// Service a store into the MMIO window (offset from IOAPIC_BASE). Only the
    /// IOREGSEL and IOWIN dwords are writable; anything else is dropped.
    pub fn mmioWrite(self: *Ioapic, offset: usize, val: u32) void {
        switch (offset) {
            IOREGSEL => self.ioregsel = @truncate(val),
            IOWIN => self.writeReg(self.ioregsel, val),
            else => {},
        }
    }

    /// Service a load from the MMIO window. Reads outside IOREGSEL/IOWIN float 0.
    pub fn mmioRead(self: *const Ioapic, offset: usize) u32 {
        return switch (offset) {
            IOREGSEL => self.ioregsel,
            IOWIN => self.readReg(self.ioregsel),
            else => 0,
        };
    }

    fn writeReg(self: *Ioapic, index: u8, val: u32) void {
        switch (@as(Reg, @enumFromInt(index))) {
            .id => self.id = @as(IoapicId, @bitCast(val)).id,
            .ver, .arb => {}, //                         read-only
            else => if (index >= @intFromEnum(Reg.rte_base) and index <= RTE_LAST) {
                const rel = index - @intFromEnum(Reg.rte_base);
                self.writeRte(rel / 2, rel & 1 == 1, val);
                self.touched = true;
            },
        }
    }

    fn readReg(self: *const Ioapic, index: u8) u32 {
        return switch (@as(Reg, @enumFromInt(index))) {
            .id => @bitCast(IoapicId{ .id = self.id }),
            .ver => @bitCast(IoapicVersion{}),
            .arb => @bitCast(IoapicId{ .id = self.id }), // arbitration ID mirrors the ID
            else => if (index >= @intFromEnum(Reg.rte_base) and index <= RTE_LAST) blk: {
                const rel = index - @intFromEnum(Reg.rte_base);
                break :blk self.readRte(rel / 2, rel & 1 == 1);
            } else 0,
        };
    }

    // Splice one 32-bit half into the entry, leaving the other untouched.
    fn writeRte(self: *Ioapic, pin: usize, high: bool, val: u32) void {
        var halves: Halves = @bitCast(self.rte[pin]);
        if (high) halves.high = val else halves.low = val;
        self.rte[pin] = @bitCast(halves);
    }
    fn readRte(self: *const Ioapic, pin: usize, high: bool) u32 {
        const halves: Halves = @bitCast(self.rte[pin]);
        return if (high) halves.high else halves.low;
    }

    // ---- delivery ---------------------------------------------------------

    /// Route an asserted pin into `lapic`'s request register. Dropped when the
    /// RTE is masked or still unprogrammed — a just-reset entry is all zeroes,
    /// which reads as "unmasked, vector 0", so the vector must be checked too
    /// or a device could inject vector 0 into a guest that has not set the
    /// table up yet.
    pub fn deliver(self: *const Ioapic, pin: usize, lapic: anytype) void {
        if (pin >= NUM_RTES) return;
        const entry = self.rte[pin];
        if (entry.mask or entry.vector == 0) return;
        lapic.raise(entry.vector);
    }

    /// The vector the guest programmed for a pin (RTE[pin].vector).
    pub fn vectorFor(self: *const Ioapic, pin: usize) u8 {
        return self.rte[pin].vector;
    }
    /// Whether a pin is masked (RTE[pin].mask).
    pub fn masked(self: *const Ioapic, pin: usize) bool {
        return self.rte[pin].mask;
    }
    /// The guest has begun programming the I/O APIC (any RTE written) — the
    /// analogue of the PIC's "vector base set" gate.
    pub fn initialized(self: *const Ioapic) bool {
        return self.touched;
    }

};

// ---- tests (pure model) ----------------------------------------------------

const testing = std.testing;

// Two arbitrary pins for the tests. Nothing about the device fixes what a
// machine wires to either one.
const PIN_A = 4;
const PIN_B = 5;

/// The low dword of an RTE, as the guest would write it through IOWIN.
fn rteLow(entry: RedirectionEntry) u32 {
    return @as(Halves, @bitCast(entry)).low;
}

test "Ioapic: IOAPICVER reports version 0x11 and 23 as the max redirection entry" {
    var io = Ioapic{};
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.ver));
    const ver: IoapicVersion = @bitCast(io.mmioRead(IOWIN));
    try testing.expectEqual(VERSION, ver.version);
    try testing.expectEqual(MAX_REDIR, ver.max_redir); // 23 → 24 RTEs
}

test "Ioapic: the ID register round-trips through IOREGSEL/IOWIN" {
    var io = Ioapic{};
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.id));
    io.mmioWrite(IOWIN, 0x0f00_0000); // ID = 0xf in bits 24-27
    try testing.expectEqual(@as(u4, 0xf), io.id);
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.id));
    try testing.expectEqual(@as(u32, 0x0f00_0000), io.mmioRead(IOWIN));
}

test "Ioapic: programming an RTE sets its vector and mask" {
    var io = Ioapic{};
    try testing.expect(!io.initialized());

    // Linux writes each RTE masked-first: low dword = vector 0x30, mask bit set.
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base)); // pin 0 low
    io.mmioWrite(IOWIN, rteLow(.{ .vector = 0x30, .mask = true }));
    try testing.expect(io.initialized());
    try testing.expectEqual(@as(u8, 0x30), io.vectorFor(0));
    try testing.expect(io.masked(0));

    // Read the low dword back through the window.
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base));
    try testing.expectEqual(rteLow(.{ .vector = 0x30, .mask = true }), io.mmioRead(IOWIN));

    // Unmask (clear bit 16), keeping the vector.
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base));
    io.mmioWrite(IOWIN, 0x30);
    try testing.expect(!io.masked(0));
    try testing.expectEqual(@as(u8, 0x30), io.vectorFor(0));
}

test "Ioapic: pin 4 (IRQ4, COM1) is independent of pin 0" {
    var io = Ioapic{};
    // pin 4 low reg = 0x10 + 4*2 = 0x18.
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base) + PIN_A * 2);
    io.mmioWrite(IOWIN, 0x34); // vector 0x34, unmasked
    try testing.expectEqual(@as(u8, 0x34), io.vectorFor(PIN_A));
    try testing.expect(!io.masked(PIN_A));
    // pin 0 untouched → still zero/unmasked-but-no-vector.
    try testing.expectEqual(@as(u8, 0), io.vectorFor(0));
}

test "Ioapic: pin 5 (IRQ5, virtio) exposes its vector and mask independently" {
    var io = Ioapic{};
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base) + PIN_B * 2);
    io.mmioWrite(IOWIN, 0x40); // vector 0x40, unmasked
    try testing.expectEqual(@as(u8, 0x40), io.vectorFor(PIN_B));
    try testing.expect(!io.masked(PIN_B));
    // Mask it (bit 16) and the mask flips, vector unchanged.
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base) + PIN_B * 2);
    io.mmioWrite(IOWIN, rteLow(.{ .vector = 0x40, .mask = true }));
    try testing.expect(io.masked(PIN_B));
    try testing.expectEqual(@as(u8, 0x40), io.vectorFor(PIN_B));
    // Timer/serial pins are untouched.
    try testing.expectEqual(@as(u8, 0), io.vectorFor(0));
    try testing.expectEqual(@as(u8, 0), io.vectorFor(PIN_A));
}

test "Ioapic: the RTE high dword (destination) round-trips separately" {
    var io = Ioapic{};
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base) + 1); // pin 0 high
    io.mmioWrite(IOWIN, 0x0100_0000); // destination APIC id 1 in bits 56-63
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base) + 1);
    try testing.expectEqual(@as(u32, 0x0100_0000), io.mmioRead(IOWIN));
    // The low dword stayed zero.
    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base));
    try testing.expectEqual(@as(u32, 0), io.mmioRead(IOWIN));
}

/// The only thing `deliver` needs of a local APIC. It takes `anytype`, so any
/// type with this method satisfies it.
const StubLapic = struct {
    raised: ?u8 = null,
    fn raise(self: *StubLapic, vector: u8) void {
        self.raised = vector;
    }
};

test "Ioapic: deliver routes an asserted pin into the LAPIC, honouring the mask" {
    var io = Ioapic{};
    var lapic = StubLapic{};

    // Unprogrammed table: an all-zero RTE reads as unmasked with vector 0, so
    // delivery must be suppressed or the guest gets vector 0 before it has set
    // the routing up.
    io.deliver(PIN_A, &lapic);
    try testing.expectEqual(@as(?u8, null), lapic.raised);

    io.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base) + PIN_A * 2);
    io.mmioWrite(IOWIN, rteLow(.{ .vector = 0x34 })); // unmasked
    io.deliver(PIN_A, &lapic);
    try testing.expectEqual(@as(?u8, 0x34), lapic.raised);

    // Masked pins are dropped.
    var io2 = Ioapic{};
    var lapic2 = StubLapic{};
    io2.mmioWrite(IOREGSEL, @intFromEnum(Reg.rte_base) + PIN_B * 2);
    io2.mmioWrite(IOWIN, rteLow(.{ .vector = 0x40, .mask = true }));
    io2.deliver(PIN_B, &lapic2);
    try testing.expectEqual(@as(?u8, null), lapic2.raised);
}
