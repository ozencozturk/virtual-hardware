const std = @import("std");
const testing = std.testing;

pub fn bitrange(value: u64, comptime hi: u6, comptime lo: u6) u64 {
    const mask = createmask(hi, lo);
    return (value & mask) >> lo;
}

pub fn createmask(comptime hi: u6, comptime lo: u6) u64 {
    const width: u7 = @as(u7, hi) - lo + 1;
    const mask: u64 = @truncate((@as(u128, 1) << width) - 1);
    return mask << lo;
}

pub fn getbit(value: u64, bit: u6) u1 {
    return @truncate(value >> bit);
}

// Power-of-two alignment check (alignment = RISC-V access width 1/2/4/8, or
// IALIGN for fetch). Pure predicate; the caller decides the trap policy.
pub fn isAligned(addr: u64, alignment: u64) bool {
    std.debug.assert(alignment != 0 and (alignment & (alignment - 1)) == 0);
    return addr & (alignment - 1) == 0;
}

// True when the window [off, off+len) lies within [0, limit). The `off <= limit`
// guard makes `limit - off` safe, so this never overflows even for hostile
// off/len near maxInt(u64). Callers map false to their own outcome (AccessFault
// for a memory-mapped register, null for a skipped DMA access).
pub fn inBounds(off: u64, len: u64, limit: u64) bool {
    return off <= limit and len <= limit - off;
}

pub fn setbit(value: u64, bit: u6) u64 {
    return value | (@as(u64, 1) << bit);
}

pub fn setrange(value: u64, comptime hi: u6, comptime lo: u6, field: u64) u64 {
    const mask = createmask(hi, lo);
    return (value & ~mask) | ((field << lo) & mask);
}

/// Merge the `mask` bits of `v` into `cur`; bits outside `mask` keep their `cur` value.
/// The canonical WARL/allow-list register write: (cur & ~mask) | (v & mask).
pub fn mergeBits(cur: u64, v: u64, mask: u64) u64 {
    return (cur & ~mask) | (v & mask);
}

pub fn setbitval(value: u64, bit: u6, val: u1) u64 {
    return clearbit(value, bit) | (@as(u64, val) << bit);
}
// all ones except bit
pub fn clearbit(value: u64, bit: u6) u64 {
    const mask = ~setbit(0, bit);
    return value & mask;
}

pub fn sext(imm: anytype) u64 {
    return @bitCast(@as(i64, imm));
}

pub fn signedField(comptime T: type, word: u64, comptime hi: u6, comptime lo: u6) T {
    const U = @Int(.unsigned, @typeInfo(T).int.bits);
    return @bitCast(@as(U, @intCast(bitrange(word, hi, lo))));
}

pub fn u16le(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

pub fn u32le(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
pub fn u64le(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}
test "bitrange" {
    try testing.expectEqual(bitrange(0xDEADBEEF, 31, 28), 0xD);
    try testing.expectEqual(createmask(31, 28), 0x00000000F0000000);
    try testing.expectEqual(createmask(63, 0), 0xFFFFFFFFFFFFFFFF);
    try testing.expectEqual(1, getbit(0xFFFFFFFFFFFFFFFF, 1));
    try testing.expectEqual(1, setbit(0, 0));
    try testing.expectEqual(0, clearbit(1, 0));
}
test "signedField" {
    // I-type imm at [31:20], i12: 0xFFF00000 → field 0xFFF → -1
    try testing.expectEqual(@as(i12, -1), signedField(i12, 0xFFF00000, 31, 20));
    try testing.expectEqual(@as(i12, 1), signedField(i12, 0x00100000, 31, 20));
    try testing.expectEqual(@as(i12, -2048), signedField(i12, 0x80000000, 31, 20)); // most negative
    // U-type imm at [31:12], i20: 0x80000000 → field 0x80000 → most negative i20
    try testing.expectEqual(@as(i20, -524288), signedField(i20, 0x80000000, 31, 12));
}
test "setrange clears then writes, masks overflow" {
    try testing.expectEqual(@as(u64, 0), setrange(0b11 << 11, 12, 11, 0)); // clear
    try testing.expectEqual(@as(u64, 0b11 << 11), setrange(0, 12, 11, 0b111)); // overflow clamped to 2 bits
}
test "mergeBits takes v inside the mask, keeps cur outside" {
    // mask bits come from v (both the set→clear and clear→set directions), rest stay cur
    try testing.expectEqual(@as(u64, 0xF0), mergeBits(0xFF, 0x00, 0x0F)); // low nibble cleared from v
    try testing.expectEqual(@as(u64, 0x0F), mergeBits(0x00, 0xFF, 0x0F)); // low nibble set from v
    try testing.expectEqual(@as(u64, 0xAB), mergeBits(0xA0, 0x0B, 0x0F)); // splice: hi from cur, lo from v
    // bits of v outside the mask are ignored
    try testing.expectEqual(@as(u64, 0xA0), mergeBits(0xA0, 0xF0, 0x0F));
    // identity edges
    try testing.expectEqual(@as(u64, 0x1234), mergeBits(0x1234, 0xFFFF, 0)); // empty mask → cur unchanged
    try testing.expectEqual(@as(u64, 0xFFFF), mergeBits(0x1234, 0xFFFF, ~@as(u64, 0))); // full mask → v
}
test "inBounds" {
    const max = std.math.maxInt(u64);
    // ordinary in/out of range
    try testing.expect(inBounds(0, 8, 0x10000));
    try testing.expect(inBounds(0xFFF8, 8, 0x10000)); // last aligned window fits exactly
    try testing.expect(!inBounds(0xFFF9, 8, 0x10000)); // window runs one byte past
    try testing.expect(!inBounds(0x10000, 4, 0x10000)); // off at limit, non-zero len
    // zero-length edges: off == limit with len 0 is in-bounds (empty slice)
    try testing.expect(inBounds(0x10000, 0, 0x10000));
    try testing.expect(!inBounds(0x10001, 0, 0x10000)); // off past limit even for len 0
    // overflow safety: a hostile off/len near maxInt must not wrap to "in-bounds"
    try testing.expect(!inBounds(max, 8, 0x10000));
    try testing.expect(!inBounds(0x8000, max, 0x10000));
}
test "isAligned" {
    try std.testing.expect(isAligned(0x1000, 8));
    try std.testing.expect(isAligned(0x8000_0004, 4));
    try std.testing.expect(!isAligned(0x8000_0002, 4));
    try std.testing.expect(!isAligned(0x1001, 2));
    try std.testing.expect(isAligned(0xdead_beef, 1)); // byte access never misaligns
}
