const std = @import("std");

/// The 64-byte header every arm64 kernel Image starts with, per the boot protocol
/// (Documentation/arch/arm64/booting.rst). All multi-byte fields are little-endian,
/// which matches field order on an LE host, so a @bitCast decodes it directly.
pub const ImageHeader = packed struct {
    code0: u32, // executable code (a branch, so the image is also directly bootable)
    code1: u32, // executable code
    text_offset: u64, // load offset from a 2 MiB-aligned base; 0 on modern kernels
    image_size: u64, // footprint once loaded, INCLUDING BSS — exceeds the file size.
    // 0 means "unknown" (pre-3.17 kernels): reserve the whole window instead.
    flags: u64, // bit 0 endianness (0=LE) · bits 1:2 guest page size · bit 3 anywhere-2MiB
    res2: u64,
    res3: u64,
    res4: u64,
    magic: u32, // "ARM\x64" — identifies the file as an arm64 Image
    res5: u32, // reserved; holds the PE/COFF header offset on EFI-stub kernels

    const MAGIC: u32 = 0x644d_5241; // 41=A, 52=R, 4d=M in ascii

    pub fn fromBits(v: [64]u8) ImageHeader {
        return @bitCast(v);
    }

    pub fn parse(hdr: [64]u8) !ImageHeader {
        const h: ImageHeader = fromBits(hdr);
        if (h.magic != MAGIC) {
            return error.BadImageMagic;
        }
        return h;
    }
};
comptime {
    std.debug.assert(@bitSizeOf(ImageHeader) == 64 * 8);
    std.debug.assert(@bitOffsetOf(ImageHeader, "text_offset") == 8 * 8);
    std.debug.assert(@bitOffsetOf(ImageHeader, "image_size") == 16 * 8);
    std.debug.assert(@bitOffsetOf(ImageHeader, "magic") == 56 * 8);
}

const testing = std.testing;

test "parse: decodes fields from the raw 64-byte header layout" {
    var raw: [64]u8 = @splat(0);
    raw[56] = 0x41; // "ARM\x64" magic at offset 0x38, little-endian
    raw[57] = 0x52;
    raw[58] = 0x4d;
    raw[59] = 0x64;
    std.mem.writeInt(u64, raw[8..16], 0, .little); // text_offset
    std.mem.writeInt(u64, raw[16..24], 0x2c70000, .little); // image_size
    std.mem.writeInt(u64, raw[24..32], 0xa, .little); // flags (LE, 4K pages, anywhere)

    const h = try ImageHeader.parse(raw);
    try testing.expectEqual(ImageHeader.MAGIC, h.magic);
    try testing.expectEqual(@as(u64, 0), h.text_offset);
    try testing.expectEqual(@as(u64, 0x2c70000), h.image_size);
    try testing.expectEqual(@as(u64, 0xa), h.flags);
}

test "parse: rejects a header with the wrong magic" {
    const raw: [64]u8 = @splat(0); // magic bytes left zero
    try testing.expectError(error.BadImageMagic, ImageHeader.parse(raw));
}

test "parse: struct round-trips through fromBits" {
    const orig = ImageHeader{
        .code0 = 0x1234,
        .code1 = 0,
        .text_offset = 0,
        .image_size = 0xdead000,
        .flags = 0xa,
        .res2 = 0,
        .res3 = 0,
        .res4 = 0,
        .magic = ImageHeader.MAGIC,
        .res5 = 0,
    };
    const back = try ImageHeader.parse(@bitCast(orig));
    try testing.expectEqual(orig.image_size, back.image_size);
    try testing.expectEqual(orig.code0, back.code0);
}
