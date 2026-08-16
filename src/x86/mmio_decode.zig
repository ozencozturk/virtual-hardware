const std = @import("std");

// A minimal x86-64 MOV decoder: instruction bytes in, the direction, data
// register, operand size and total instruction length out. `paging.zig` reads
// the bytes out of guest memory at a virtual RIP.
//
// The memory operand's effective address is NOT resolved. The addressing mode
// (ModRM.mod/rm, SIB, displacement) is parsed only far enough to measure the
// instruction.

/// The REX prefix (0x40..0x4F): four extension bits over a fixed 0b0100 tag.
const Rex = packed struct(u8) {
    b: bool = false, //   extends ModRM.rm / SIB.base
    x: bool = false, //   extends SIB.index
    r: bool = false, //   extends ModRM.reg
    w: bool = false, //   64-bit operand size
    tag: u4 = 0b0100, // what makes a byte a REX prefix at all

    fn isRex(byte: u8) bool {
        return @as(Rex, @bitCast(byte)).tag == 0b0100;
    }
};

/// The ModRM byte: addressing mode, register field, and r/m field.
const ModRm = packed struct(u8) {
    rm: u3, //   0..2  register or memory operand
    reg: u3, //  3..5  the other register operand (opcode extension for some ops)
    mod: u2, //  6..7  3 = register-direct, otherwise a memory form
};

/// The SIB byte, present when ModRM selects a scaled-index form.
const Sib = packed struct(u8) {
    base: u3,
    index: u3,
    scale: u2,
};

/// A decoded MOV against a memory-mapped address.
pub const Mov = struct {
    dir: Dir,
    reg: u4, //   data register index 0..15, RAX = 0 through R15 = 15
    size: u8, //  operand size in bytes (1/2/4/8)
    len: u8, //   total instruction length, for advancing RIP

    pub const Dir = enum {
        /// Store a GPR into the MMIO location (the guest writing the device).
        write,
        /// Load the MMIO location into a GPR (the guest reading the device).
        read,
    };
};

/// The architectural maximum x86 instruction length. `decode` rejects anything
/// measuring longer.
pub const MAX_INSTR_LEN = 15;

/// Decode the leading instruction in `bytes`, or null if it is not one of the
/// four register-operand MOV forms against memory: 0x88, 0x89, 0x8A, 0x8B.
/// Null covers everything else, including immediate-source stores (0xC7),
/// register-direct forms, and a truncated byte stream.
pub fn decode(bytes: []const u8) ?Mov {
    var i: usize = 0;
    var op_size: u8 = 4; // 32-bit is the default operand size in long mode
    var rex_r: u1 = 0; // REX.R extends ModRM.reg to r8..r15
    var rex_w = false; // REX.W promotes to a 64-bit operand

    // Consume legacy prefixes (they may appear in any order); only the
    // operand-size override (0x66) changes what we report.
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            0x66 => op_size = 2, // operand-size override → 16-bit
            // address-size override, LOCK/REPNE/REP, and the six segment
            // overrides don't affect the data register or size — skip them.
            0x67, 0xf0, 0xf2, 0xf3, 0x2e, 0x36, 0x3e, 0x26, 0x64, 0x65 => {},
            else => break,
        }
    }
    // An optional REX prefix sits immediately before the opcode (0x40..0x4f).
    if (i < bytes.len and Rex.isRex(bytes[i])) {
        const rex: Rex = @bitCast(bytes[i]);
        rex_w = rex.w;
        rex_r = @intFromBool(rex.r);
        i += 1;
    }
    if (rex_w) op_size = 8; // REX.W overrides a 0x66 that may also be present

    if (i + 1 >= bytes.len) return null; // need at least opcode + ModRM
    const opcode = bytes[i];
    const modrm_idx = i + 1;
    const modrm: ModRm = @bitCast(bytes[modrm_idx]);

    const dir: Mov.Dir, const size: u8 = switch (opcode) {
        0x88 => .{ .write, 1 }, //        MOV r/m8, r8
        0x89 => .{ .write, op_size }, //  MOV r/m, r
        0x8a => .{ .read, 1 }, //         MOV r8, r/m8
        0x8b => .{ .read, op_size }, //   MOV r, r/m
        else => return null,
    };

    const len = instructionLen(bytes, modrm_idx) orelse return null;
    return .{
        .dir = dir,
        // REX.R is the high bit of a 4-bit register number.
        .reg = (@as(u4, rex_r) << 3) | modrm.reg,
        .size = size,
        .len = @intCast(len),
    };
}

/// Total instruction length given the ModRM byte's index: everything through the
/// ModRM, plus an optional SIB byte and displacement. Returns null for a
/// register-direct form (mod == 3 — not a memory access, so not ours) or a
/// truncated byte stream.
fn instructionLen(bytes: []const u8, modrm_idx: usize) ?usize {
    const modrm: ModRm = @bitCast(bytes[modrm_idx]);
    const mod = modrm.mod;
    const rm = modrm.rm;
    if (mod == 3) return null; // register-direct: no memory operand

    var len = modrm_idx + 1; // through the ModRM byte
    const has_sib = (rm == 4); // rm=100 selects a SIB byte
    if (has_sib) {
        if (len >= bytes.len) return null;
        len += 1;
    }
    const sib_base: u3 = if (has_sib) @as(Sib, @bitCast(bytes[modrm_idx + 1])).base else 0;

    len += switch (mod) {
        // mod=00 is normally no displacement, with two disp32 escapes:
        // rm=101 (RIP-relative in 64-bit mode) and a SIB with base=101.
        0 => if (rm == 5 or (has_sib and sib_base == 5)) @as(usize, 4) else 0,
        1 => 1, // disp8
        2 => 4, // disp32
        else => unreachable,
    };
    if (len > bytes.len or len > MAX_INSTR_LEN) return null;
    return len;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "decode: MOV [rdx], eax (writel) → write eax, 4 bytes, len 2" {
    // 89 02 : mov [rdx], eax  (ModRM 0x02 = mod 00, reg 000=eax, rm 010=rdx)
    const op = decode(&[_]u8{ 0x89, 0x02 }).?;
    try testing.expectEqual(Mov.Dir.write, op.dir);
    try testing.expectEqual(@as(u4, 0), op.reg); // eax
    try testing.expectEqual(@as(u8, 4), op.size);
    try testing.expectEqual(@as(u8, 2), op.len);
}

test "decode: MOV eax, [rdx] (readl) → read eax, 4 bytes, len 2" {
    const op = decode(&[_]u8{ 0x8b, 0x02 }).?;
    try testing.expectEqual(Mov.Dir.read, op.dir);
    try testing.expectEqual(@as(u4, 0), op.reg);
    try testing.expectEqual(@as(u8, 4), op.size);
    try testing.expectEqual(@as(u8, 2), op.len);
}

test "decode: a disp8 adds one byte to the length" {
    // 89 42 10 : mov [rdx+0x10], eax  (mod 01 → disp8)
    const op = decode(&[_]u8{ 0x89, 0x42, 0x10 }).?;
    try testing.expectEqual(Mov.Dir.write, op.dir);
    try testing.expectEqual(@as(u4, 0), op.reg);
    try testing.expectEqual(@as(u8, 3), op.len);
}

test "decode: a disp32 adds four bytes" {
    // 89 82 00 01 00 00 : mov [rdx+0x100], eax  (mod 10 → disp32)
    const op = decode(&[_]u8{ 0x89, 0x82, 0x00, 0x01, 0x00, 0x00 }).?;
    try testing.expectEqual(@as(u8, 6), op.len);
}

test "decode: a SIB byte is counted (mod 00, rm 100)" {
    // 89 04 11 : mov [rcx+rdx], eax  (ModRM 0x04 = mod 00 rm 100 → SIB 0x11)
    const op = decode(&[_]u8{ 0x89, 0x04, 0x11 }).?;
    try testing.expectEqual(@as(u8, 3), op.len);
    try testing.expectEqual(@as(u4, 0), op.reg);

    // SIB with base=101 and mod=00 escapes to a disp32: 89 04 15 + 4 bytes.
    const d32 = decode(&[_]u8{ 0x89, 0x04, 0x15, 0x00, 0x00, 0x00, 0x00 }).?;
    try testing.expectEqual(@as(u8, 7), d32.len);
}

test "decode: RIP-relative (mod 00, rm 101) carries a disp32" {
    // 8b 05 xx xx xx xx : mov eax, [rip+disp32]
    const op = decode(&[_]u8{ 0x8b, 0x05, 0x00, 0x00, 0x00, 0x00 }).?;
    try testing.expectEqual(Mov.Dir.read, op.dir);
    try testing.expectEqual(@as(u8, 6), op.len);
}

test "decode: REX.R selects an extended data register and counts toward length" {
    // 44 89 02 : mov [rdx], r8d  (REX 0x44 = REX.R; reg 000 | 8 = 8)
    const op = decode(&[_]u8{ 0x44, 0x89, 0x02 }).?;
    try testing.expectEqual(@as(u4, 8), op.reg); // r8
    try testing.expectEqual(@as(u8, 3), op.len); // prefix included
}

test "decode: 0x66 gives a 16-bit operand; REX.W gives 64-bit" {
    const w16 = decode(&[_]u8{ 0x66, 0x89, 0x02 }).?; // mov [rdx], ax
    try testing.expectEqual(@as(u8, 2), w16.size);
    try testing.expectEqual(@as(u8, 3), w16.len);

    const w64 = decode(&[_]u8{ 0x48, 0x89, 0x02 }).?; // mov [rdx], rax
    try testing.expectEqual(@as(u8, 8), w64.size);

    // REX.W wins even if a 0x66 is also present.
    const both = decode(&[_]u8{ 0x66, 0x48, 0x89, 0x02 }).?;
    try testing.expectEqual(@as(u8, 8), both.size);
    try testing.expectEqual(@as(u8, 4), both.len);
}

test "decode: reg field decodes across the register file (ecx as source)" {
    const op = decode(&[_]u8{ 0x89, 0x0a }).?; // mov [rdx], ecx
    try testing.expectEqual(@as(u4, 1), op.reg);
}

test "decode: a byte MOV reports size 1" {
    const op = decode(&[_]u8{ 0x88, 0x02 }).?; // mov [rdx], al
    try testing.expectEqual(Mov.Dir.write, op.dir);
    try testing.expectEqual(@as(u8, 1), op.size);
}

test "decode: register-direct (mod 11) is rejected — not a memory access" {
    try testing.expectEqual(@as(?Mov, null), decode(&[_]u8{ 0x89, 0xc1 })); // mov ecx, eax
}

test "decode: an unmodelled opcode and a truncated stream return null" {
    try testing.expectEqual(@as(?Mov, null), decode(&[_]u8{ 0xc7, 0x02, 0x00 })); // imm store
    try testing.expectEqual(@as(?Mov, null), decode(&[_]u8{0x89})); // opcode, no ModRM
    try testing.expectEqual(@as(?Mov, null), decode(&[_]u8{})); // empty
    try testing.expectEqual(@as(?Mov, null), decode(&[_]u8{ 0x89, 0x42 })); // disp8 missing
}

test "decode: a zero/NOP pad is rejected rather than decoded" {
    const pad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
    try testing.expectEqual(@as(?Mov, null), decode(&pad));
}
