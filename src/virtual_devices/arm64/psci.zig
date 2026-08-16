//! psci.zig — the PSCI (Power State Coordination Interface) firmware ABI.
//!
//! Unlike every other guest interaction so far, this is not a memory access that
//! faulted: it is a FUNCTION CALL into a higher exception level. The guest kernel
//! executes `hvc #0` and traps to EL2 with ESR_EL2.EC = 0x16. Nothing is mapped,
//! no address faults, and `exit.physical_address` is meaningless here.
//!
//! The register contract is SMCCC's, not ours: w0 carries the Function ID in and
//! the return value out; x1..x3 carry arguments. That is why `handle` reads GPR 0
//! and writes GPR 0, and why it needs nothing but the caller's vCPU seam — which
//! keeps this file free of any hypervisor API and fully unit-testable.
//!
//! THE LANDMINE, and it INVERTS the sysreg-trap path (EC 0x18): do NOT advance the
//! PC after an HVC. A *trap* leaves the PC on the faulting instruction, so a sysreg
//! handler must step over it. A *call* has already moved past it — the ELR points at
//! the instruction after the `hvc`. Advancing anyway silently skips one instruction
//! of kernel code. KVM encodes the same asymmetry: handle_hvc does not increment,
//! handle_smc does.

const std = @import("std");
const testing = std.testing;

// SMCCC Function IDs. These are bitfields, not magic numbers:
//   bit 31    Fast Call (always 1 for PSCI) -> the leading 8 or c
//   bit 30    SMC64 (1) vs SMC32 (0) calling convention
//   bits 29:24  Owning Entity Number; 0x4 = Standard Secure Service -> the `4`
//   bits 15:0   function number
// The _64 suffixes are forced: a call is SMC64 exactly when it moves a 64-bit
// value (an entry-point address, an MPIDR). The rest are SMC32 only.
pub const VERSION: u32 = 0x8400_0000;
pub const CPU_OFF: u32 = 0x8400_0002;
pub const SYSTEM_OFF: u32 = 0x8400_0008;
pub const SYSTEM_RESET: u32 = 0x8400_0009;
pub const FEATURES: u32 = 0x8400_000a;
pub const CPU_SUSPEND_64: u32 = 0xc400_0001;
pub const CPU_ON_64: u32 = 0xc400_0003;
pub const AFFINITY_INFO_64: u32 = 0xc400_0004;

/// PSCI_VERSION(major, minor) = (major << 16) | minor. We answer 1.1.
pub const V1_1: u64 = (1 << 16) | 1;

pub const SUCCESS: i64 = 0;
pub const NOT_SUPPORTED: i64 = -1;

/// Service one `hvc #0`. Returns true to tell the caller to STOP the machine.
///
/// An unknown FID answers NOT_SUPPORTED rather than failing loudly — the exact
/// OPPOSITE of the right default for a sysreg trap, and for the same underlying
/// reason: match the contract the caller expects. Linux *probes* with PSCI_FEATURES
/// and reads -1 as a legitimate "you don't have that". Failing there would kill the
/// boot on a question the guest asked politely. Nobody probes sysregs, so those
/// should still fail.
pub fn handle(cpu: anytype) !bool {
    const fid: u32 = @truncate(try cpu.getGpr(0));
    switch (fid) {
        VERSION => try setRet(cpu, @bitCast(V1_1)),
        // No return value: the guest never runs again. Stop before writing x0.
        SYSTEM_OFF, SYSTEM_RESET => return true,
        FEATURES => {
            const arg: u32 = @truncate(try cpu.getGpr(1));
            try setRet(cpu, if (implemented(arg)) SUCCESS else NOT_SUPPORTED);
        },
        else => try setRet(cpu, NOT_SUPPORTED),
    }
    return false;
}

/// The single source of truth for "does handle() actually service this FID?", so
/// PSCI_FEATURES cannot drift out of agreement with the switch above. Answering
/// 1.1 while lying about what we implement is worse than answering 0.2 honestly.
///
/// CPU_OFF / CPU_SUSPEND / CPU_ON / AFFINITY_INFO are deliberately absent: they
/// are for SECONDARIES, so a single-CPU machine never sees them — Linux does not
/// call them on a tree whose only cpu carries no enable-method. A machine that
/// brings up secondaries must add them BOTH here and to the switch in `handle`,
/// or FEATURES will advertise what handle does not service.
fn implemented(fid: u32) bool {
    return switch (fid) {
        VERSION, SYSTEM_OFF, SYSTEM_RESET, FEATURES => true,
        else => false,
    };
}

fn setRet(cpu: anytype, v: i64) !void {
    try cpu.setGpr(0, @bitCast(v));
}

// ---- Tests -----------------------------------------------------------------
// This file needs nothing but the vCPU seam and calls no hypervisor API, so every
// line here is reachable from `zig build test`. The fake below is the whole harness
// — and it doubles as the reference for the shape `handle` expects of `cpu`.

const FakeVcpu = struct {
    regs: [31]u64 = @splat(0), // x0..x30
    pc: u64 = 0,

    fn getGpr(self: *FakeVcpu, srt: u5) !u64 {
        return if (srt == 31) 0 else self.regs[srt];
    }
    fn setGpr(self: *FakeVcpu, srt: u5, val: u64) !void {
        if (srt != 31) self.regs[srt] = val;
    }
};

/// Drive one call the way the guest would: FID in x0, arg in x1.
fn call(cpu: *FakeVcpu, fid: u32, arg: u64) !bool {
    try cpu.setGpr(0, fid);
    try cpu.setGpr(1, arg);
    return handle(cpu);
}

fn retOf(cpu: *FakeVcpu) i64 {
    return @bitCast(cpu.regs[0]);
}

// The first HVC the kernel will ever make: psci_probe() calls PSCI_VERSION before
// anything else, and the answer is what makes it go on to probe features.
test "psci: VERSION answers 1.1 and does not stop the machine" {
    var cpu = FakeVcpu{};
    try testing.expectEqual(false, try call(&cpu, VERSION, 0));
    try testing.expectEqual(@as(u64, 0x0001_0001), cpu.regs[0]);
}

// What this guards: `poweroff` in the guest shell must end the run.
test "psci: SYSTEM_OFF and SYSTEM_RESET stop the machine" {
    for ([_]u32{ SYSTEM_OFF, SYSTEM_RESET }) |fid| {
        var cpu = FakeVcpu{};
        try testing.expectEqual(true, try call(&cpu, fid, 0));
    }
}

// The locked default, and the opposite of a sysreg trap's: a FID we don't service
// is answered politely, NOT refused. Getting this backwards kills the boot on a
// probe. CPU_ON_64 is the realistic case — a real FID we really don't implement.
test "psci: an unknown FID answers NOT_SUPPORTED and keeps running" {
    for ([_]u32{ CPU_ON_64, CPU_OFF, CPU_SUSPEND_64, AFFINITY_INFO_64, 0x8400_00ff }) |fid| {
        var cpu = FakeVcpu{};
        try testing.expectEqual(false, try call(&cpu, fid, 0));
        try testing.expectEqual(NOT_SUPPORTED, retOf(&cpu));
    }
}

// PSCI_FEATURES is what makes the 1.1 claim honest, so it must agree with the
// switch in handle() — for EVERY FID, not just the ones we remembered to check.
// This is the drift this file is most likely to suffer: add a FID to handle() and
// forget FEATURES, and Linux never calls the thing we just implemented.
test "psci: FEATURES agrees with what handle actually services" {
    for ([_]u32{ VERSION, SYSTEM_OFF, SYSTEM_RESET, FEATURES }) |fid| {
        var cpu = FakeVcpu{};
        try testing.expectEqual(false, try call(&cpu, FEATURES, fid));
        try testing.expectEqual(SUCCESS, retOf(&cpu));
    }
    for ([_]u32{ CPU_OFF, CPU_SUSPEND_64, CPU_ON_64, AFFINITY_INFO_64, 0x8400_00ff }) |fid| {
        var cpu = FakeVcpu{};
        try testing.expectEqual(false, try call(&cpu, FEATURES, fid));
        try testing.expectEqual(NOT_SUPPORTED, retOf(&cpu));
        // ...and the other half of "agrees": handle really doesn't service it.
        var probe = FakeVcpu{};
        try testing.expectEqual(false, try call(&probe, fid, 0));
        try testing.expectEqual(NOT_SUPPORTED, retOf(&probe));
    }
}

// THE LANDMINE, asserted. An HVC's ELR already points past the instruction, so
// advancing skips a real instruction of kernel code — a corruption that would not
// show up here at all, only as an inexplicable guest misbehaviour later.
test "psci: handling an HVC never advances the PC" {
    for ([_]u32{ VERSION, FEATURES, SYSTEM_OFF, CPU_ON_64 }) |fid| {
        var cpu = FakeVcpu{};
        _ = try call(&cpu, fid, VERSION);
        try testing.expectEqual(@as(u64, 0), cpu.pc);
    }
}

// NOT_SUPPORTED is -1, and x0 is unsigned: the guest must see all 64 bits set.
// A naive write of the i64 through a u32 would leave 0x00000000_ffffffff, which
// Linux's 32-bit `int err` truncation would READ AS CORRECT — passing this test
// by accident is exactly how a sign bug survives to bite SMC64 callers.
test "psci: NOT_SUPPORTED lands in x0 as a full 64-bit -1" {
    var cpu = FakeVcpu{};
    _ = try call(&cpu, CPU_ON_64, 0);
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), cpu.regs[0]);
}
