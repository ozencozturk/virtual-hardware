const std = @import("std");

pub const Header = extern struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,

    comptime {
        std.debug.assert(@sizeOf(Header) == 40);
    }
};

pub const ReserveEntry = extern struct {
    address: u64,
    size: u64,
    comptime {
        std.debug.assert(@sizeOf(ReserveEntry) == 16);
    }
};

pub const MAGIC: u32 = 0xd00d_feed;
pub const VERSION: u32 = 17;
pub const LAST_COMP_VERSION: u32 = 16;
const HEADER_SIZE: usize = @sizeOf(Header);
const MEMRSV_OFF: usize = HEADER_SIZE;
const MEMRSV_SIZE: usize = @sizeOf(ReserveEntry);
const STRUCT_OFF: usize = MEMRSV_OFF + MEMRSV_SIZE;

pub const Value = union(enum) {
    empty,
    string: []const u8,
    strings: []const []const u8,
    u32: u32,
    u64: u64,
    cells: []const u32,
};

pub const Prop = struct {
    name: []const u8,
    value: Value,
};

pub const Node = struct {
    name: []const u8,
    props: []const Prop = &.{},
    children: []const Node = &.{},
};

pub fn serialize(buf: []u8, strings: []u8, root: Node) ![]u8 {
    var w = Writer{ .buf = buf, .strings = strings };
    if (buf.len < STRUCT_OFF) {
        return error.FdtBufferTooSmall;
    }
    @memset(buf[0..STRUCT_OFF], 0);

    try w.node(root);
    try w.word(END);

    const strings_off = w.pos;
    try w.raw(w.strings[0..w.str_len]);
    const total = w.pos;

    var h = Header{
        .magic = MAGIC,
        .totalsize = @intCast(total),
        .off_dt_struct = STRUCT_OFF,
        .off_dt_strings = @intCast(strings_off),
        .off_mem_rsvmap = MEMRSV_OFF,
        .version = VERSION,
        .last_comp_version = LAST_COMP_VERSION,
        .boot_cpuid_phys = 0,
        .size_dt_strings = @intCast(w.str_len),
        .size_dt_struct = @intCast(strings_off - STRUCT_OFF),
    };
    std.mem.byteSwapAllFields(Header, &h);
    @memcpy(buf[0..HEADER_SIZE], std.mem.asBytes(&h));
    return buf[0..total];
}

const BEGIN_NODE: u32 = 1;
const END_NODE: u32 = 2;
const PROP: u32 = 3;
const END: u32 = 9;

const Writer = struct {
    buf: []u8,
    pos: usize = STRUCT_OFF,
    strings: []u8,
    str_len: usize = 0,

    fn node(self: *Writer, n: Node) !void {
        try self.word(BEGIN_NODE);
        try self.raw(n.name);
        try self.raw(&[_]u8{0});
        try self.pad();

        for (n.props) |p| {
            try self.prop(p);
        }
        for (n.children) |c| {
            try self.node(c);
        }
        try self.word(END_NODE);
    }

    fn prop(self: *Writer, p: Prop) !void {
        const name_offset = try self.intern(p.name);
        var scratch: [128]u8 = undefined;
        const bytes = try encodeValue(&scratch, p.value);
        try self.word(PROP);
        try self.word(@intCast(bytes.len));
        try self.word(name_offset);
        try self.raw(bytes);
        try self.pad();
    }

    fn pad(self: *Writer) !void {
        while (self.pos % 4 != 0) {
            try self.raw(&[_]u8{0});
        }
    }
    fn intern(self: *Writer, name: []const u8) !u32 {
        var i: usize = 0;
        while (i < self.str_len) {
            const entry = std.mem.sliceTo(self.strings[i..self.str_len], 0);
            if (std.mem.eql(u8, entry, name)) return @intCast(i);
            i += entry.len + 1;
        }
        if (self.str_len + name.len + 1 > self.strings.len) return error.FdtStringsTooSmall;
        @memcpy(self.strings[self.str_len..][0..name.len], name);
        self.strings[self.str_len + name.len] = 0;
        defer self.str_len += name.len + 1;
        return @intCast(self.str_len);
    }

    fn word(self: *Writer, v: u32) !void {
        if (self.pos + 4 > self.buf.len) return error.FdtBufferTooSmall;
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .big);
        self.pos += 4;
    }

    fn raw(self: *Writer, b: []const u8) !void {
        if (self.pos + b.len > self.buf.len) return error.FdtBufferTooSmall;
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
};

fn encodeValue(scratch: []u8, v: Value) ![]const u8 {
    switch (v) {
        .empty => return scratch[0..0],
        .string => |s| {
            if (s.len + 1 > scratch.len) return error.FdtValueTooLarge;
            @memcpy(scratch[0..s.len], s);
            scratch[s.len] = 0;
            return scratch[0 .. s.len + 1];
        },
        .strings => |list| {
            var n: usize = 0;
            for (list) |s| {
                if (n + s.len + 1 > scratch.len) return error.FdtValueTooLarge;
                @memcpy(scratch[n..][0..s.len], s);
                n += s.len;
                scratch[n] = 0;
                n += 1;
            }
            return scratch[0..n];
        },
        .u32 => |x| {
            if (scratch.len < 4) return error.FdtValueTooLarge;
            std.mem.writeInt(u32, scratch[0..4], x, .big);
            return scratch[0..4];
        },
        .u64 => |x| {
            if (scratch.len < 8) return error.FdtValueTooLarge;
            std.mem.writeInt(u32, scratch[0..4], @truncate(x >> 32), .big);
            std.mem.writeInt(u32, scratch[4..8], @truncate(x), .big);
            return scratch[0..8];
        },
        .cells => |cs| {
            if (cs.len * 4 > scratch.len) return error.FdtValueTooLarge;
            for (cs, 0..) |c, i| {
                std.mem.writeInt(u32, scratch[i * 4 ..][0..4], c, .big);
            }
            return scratch[0 .. cs.len * 4];
        },
    }
}

// ---- Tests -----------------------------------------------------------------
// Three layers, deliberately:
//   - Header/ReserveEntry + the derived offsets, against dtc's REAL header bytes.
//   - Writer and encodeValue, driven DIRECTLY (file-private, same-file-visible).
//     These are the finest-grained tests and they name the function that broke.
//   - serialize(), which is the only thing that can cover what composition adds:
//     the header backpatch, the big-endian swap, the memrsv terminator, FDT_END,
//     and the strings block landing after the struct block.
//
// The Writer layer is not redundant with the serialize layer: Writer.node never
// emits FDT_END (serialize does), and a Writer test failing points at one function
// rather than at "the blob is wrong somewhere".

const testing = std.testing;

/// The 40 header bytes dtc ACTUALLY emitted for a real device tree, frozen here.
/// Reproduce with `xxd -l 40 -g 4 <any dtc-produced .dtb>`.
///
/// This is an EXTERNAL oracle — the whole value is that these bytes did not come
/// from us. Frozen as a literal rather than @embedFile'd on purpose: no .dtb
/// artifact is shipped with this package, and the oracle should outlive any one.
const dtc_header_bytes = [40]u8{
    0xd0, 0x0d, 0xfe, 0xed, // magic
    0x00, 0x00, 0x04, 0x9f, // totalsize         = 1183
    0x00, 0x00, 0x00, 0x38, // off_dt_struct     = 56
    0x00, 0x00, 0x03, 0xdc, // off_dt_strings    = 988
    0x00, 0x00, 0x00, 0x28, // off_mem_rsvmap    = 40
    0x00, 0x00, 0x00, 0x11, // version           = 17
    0x00, 0x00, 0x00, 0x10, // last_comp_version = 16
    0x00, 0x00, 0x00, 0x00, // boot_cpuid_phys   = 0
    0x00, 0x00, 0x00, 0xc3, // size_dt_strings   = 195
    0x00, 0x00, 0x03, 0xa4, // size_dt_struct    = 932
};

// `@sizeOf(Header) == 40` does NOT catch a transposition: swap any two u32 fields
// and it is still 40 bytes. THIS catches it — every field holds a different
// number, and the numbers came from dtc rather than from us. It is the same shape
// as any header test read against a real, externally produced binary.
//
// The order is worth staring at: off_dt_struct(8), off_dt_strings(12),
// off_mem_rsvmap(16) are listed in the OPPOSITE order from the regions they point
// at in the file (memrsv comes first, at 40). That inversion is exactly what a
// hand-counted layout gets wrong, and exactly what this pins down.
test "fdt: Header's field order matches a real dtc-produced header" {
    var h = std.mem.bytesToValue(Header, &dtc_header_bytes);
    std.mem.byteSwapAllFields(Header, &h);
    try testing.expectEqual(MAGIC, h.magic);
    try testing.expectEqual(@as(u32, 1183), h.totalsize);
    try testing.expectEqual(@as(u32, 56), h.off_dt_struct);
    try testing.expectEqual(@as(u32, 988), h.off_dt_strings);
    try testing.expectEqual(@as(u32, 40), h.off_mem_rsvmap);
    try testing.expectEqual(VERSION, h.version);
    try testing.expectEqual(LAST_COMP_VERSION, h.last_comp_version);
    try testing.expectEqual(@as(u32, 0), h.boot_cpuid_phys);
    try testing.expectEqual(@as(u32, 195), h.size_dt_strings);
    try testing.expectEqual(@as(u32, 932), h.size_dt_struct);
}

// The whole header design in one assertion, provable before serialize() exists:
// build it in NATIVE endianness (reading like the spec), swap once, and the bytes
// must be dtc's exactly. If this holds, serialize()'s header half is already done.
//
// Note this is the direction that matters — WRITING. The test above only proves we
// can read dtc's bytes back; this proves we can produce them.
test "fdt: a natively-built Header serializes to dtc's exact bytes" {
    var h = Header{
        .magic = MAGIC,
        .totalsize = 1183,
        .off_dt_struct = 56,
        .off_dt_strings = 988,
        .off_mem_rsvmap = 40,
        .version = VERSION,
        .last_comp_version = LAST_COMP_VERSION,
        .boot_cpuid_phys = 0,
        .size_dt_strings = 195,
        .size_dt_struct = 932,
    };
    std.mem.byteSwapAllFields(Header, &h);
    try testing.expectEqualSlices(u8, &dtc_header_bytes, std.mem.asBytes(&h));
}

// The region offsets are DERIVED from @sizeOf, so they are only correct if the
// structs are. dtc's blob is the check: 40 (header) + 16 (one {0,0} memrsv entry)
// = 56 is precisely what a real DTB carries in off_dt_struct. Add a field to
// Header or ReserveEntry and this goes red before anything else notices.
test "fdt: the derived region offsets agree with dtc's" {
    var h = std.mem.bytesToValue(Header, &dtc_header_bytes);
    std.mem.byteSwapAllFields(Header, &h);
    try testing.expectEqual(@as(usize, h.off_mem_rsvmap), MEMRSV_OFF);
    try testing.expectEqual(@as(usize, h.off_dt_struct), STRUCT_OFF);
    try testing.expectEqual(@as(usize, 16), MEMRSV_SIZE); // one {0,0} terminator

    // ...and dtc's own internal consistency — the invariant serialize() must
    // reproduce, stated here against real numbers rather than against our maths.
    try testing.expectEqual(h.off_dt_strings, h.off_dt_struct + h.size_dt_struct);
    try testing.expectEqual(h.totalsize, h.off_dt_strings + h.size_dt_strings);
}

// ---- encodeValue ------------------------------------------------------------

// encodeValue is a pure function, so test it as one — every arm, including the
// two traps: a string's length INCLUDES the NUL (ns16550a is 9, not 8), and
// `empty` is length 0 but PRESENT (zero-length is not absent).
test "fdt: encodeValue covers every arm, NUL included" {
    var s: [128]u8 = undefined;

    // Zero-length, but the property still exists — `ranges`, `always-on`.
    try testing.expectEqual(@as(usize, 0), (try encodeValue(&s, .empty)).len);

    try testing.expectEqualSlices(u8, "ns16550a\x00", try encodeValue(&s, .{ .string = "ns16550a" }));

    // A DT string LIST is one value: NUL-separated, NUL-terminated. /psci's real one.
    try testing.expectEqualSlices(u8, "arm,psci-1.0\x00arm,psci-0.2\x00", try encodeValue(&s, .{
        .strings = &.{ "arm,psci-1.0", "arm,psci-0.2" },
    }));

    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2 }, try encodeValue(&s, .{ .u32 = 2 }));

    // u64 is TWO cells, HIGH FIRST — not a native 8-byte write. Distinct bytes in
    // every position, so a hi/lo swap or a native write cannot pass by coincidence.
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 }, try encodeValue(&s, .{
        .u64 = 0x1122_3344_5566_7788,
    }));
    // ...and the real one from /chosen, where hi is 0 — the case that would let a
    // swapped implementation look plausible if you only eyeballed it.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0x90, 0x22, 0x08, 0x00 }, try encodeValue(&s, .{
        .u64 = 0x9022_0800,
    }));

    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0, 0, 0, 2 }, try encodeValue(&s, .{ .cells = &.{ 1, 2 } }));
}

// THE test that would have caught `error.FdtValueTooLrage`: it names the error, so
// a typo'd arm fails here rather than widening an inferred error set in silence.
// Every arm that can overflow is exercised — `.empty` is excluded because it
// cannot (it writes nothing).
test "fdt: encodeValue refuses a value larger than its scratch buffer" {
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.FdtValueTooLarge, encodeValue(&tiny, .{ .string = "abcd" })); // 4+NUL > 4
    try testing.expectError(error.FdtValueTooLarge, encodeValue(&tiny, .{ .strings = &.{ "ab", "cd" } })); // 3+3 > 4
    try testing.expectError(error.FdtValueTooLarge, encodeValue(&tiny, .{ .u64 = 0 })); // 8 > 4
    try testing.expectError(error.FdtValueTooLarge, encodeValue(&tiny, .{ .cells = &.{ 1, 2 } })); // 8 > 4

    var none: [0]u8 = undefined;
    try testing.expectError(error.FdtValueTooLarge, encodeValue(&none, .{ .u32 = 1 })); // 4 > 0
}

// ---- Writer -----------------------------------------------------------------

// word() is the ONLY place a u32 enters the struct block, so `.big` living here is
// the whole endianness guarantee for everything except the header. Asserted as raw
// bytes, never readInt(.big) — readInt would agree with a little-endian writer if
// the test and the code shared the same mistake.
test "fdt: word writes one big-endian u32 and advances pos by 4" {
    var buf: [64]u8 = undefined;
    var strs: [8]u8 = undefined;
    var w = Writer{ .buf = &buf, .strings = &strs };

    // Writing starts after the header and the memrsv block, never at 0.
    try testing.expectEqual(@as(usize, 56), w.pos);
    try w.word(0xd00d_feed);
    try testing.expectEqual(@as(usize, 60), w.pos);
    try testing.expectEqualSlices(u8, &.{ 0xd0, 0x0d, 0xfe, 0xed }, buf[56..60]);
}

// Tokens and property values are all 4-aligned; miss one and every token after it
// is read from a misaligned offset — the tree is garbage from there on, with no
// diagnostic. The already-aligned case is the one that matters in practice: it runs
// after every 4-byte value and must be a no-op, not a 4-byte skip.
test "fdt: pad rounds pos up to the next 4-byte boundary with zeroes" {
    var buf: [64]u8 = undefined;
    var strs: [8]u8 = undefined;
    var w = Writer{ .buf = &buf, .strings = &strs };

    try w.raw("a");
    try testing.expectEqual(@as(usize, 57), w.pos);
    try w.pad();
    try testing.expectEqual(@as(usize, 60), w.pos);
    try testing.expectEqualSlices(u8, &.{ 'a', 0, 0, 0 }, buf[56..60]);

    try w.pad(); // already aligned
    try testing.expectEqual(@as(usize, 60), w.pos);
}

// Names repeat constantly ("reg", "compatible"), so a dedupe bug is invisible — the
// tree still parses, just bigger — until the strings buffer overflows on a tree you
// didn't expect to grow.
//
// The first assert is also the one with teeth on intern's `defer`: it returns the
// offset the name was written AT, then advances. Reorder those two lines and this
// returns 4 instead of 0, every nameoff shifts by one entry, and the blob parses
// fine with every property misnamed.
test "fdt: intern returns a name's offset and dedupes repeats" {
    var buf: [64]u8 = undefined;
    var strs: [64]u8 = undefined;
    var w = Writer{ .buf = &buf, .strings = &strs };

    try testing.expectEqual(@as(u32, 0), try w.intern("reg"));
    try testing.expectEqual(@as(u32, 4), try w.intern("compatible")); // after "reg\0"
    try testing.expectEqual(@as(u32, 0), try w.intern("reg")); // deduped, not appended
    try testing.expectEqual(@as(u32, 4), try w.intern("compatible"));

    try testing.expectEqual(@as(usize, 15), w.str_len); // "reg\0" + "compatible\0"
    try testing.expectEqualStrings("reg\x00compatible\x00", strs[0..15]);
}

// Pins a DELIBERATE deviation from a naive byte-scan intern, which would match
// suffixes ("cells\0" inside "#address-cells\0" is a correctly terminated
// "cells"). The entry-walk compares whole NUL-delimited entries only, so it appends.
//
// The cost is bounded and the output stays CORRECT either way — a tree whose names
// are suffixes of one another simply spends a few extra bytes in the strings block,
// which is what this test pins. dtc itself shares nothing across whole entries in
// the blobs checked here, so for a tree with no suffix pairs the output is
// byte-identical to dtc's; for one with them, it is merely larger.
test "fdt: intern matches whole entries only, not suffixes" {
    var buf: [64]u8 = undefined;
    var strs: [64]u8 = undefined;
    var w = Writer{ .buf = &buf, .strings = &strs };

    try testing.expectEqual(@as(u32, 0), try w.intern("#address-cells"));
    try testing.expectEqual(@as(u32, 15), try w.intern("cells")); // appended, not shared at offset 9
}

test "fdt: intern refuses a name that overflows the strings buffer" {
    var buf: [64]u8 = undefined;
    var strs: [4]u8 = undefined; // exactly "reg\0"
    var w = Writer{ .buf = &buf, .strings = &strs };

    try testing.expectEqual(@as(u32, 0), try w.intern("reg"));
    try testing.expectError(error.FdtStringsTooSmall, w.intern("model"));
}

// A minimal node, checked byte-for-byte against the format. This is the only thing
// standing between a plausible-looking blob and a silent hang, and it needs no
// parser: the expected bytes are short enough to state. Also the only test that
// covers prop() — its three-word {token, len, nameoff} head is visible here.
test "fdt: a node with one cell property encodes exactly" {
    var buf: [256]u8 = undefined;
    var strs: [64]u8 = undefined;
    var w = Writer{ .buf = &buf, .strings = &strs };

    try w.node(.{
        .name = "",
        .props = &.{.{ .name = "#address-cells", .value = .{ .u32 = 2 } }},
    });

    try testing.expectEqualSlices(u8, &.{
        0, 0, 0, 1, // FDT_BEGIN_NODE
        0, 0, 0, 0, // name "" + NUL, padded to 4
        0, 0, 0, 3, // FDT_PROP
        0, 0, 0, 4, // len = 4
        0, 0, 0, 0, // nameoff = 0
        0, 0, 0, 2, // value = <2>, BIG-endian
        0, 0, 0, 2, // FDT_END_NODE
    }, buf[56..w.pos]);
    try testing.expectEqualStrings("#address-cells\x00", strs[0..w.str_len]);
}

// Nesting is the one thing the tree shape is FOR: a child's tokens must sit strictly
// between its parent's BEGIN and END. There is no balance to police here (unbalanced
// is unrepresentable) — what this checks is that node() recurses in the right place,
// i.e. children come after props and before the parent's END_NODE.
test "fdt: a child node nests between its parent's tokens" {
    var buf: [256]u8 = undefined;
    var strs: [64]u8 = undefined;
    var w = Writer{ .buf = &buf, .strings = &strs };

    try w.node(.{ .name = "", .children = &.{.{ .name = "cpus" }} });

    try testing.expectEqualSlices(u8, &.{
        0, 0, 0, 1, // FDT_BEGIN_NODE (root)
        0, 0, 0, 0, // "" + NUL, padded
        0, 0, 0, 1, // FDT_BEGIN_NODE (cpus)
        'c', 'p', 'u', 's', // name
        0, 0, 0, 0, //         NUL + 3 pad
        0, 0, 0, 2, // FDT_END_NODE (cpus)
        0, 0, 0, 2, // FDT_END_NODE (root)
    }, buf[56..w.pos]);
}

// The buffer is guest RAM. Running off the end must be an error, not a write into
// whatever the kernel put after DTB_OFF.
//
// There are TWO bounds checks — raw()'s and word()'s — and one test cannot reach
// both, so there are two tests. Found the hard way: a control that renamed word()'s
// error left the suite green, because this case errors inside raw().
//
// This one: the name overruns. word(BEGIN_NODE) fits exactly (56+4 == 60), then
// raw() trips on the 23-byte name. Covers raw().
test "fdt: a buffer too small errors instead of overrunning" {
    var buf: [60]u8 = undefined; // 56 header+memrsv, room for exactly one token
    var strs: [64]u8 = undefined;
    var w = Writer{ .buf = &buf, .strings = &strs };

    try testing.expectError(error.FdtBufferTooSmall, w.node(.{ .name = "a-node-with-a-long-name" }));
}

// ...and this one covers word(): 2 bytes left after the header and memrsv block is
// not enough for even the first token, so it fails before raw() is ever called.
test "fdt: a buffer with no room for a single token errors in word" {
    var buf: [58]u8 = undefined; // 56 header+memrsv, 2 spare — short of one token
    var strs: [64]u8 = undefined;
    var w = Writer{ .buf = &buf, .strings = &strs };

    try testing.expectError(error.FdtBufferTooSmall, w.node(.{ .name = "" }));
}

// ---- serialize --------------------------------------------------------------

// The whole blob, byte for byte, and the only test that sees FDT_END — Writer.node
// stops at END_NODE, so the terminating token exists solely because serialize()
// writes it. A blob missing it makes the kernel walk off the end of the tree.
//
// NOTE the arithmetic: eight words is 32 bytes, so the struct block is [56, 88),
// not [56, 84) — 84 would be 32 expected bytes against a 28-byte slice, which the
// length check would reject.
test "fdt: a root node with one cell property serializes exactly" {
    var buf: [256]u8 = undefined;
    var strs: [64]u8 = undefined;
    const blob = try serialize(&buf, &strs, .{
        .name = "",
        .props = &.{.{ .name = "#address-cells", .value = .{ .u32 = 2 } }},
    });

    try testing.expectEqualSlices(u8, &.{
        0, 0, 0, 1, // FDT_BEGIN_NODE
        0, 0, 0, 0, // name "" + NUL, padded to 4
        0, 0, 0, 3, // FDT_PROP
        0, 0, 0, 4, // len = 4
        0, 0, 0, 0, // nameoff = 0
        0, 0, 0, 2, // value = <2>, BIG-endian
        0, 0, 0, 2, // FDT_END_NODE
        0, 0, 0, 9, // FDT_END  <- serialize's, not Writer's
    }, blob[56..88]);
    try testing.expectEqualStrings("#address-cells\x00", blob[88..103]);
    try testing.expectEqual(@as(usize, 103), blob.len); // 56 + 32 + 15
}

// THE one line byteSwapAllFields replaced a whole Be32 newtype for, and the one
// line that can be FORGOTTEN. Delete the byteSwapAllFields call in serialize() to
// negative-control this: it must go red.
//
// Raw bytes, not readInt — readInt(.big) would happily pass on a little-endian blob
// if the test and the code shared the same mistake. These are the bytes on disk.
test "fdt: the header is written big-endian" {
    var buf: [256]u8 = undefined;
    var strs: [64]u8 = undefined;
    const blob = try serialize(&buf, &strs, .{ .name = "" });

    try testing.expectEqualSlices(u8, &.{ 0xd0, 0x0d, 0xfe, 0xed }, blob[0..4]); // magic
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 17 }, blob[20..24]); // version
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 16 }, blob[24..28]); // last_comp_version
}

// Every offset in the header is derived, so a mistake in one silently shifts a
// block. Assert they agree with each other AND with the blob's real length — the
// header stores each offset and its size six fields apart, so they CAN disagree.
test "fdt: serialize's header offsets and sizes are self-consistent" {
    var buf: [256]u8 = undefined;
    var strs: [64]u8 = undefined;
    const blob = try serialize(&buf, &strs, .{
        .name = "",
        .props = &.{.{ .name = "compatible", .value = .{ .string = "x" } }},
    });

    var h = std.mem.bytesToValue(Header, blob[0..@sizeOf(Header)]);
    std.mem.byteSwapAllFields(Header, &h); // back to native to read it

    try testing.expectEqual(@as(u32, 40), h.off_mem_rsvmap);
    try testing.expectEqual(@as(u32, 56), h.off_dt_struct);
    try testing.expectEqual(h.off_dt_strings, h.off_dt_struct + h.size_dt_struct);
    try testing.expectEqual(h.totalsize, h.off_dt_strings + h.size_dt_strings);
    try testing.expectEqual(@as(usize, h.totalsize), blob.len);
}

// The strings block must land AFTER the struct block, at exactly off_dt_strings and
// for exactly size_dt_strings bytes. Reading it back THROUGH the header (rather than
// at a hardcoded offset) is the point: it proves the header's own pointer is what
// leads a reader to the names, which is all the kernel has to go on.
test "fdt: the strings block is appended where the header says it is" {
    var buf: [256]u8 = undefined;
    var strs: [64]u8 = undefined;
    const blob = try serialize(&buf, &strs, .{
        .name = "",
        .props = &.{
            .{ .name = "#address-cells", .value = .{ .u32 = 2 } },
            .{ .name = "#size-cells", .value = .{ .u32 = 2 } },
        },
    });

    var h = std.mem.bytesToValue(Header, blob[0..@sizeOf(Header)]);
    std.mem.byteSwapAllFields(Header, &h);

    try testing.expectEqualStrings(
        "#address-cells\x00#size-cells\x00",
        blob[h.off_dt_strings..][0..h.size_dt_strings],
    );
}

// The memrsv block is easy to forget entirely (we have no reservations) — but the
// TERMINATOR is not optional. An absent {0,0} means the kernel walks the struct
// block as reservation entries.
//
// This test only has teeth because Zig fills `undefined` with 0xAA in Debug: the
// real target is mmap'd guest RAM, which the OS already zero-fills, so a missing
// @memset would work in production and be invisible. Negative-control it by
// deleting the @memset in serialize().
test "fdt: the empty memory-reservation block still has its terminator" {
    var buf: [256]u8 = undefined;
    var strs: [64]u8 = undefined;
    const blob = try serialize(&buf, &strs, .{ .name = "" });

    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), blob[40..56]);
}

// Names repeat constantly; a dedupe bug is invisible (the tree still parses, just
// bigger) until the strings buffer overflows on a tree you didn't expect to grow.
// This is the intern test at the serialize layer: it pins that size_dt_strings is
// DERIVED from str_len rather than counted.
test "fdt: a repeated property name is interned once" {
    var buf: [256]u8 = undefined;
    var strs: [64]u8 = undefined;
    const blob = try serialize(&buf, &strs, .{
        .name = "",
        .props = &.{.{ .name = "reg", .value = .{ .u32 = 1 } }},
        .children = &.{.{ .name = "a", .props = &.{.{ .name = "reg", .value = .{ .u32 = 2 } }} }},
    });

    var h = std.mem.bytesToValue(Header, blob[0..@sizeOf(Header)]);
    std.mem.byteSwapAllFields(Header, &h);
    try testing.expectEqual(@as(u32, 4), h.size_dt_strings); // "reg\0" once, not twice
}

// serialize()'s OWN guard, distinct from Writer's two: a buffer that cannot even
// hold the header and the memrsv block must error before the @memset scribbles
// past the end of it.
test "fdt: serialize refuses a buffer too small for the header and memrsv" {
    var buf: [55]u8 = undefined; // one byte short of STRUCT_OFF
    var strs: [64]u8 = undefined;

    try testing.expectError(error.FdtBufferTooSmall, serialize(&buf, &strs, .{ .name = "" }));
}
