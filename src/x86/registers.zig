// Control register 0. The mode-control master switch: PE (bit 0) enters
// protected mode and PG (bit 31) turns on paging; together they gate long mode.
// The `packed struct(u64)` backing integer makes a miscounted reserved field a
// compile error.
pub const Cr0 = packed struct(u64) {
    PE: bool = false, // 0   protection enable (0 = real mode, 1 = protected mode)
    MP: bool = false, // 1   monitor coprocessor (WAIT/FWAIT traps with TS)
    EM: bool = false, // 2   emulation (1 = no x87; FP ops trap #NM)
    TS: bool = false, // 3   task switched (defers FPU state save on task switch)
    ET: bool = false, // 4   extension type (387 vs 287; hardwired 1 on modern CPUs)
    NE: bool = false, // 5   numeric error (1 = native x87 #MF, not the legacy IRQ13)
    _r0: u10 = 0, //     6..15  reserved
    WP: bool = false, // 16  write protect (1 = supervisor honors read-only pages)
    _r1: u1 = 0, //      17  reserved
    AM: bool = false, // 18  alignment mask (with EFLAGS.AC → #AC alignment checks)
    _r2: u10 = 0, //     19..28  reserved
    NW: bool = false, // 29  not write-through (legacy cache write policy)
    CD: bool = false, // 30  cache disable (1 = caching off)
    PG: bool = false, // 31  paging enable (1 = MMU on; translate via CR3)
    _hi: u32 = 0, //     32..63  reserved

    pub fn fromBits(v: u64) Cr0 {
        return @bitCast(v);
    }
    pub fn toBits(self: Cr0) u64 {
        return @bitCast(self);
    }
};

// Control register 4. Long mode requires PAE (bit 5). The `packed struct(u64)`
// backing integer makes a miscounted reserved field a compile error.
pub const Cr4 = packed struct(u64) {
    VME: bool = false, // 0
    PVI: bool = false, // 1
    TSD: bool = false, // 2
    DE: bool = false, // 3
    PSE: bool = false, // 4
    PAE: bool = false, // 5  (required for long mode)
    MCE: bool = false, // 6
    PGE: bool = false, // 7
    PCE: bool = false, // 8
    OSFXSR: bool = false, // 9
    OSXMMEXCPT: bool = false, // 10
    UMIP: bool = false, // 11
    LA57: bool = false, // 12
    VMXE: bool = false, // 13
    SMXE: bool = false, // 14
    _r0: u1 = 0, // 15
    FSGSBASE: bool = false, // 16
    PCIDE: bool = false, // 17
    OSXSAVE: bool = false, // 18
    _r1: u1 = 0, // 19
    SMEP: bool = false, // 20
    SMAP: bool = false, // 21
    PKE: bool = false, // 22
    CET: bool = false, // 23
    PKS: bool = false, // 24
    _hi: u39 = 0, // 25..63

    pub fn fromBits(v: u64) Cr4 {
        return @bitCast(v);
    }
    pub fn toBits(self: Cr4) u64 {
        return @bitCast(self);
    }
};

// Extended Feature Enable Register (MSR 0xC000_0080). LME (bit 8) enables long
// mode; LMA (bit 10) is set by hardware once paging comes on.
pub const Efer = packed struct(u64) {
    SCE: bool = false, // 0   system-call extensions
    _r0: u7 = 0, // 1..7
    LME: bool = false, // 8   long mode enable
    _r1: u1 = 0, // 9
    LMA: bool = false, // 10  long mode active (HW-derived)
    NXE: bool = false, // 11  no-execute enable
    _hi: u52 = 0, // 12..63

    pub fn fromBits(v: u64) Efer {
        return @bitCast(v);
    }
    pub fn toBits(self: Efer) u64 {
        return @bitCast(self);
    }
};

// IA32_APIC_BASE (MSR 0x1B). `base` holds the local APIC's MMIO address shifted
// right by 12, the same way a page-table entry holds a frame. Clearing `enable`
// is what a BIOS does to hand the machine to the PIC, so a zeroed value here is
// not a neutral default — it disables the APIC.
pub const ApicBase = packed struct(u64) {
    _r0: u8 = 0, //         0..7   reserved
    bsp: bool = false, //   8      this is the bootstrap processor
    _r1: u1 = 0, //         9      reserved
    x2apic: bool = false, //10     x2APIC mode (EXTD)
    enable: bool = false, //11     xAPIC global enable
    base: u40 = 0, //       12..51 MMIO base >> 12
    _hi: u12 = 0, //        52..63 reserved

    pub fn fromBits(v: u64) ApicBase {
        return @bitCast(v);
    }
    pub fn toBits(self: ApicBase) u64 {
        return @bitCast(self);
    }

    /// The MMIO address `base` names.
    pub fn baseAddr(self: ApicBase) u64 {
        return @as(u64, self.base) << 12;
    }
};

// A 64-bit x86-64 page-table entry — PML4E / PDPTE / PDE / PTE all share this
// layout. `frame` holds the next table's (or the mapped page's) physical address
// shifted right by 12 (it occupies bits 12..51, and the address is always
// 4 KiB-aligned so its low 12 bits are the flags). `ps` marks a leaf mapping
// (a 2 MiB page at the PD level); it must stay 0 in a PML4E and in any entry
// that points at a further table.
pub const PageTableEntry = packed struct(u64) {
    p: bool = false, // 0   present
    rw: bool = false, // 1   writable
    us: bool = false, // 2   user/supervisor (0 = supervisor-only)
    pwt: bool = false, // 3   page-level write-through
    pcd: bool = false, // 4   page-level cache disable
    a: bool = false, // 5   accessed (hardware-set)
    d: bool = false, // 6   dirty (hardware-set, leaf only)
    ps: bool = false, // 7   page size (1 = leaf mapping)
    g: bool = false, // 8   global (leaf only)
    _avail0: u3 = 0, // 9..11
    frame: u40 = 0, // 12..51  physical address >> 12
    _avail1: u11 = 0, // 52..62  (ignored / protection key)
    nx: bool = false, // 63  no-execute

    pub fn fromBits(v: u64) PageTableEntry {
        return @bitCast(v);
    }
    pub fn toBits(self: PageTableEntry) u64 {
        return @bitCast(self);
    }

    /// The physical address `frame` names. For a large-page leaf the low bits
    /// are supplied by the offset instead, and hardware ignores whatever the
    /// frame field holds there — see `LinearAddress.offsetIn`.
    pub fn frameAddr(self: PageTableEntry) u64 {
        return @as(u64, self.frame) << 12;
    }
};

/// A 64-bit linear address, split the way the MMU splits it to walk a 4-level
/// page table. Each index selects an entry in one table; `offset` is the byte
/// within the final 4 KiB frame.
pub const LinearAddress = packed struct(u64) {
    offset: u12 = 0, // 0..11   byte within the 4 KiB page
    pt: u9 = 0, //      12..20  index into the page table
    pd: u9 = 0, //      21..29  index into the page directory
    pdpt: u9 = 0, //    30..38  index into the page-directory-pointer table
    pml4: u9 = 0, //    39..47  index into the PML4
    _sign: u16 = 0, //  48..63  sign extension of bit 47

    pub fn fromBits(v: u64) LinearAddress {
        return @bitCast(v);
    }
    pub fn toBits(self: LinearAddress) u64 {
        return @bitCast(self);
    }

    /// Byte offset within a page of `page_shift` bits — the fields below the
    /// leaf level, which the mapping supplies rather than the frame.
    pub fn offsetIn(self: LinearAddress, page_shift: u6) u64 {
        return self.toBits() & ((@as(u64, 1) << page_shift) - 1);
    }
};

// ---- CPUID leaves ---------------------------------------------------------
//
// Partially decoded on purpose: a leaf has far more bits than any caller needs,
// and naming one it does not use is an unchecked claim about where that bit
// sits. Bits get broken out as callers come to depend on them; the unnamed runs
// are reserved fields that round-trip untouched, so decoding more later cannot
// disturb what is already here.

/// CPUID.1:ECX — feature flags.
pub const Cpuid1Ecx = packed struct(u32) {
    _low: u30 = 0,
    rdrand: bool = false, // 30
    /// Bit 31. Reads as 0 on real silicon; a hypervisor sets it to say the
    /// guest is virtualized.
    hypervisor: bool = false,

    pub fn fromBits(v: u32) Cpuid1Ecx {
        return @bitCast(v);
    }
    pub fn toBits(self: Cpuid1Ecx) u32 {
        return @bitCast(self);
    }
};

/// CPUID.1:EBX. Unlike the feature words, the top three bytes are DATA
/// describing the CPU this leaf was read on, not capabilities.
pub const Cpuid1Ebx = packed struct(u32) {
    brand_index: u8 = 0,
    clflush_size: u8 = 0, // in 8-byte units
    max_logical: u8 = 0, // meaningful only with EDX.HTT
    initial_apic_id: u8 = 0,

    pub fn fromBits(v: u32) Cpuid1Ebx {
        return @bitCast(v);
    }
    pub fn toBits(self: Cpuid1Ebx) u32 {
        return @bitCast(self);
    }
};

/// CPUID.6:ECX — thermal and power management.
pub const Cpuid6Ecx = packed struct(u32) {
    /// Bit 0, "effective frequency interface": the APERF and MPERF MSRs
    /// (0xE7/0xE8) are present.
    eff_freq: bool = false,
    _high: u31 = 0,

    pub fn fromBits(v: u32) Cpuid6Ecx {
        return @bitCast(v);
    }
    pub fn toBits(self: Cpuid6Ecx) u32 {
        return @bitCast(self);
    }
};

/// CPUID.7:EBX — extended feature flags, subleaf 0.
pub const Cpuid7Ebx = packed struct(u32) {
    _low: u18 = 0,
    rdseed: bool = false, // 18
    _high: u13 = 0,

    pub fn fromBits(v: u32) Cpuid7Ebx {
        return @bitCast(v);
    }
    pub fn toBits(self: Cpuid7Ebx) u32 {
        return @bitCast(self);
    }
};

/// CPUID.80000001:ECX — AMD extended feature flags.
pub const AmdExtFeaturesEcx = packed struct(u32) {
    _low: u23 = 0,
    /// Bit 23, PERFCTR_CORE: the core performance counters of Fam15h+ are
    /// present, which is what makes Linux load the AMD PMU driver.
    perfctr_core: bool = false,
    _high: u8 = 0,

    pub fn fromBits(v: u32) AmdExtFeaturesEcx {
        return @bitCast(v);
    }
    pub fn toBits(self: AmdExtFeaturesEcx) u32 {
        return @bitCast(self);
    }
};

// ---- encoding tests -------------------------------------------------------
// These packed structs feed real hardware via toBits(); a one-bit drift is a
// silent guest misconfiguration no build error catches. They are pure, so the
// exact bit positions are pinned here (shift expressions, not hand-computed
// hex, so the assertions are self-evidently correct).

const testing = @import("std").testing;

test "Cr0: bit positions and round-trip" {
    try testing.expectEqual(@as(u64, 1 << 0), (Cr0{ .PE = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 4), (Cr0{ .ET = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 5), (Cr0{ .NE = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 31), (Cr0{ .PG = true }).toBits());

    // A typical long-mode bring-up value: PE | ET | NE.
    const boot = Cr0{ .PE = true, .ET = true, .NE = true };
    try testing.expectEqual(@as(u64, (1 << 0) | (1 << 4) | (1 << 5)), boot.toBits());
    try testing.expectEqual(boot, Cr0.fromBits(boot.toBits()));
}

test "Cr4: bit positions and round-trip" {
    try testing.expectEqual(@as(u64, 1 << 4), (Cr4{ .PSE = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 5), (Cr4{ .PAE = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 7), (Cr4{ .PGE = true }).toBits());

    // What long mode requires: PAE only.
    const boot = Cr4{ .PAE = true };
    try testing.expectEqual(@as(u64, 1 << 5), boot.toBits());
    try testing.expectEqual(boot, Cr4.fromBits(boot.toBits()));
}

test "Efer: bit positions and round-trip" {
    try testing.expectEqual(@as(u64, 1 << 0), (Efer{ .SCE = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 8), (Efer{ .LME = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 10), (Efer{ .LMA = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 11), (Efer{ .NXE = true }).toBits());

    // The exact long-mode boot value: LME | LMA.
    const boot = Efer{ .LME = true, .LMA = true };
    try testing.expectEqual(@as(u64, (1 << 8) | (1 << 10)), boot.toBits());
    try testing.expectEqual(boot, Efer.fromBits(boot.toBits()));
}

test "CPUID leaves: bit positions and round-trip" {
    // These are the bits a caller most often has to clear or set explicitly —
    // hardware random, the effective-frequency MSRs, the performance counters,
    // the hypervisor-present flag. A wrong bit position here changes which
    // feature a guest sees and produces no build error and no obvious failure,
    // so each is pinned against its documented position.
    try testing.expectEqual(@as(u32, 1 << 30), (Cpuid1Ecx{ .rdrand = true }).toBits());
    try testing.expectEqual(@as(u32, 1 << 31), (Cpuid1Ecx{ .hypervisor = true }).toBits());
    try testing.expectEqual(@as(u32, 1 << 18), (Cpuid7Ebx{ .rdseed = true }).toBits());
    try testing.expectEqual(@as(u32, 1 << 0), (Cpuid6Ecx{ .eff_freq = true }).toBits());
    try testing.expectEqual(@as(u32, 1 << 23), (AmdExtFeaturesEcx{ .perfctr_core = true }).toBits());

    // Clearing one bit must leave the rest of the word exactly as it was.
    var ecx = Cpuid1Ecx.fromBits(0xffff_ffff);
    ecx.rdrand = false;
    try testing.expectEqual(@as(u32, 0xffff_ffff & ~@as(u32, 1 << 30)), ecx.toBits());

    // CPUID.1:EBX is byte-addressed data, not flags.
    const ebx = Cpuid1Ebx{ .brand_index = 0x11, .clflush_size = 0x22, .max_logical = 0x33, .initial_apic_id = 0x44 };
    try testing.expectEqual(@as(u32, 0x4433_2211), ebx.toBits());
    try testing.expectEqual(ebx, Cpuid1Ebx.fromBits(ebx.toBits()));
}

test "ApicBase: bit positions and round-trip" {
    try testing.expectEqual(@as(u64, 1 << 8), (ApicBase{ .bsp = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 10), (ApicBase{ .x2apic = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 11), (ApicBase{ .enable = true }).toBits());
    try testing.expectEqual(@as(u64, 0xFEE00 << 12), (ApicBase{ .base = 0xFEE00 }).toBits());

    // A typical bring-up value: the default base, enabled, on the BSP.
    const boot = ApicBase{ .base = 0xFEE0_0000 >> 12, .bsp = true, .enable = true };
    try testing.expectEqual(@as(u64, 0xFEE0_0000 | (1 << 8) | (1 << 11)), boot.toBits());
    try testing.expectEqual(@as(u64, 0xFEE0_0000), boot.baseAddr());
    try testing.expectEqual(boot, ApicBase.fromBits(boot.toBits()));
}

test "PageTableEntry: bit positions and round-trip" {
    try testing.expectEqual(@as(u64, 1 << 0), (PageTableEntry{ .p = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 1), (PageTableEntry{ .rw = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 7), (PageTableEntry{ .ps = true }).toBits());
    try testing.expectEqual(@as(u64, 1 << 63), (PageTableEntry{ .nx = true }).toBits());
    // The frame field starts at bit 12.
    try testing.expectEqual(@as(u64, 0x102 << 12), (PageTableEntry{ .frame = 0x102 }).toBits());

    // A present|writable table link encodes as `next_gpa | 0x3`.
    const link = PageTableEntry{ .p = true, .rw = true, .frame = 0x102 };
    try testing.expectEqual(@as(u64, (0x102 << 12) | 0x3), link.toBits());

    // A present|writable 2 MiB leaf encodes as `gpa | 0x83`.
    const leaf = PageTableEntry{ .p = true, .rw = true, .ps = true, .frame = 0x200 };
    try testing.expectEqual(@as(u64, (0x200 << 12) | 0x83), leaf.toBits());
    try testing.expectEqual(leaf, PageTableEntry.fromBits(leaf.toBits()));
}
