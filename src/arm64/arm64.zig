//! AArch64 architecture: register/bitfield decode (PSTATE, ESR). Hypervisor-agnostic —
//! this is ISA layout, not any particular hypervisor's FFI.

const std = @import("std");

pub const Pstate = packed struct(u64) {
    sp_sel: u1 = 1, // bit 0    SPSel: 0 = SP_EL0 (t), 1 = SP_ELx (h)
    _res1: u1 = 0, // bit 1
    el: u2 = 1, // bits 3:2 exception level (1 = EL1)
    aarch32: u1 = 0, // bit 4    0 = AArch64
    _res2: u1 = 0, // bit 5
    f: u1 = 1, // bit 6    FIQ mask
    i: u1 = 1, // bit 7    IRQ mask
    a: u1 = 1, // bit 8    SError mask
    d: u1 = 1, // bit 9    Debug mask
    _rest: u54 = 0, // bits 10..63 (NZCV, IL, SS, PAN, … all 0 at entry)

    pub fn fromBits(v: u64) Pstate {
        return @bitCast(v);
    }
    pub fn toBits(self: Pstate) u64 {
        return @bitCast(self);
    }
};

/// ESR_ELx — outer frame. Valid for any exception class.
pub const Esr = packed struct(u64) {
    iss: u25 = 0, // bits 24:0   instruction-specific syndrome (interpret per EC)
    il: u1 = 0, // bit 25      instruction length: 0 = 16-bit, 1 = 32-bit
    ec: ExceptionClass = .unknown, // bits 31:26  exception class
    iss2: u24 = 0, // bits 55:32  ISS2 (RES0 before ARMv8.7)
    _hi: u8 = 0, // bits 63:56  RES0
    pub fn fromBits(v: u64) Esr {
        return @bitCast(v);
    }
    pub fn toBits(self: Esr) u64 {
        return @bitCast(self);
    }
};
pub const ExceptionClass = enum(u6) {
    unknown = 0x00,
    wf_x = 0x01, // WFI/WFE
    svc = 0x15, // syscall (AArch64)
    hvc = 0x16,
    smc = 0x17,
    msr_mrs = 0x18, // trapped system-register access
    inst_abort_lower = 0x20,
    inst_abort_same = 0x21,
    pc_alignment = 0x22,
    data_abort_lower = 0x24, // guest touched an unmapped IPA — the MMIO exit
    data_abort_same = 0x25,
    sp_alignment = 0x26,
    serror = 0x2f,
    _, // non-exhaustive: any other u6 is still valid
};
pub const Sas = enum(u2) {
    byte = 0b00, // 1
    halfword = 0b01, // 2
    word = 0b10, // 4
    doubleword = 0b11, // 8
    pub fn bytes(self: Sas) usize {
        return @as(usize, 1) << @intFromEnum(self); // 1 << SAS
    }
};
pub const DataAbortIss = packed struct(u25) {
    dfsc: u6 = 0, // 5:0
    wnr: u1 = 0, // 6
    s1ptw: u1 = 0, // 7
    cm: u1 = 0, // 8
    ea: u1 = 0, // 9
    fnv: u1 = 0, // 10
    _mid: u3 = 0, // 13:11
    ar: u1 = 0, // 14
    sf: u1 = 0, // 15
    srt: u5 = 0, // 20:16
    sse: u1 = 0, // 21
    sas: Sas = .byte, // 23:22
    isv: u1 = 0, // 24   ← here
    pub fn fromBits(v: u25) DataAbortIss {
        return @bitCast(v);
    }
    pub fn toBits(self: DataAbortIss) u25 {
        return @bitCast(self);
    }
    pub fn isWrite(self: DataAbortIss) bool {
        return self.wnr == 1;
    }
    pub fn size(self: DataAbortIss) usize {
        return self.sas.bytes();
    }
};
/// The (op0, op1, CRn, CRm, op2) tuple that names a system register, with the Rt
/// and direction bits the ISS interleaves through it removed. Packed so a switch
/// compares one integer instead of five fields.
pub const SysRegKey = packed struct(u16) {
    op2: u3,
    crm: u4,
    crn: u4,
    op1: u3,
    op0: u2,
};

/// Build a SysReg value from the tuple the ARM ARM prints. Via SysRegKey rather
/// than shifts, so the bit positions are stated once, by the type.
fn key(op0: u2, op1: u3, crn: u4, crm: u4, op2: u3) u16 {
    return @bitCast(SysRegKey{ .op0 = op0, .op1 = op1, .crn = crn, .crm = crm, .op2 = op2 });
}
/// System registers this module can name. NON-EXHAUSTIVE on purpose: every other
/// encoding is still a valid SysReg, it just has no name here — which is precisely
/// the set a sysreg handler's `else` should refuse.
pub const SysReg = enum(u16) {
    // The OS-lock group (trapped by MDCR_EL2.TDOSA). A hypervisor typically traps
    // all of these unconditionally with no opt-out — the usual debug-register trap
    // control covers DBGB*/DBGW*/MDSCR only. They are also not part of the vCPU
    // register set a hypervisor API exposes, so their state lives in the VMM or
    // nowhere.
    OSLAR_EL1 = key(2, 0, 1, 0, 4), // OS Lock Access       (WO)
    OSLSR_EL1 = key(2, 0, 1, 1, 4), // OS Lock Status       (RO)
    OSDLR_EL1 = key(2, 0, 1, 3, 4), // OS Double Lock       (RW)  ← traps on cold boot
    DBGPRCR_EL1 = key(2, 0, 1, 4, 4), // Powerdown/Reset Ctl (RW)  ← never executed
    _,
};
pub const Direction = enum(u1) { write = 0, read = 1 };
/// ESR ISS for EC 0x18 — a trapped MSR/MRS/System instruction in AArch64.
pub const SysRegIss = packed struct(u25) {
    direction: Direction = .write, // 0
    crm: u4 = 0, // 4:1
    rt: u5 = 0, // 9:5   31 == XZR, same convention as DataAbortIss.srt
    crn: u4 = 0, // 13:10
    op1: u3 = 0, // 16:14
    op2: u3 = 0, // 19:17   NOTE: op2 is BELOW op0 and ABOVE op1 — not tuple order
    op0: u2 = 0, // 21:20
    _res0: u3 = 0, // 24:22

    pub fn fromBits(v: u25) SysRegIss {
        return @bitCast(v);
    }
    pub fn toBits(self: SysRegIss) u25 {
        return @bitCast(self);
    }

    /// Which register this access names. A re-pack, not a mask — see SysRegKey.
    pub fn id(self: SysRegIss) SysReg {
        return @enumFromInt(key(self.op0, self.op1, self.crn, self.crm, self.op2));
    }
};
const testing = std.testing;

test "Pstate default is EL1h with DAIF masked (0x3c5)" {
    try testing.expectEqual(@as(u64, 0x3c5), (Pstate{}).toBits());
    try testing.expectEqual(Pstate{}, Pstate.fromBits(0x3c5));
}

test "Sas.bytes maps the size code to a byte count" {
    try testing.expectEqual(@as(usize, 1), Sas.byte.bytes());
    try testing.expectEqual(@as(usize, 2), Sas.halfword.bytes());
    try testing.expectEqual(@as(usize, 4), Sas.word.bytes());
    try testing.expectEqual(@as(usize, 8), Sas.doubleword.bytes());
}

test "Esr decodes the exception class from bits 31:26" {
    const esr = Esr{ .ec = .data_abort_lower };
    try testing.expectEqual(ExceptionClass.data_abort_lower, Esr.fromBits(esr.toBits()).ec);
    // EC lives at bits 31:26 → 0x24 << 26.
    try testing.expectEqual(@as(u64, 0x24) << 26, esr.toBits());
}

test "DataAbortIss round-trips its fields" {
    const iss = DataAbortIss{ .isv = 1, .wnr = 1, .sas = .word, .srt = 4 };
    const back = DataAbortIss.fromBits(iss.toBits());
    try testing.expectEqual(@as(u1, 1), back.isv);
    try testing.expectEqual(@as(u1, 1), back.wnr);
    try testing.expectEqual(Sas.word, back.sas);
    try testing.expectEqual(@as(u5, 4), back.srt);
}

test "DataAbortIss places fields at the ARM ISS bit positions" {
    const raw = (DataAbortIss{ .isv = 1, .sas = .doubleword, .srt = 5, .wnr = 1 }).toBits();
    try testing.expectEqual(@as(u25, 1), (raw >> 24) & 1); // ISV  @ 24
    try testing.expectEqual(@as(u25, 0b11), (raw >> 22) & 0b11); // SAS  @ 23:22
    try testing.expectEqual(@as(u25, 5), (raw >> 16) & 0x1f); // SRT  @ 20:16
    try testing.expectEqual(@as(u25, 1), (raw >> 6) & 1); // WnR  @ 6
}

// Every field distinct, so a struct that packs two of them into the same bits
// can't pass. Raw shifts on purpose: a round-trip through fromBits/toBits would
// agree with ANY self-consistent layout, including a wrong one.
test "SysRegIss places fields at the ARM ISS bit positions" {
    const raw = (SysRegIss{ .op0 = 2, .op1 = 5, .crn = 1, .crm = 3, .op2 = 4, .rt = 31, .direction = .read }).toBits();
    try testing.expectEqual(@as(u25, 1), raw & 1); // Direction @ 0
    try testing.expectEqual(@as(u25, 3), (raw >> 1) & 0xf); // CRm  @ 4:1
    try testing.expectEqual(@as(u25, 31), (raw >> 5) & 0x1f); // Rt   @ 9:5
    try testing.expectEqual(@as(u25, 1), (raw >> 10) & 0xf); // CRn  @ 13:10
    try testing.expectEqual(@as(u25, 5), (raw >> 14) & 0x7); // Op1  @ 16:14
    try testing.expectEqual(@as(u25, 4), (raw >> 17) & 0x7); // Op2  @ 19:17
    try testing.expectEqual(@as(u25, 2), (raw >> 20) & 0x3); // Op0  @ 21:20
}

// THE test for the EC 0x18 decode. 0x622807e6 is not synthesized: it is an exact
// ESR_EL2 captured from a real guest trapping on OSDLR_EL1 during boot.
// It is the only input here that did not come out of the struct it is checking —
// every other decode test would still pass if the whole layout were shifted,
// because it would be shifted with them.
test "SysRegIss decodes the real OSDLR_EL1 trap" {
    const esr = Esr.fromBits(0x622807e6);
    try testing.expectEqual(ExceptionClass.msr_mrs, esr.ec);

    const iss = SysRegIss.fromBits(esr.iss);
    try testing.expectEqual(SysReg.OSDLR_EL1, iss.id());
    try testing.expectEqual(Direction.write, iss.direction);
    try testing.expectEqual(@as(u5, 31), iss.rt); // XZR => the guest wrote a literal 0
}

// Rt and Direction are interleaved THROUGH the register's tuple, so a mask-based
// id() would smear them into its identity. Same register, different access.
test "SysRegIss.id names the same register regardless of Rt or direction" {
    const write_xzr = SysRegIss{ .op0 = 2, .op1 = 0, .crn = 1, .crm = 3, .op2 = 4, .rt = 31, .direction = .write };
    const read_x5 = SysRegIss{ .op0 = 2, .op1 = 0, .crn = 1, .crm = 3, .op2 = 4, .rt = 5, .direction = .read };
    try testing.expectEqual(SysReg.OSDLR_EL1, write_xzr.id());
    try testing.expectEqual(SysReg.OSDLR_EL1, read_x5.id());
}

// The OS-lock group differs ONLY in CRm (0/1/3/4), so a key() that dropped or
// misplaced that field would collapse them into one register — and a sysreg handler
// would then happily "emulate" OSLSR_EL1 reads as OSDLR_EL1 writes.
test "SysReg: the OS-lock group members are distinct encodings" {
    const group = [_]SysReg{ .OSLAR_EL1, .OSLSR_EL1, .OSDLR_EL1, .DBGPRCR_EL1 };
    for (group, 0..) |a, i| for (group[i + 1 ..]) |b| try testing.expect(a != b);
}
