const std = @import("std");
const bzimage = @import("bzimage.zig");

// Builds Linux's `boot_params` — the 4 KiB "zero page" the kernel reads at
// startup_64 via RSI (Documentation/arch/x86/boot.rst). It is the guest's entire
// picture of its environment at entry: memory map, command line, loader identity.
// The x86 counterpart of arm64's device tree, but a FIXED struct with hardcoded
// byte offsets rather than a self-describing tree, so the job is to zero a page
// and write the right bytes at the right offsets. Every field left untouched
// stays zero, which is the correct "unused" value. Pure over the caller's `ram`
// slice, with no I/O.

/// Guest-physical address.
const Gpa = u64;

/// setup_data node types (arch/x86/include/uapi/asm/setup_data.h). Only the one
/// this module emits is named.
const SETUP_RNG_SEED: u32 = 9;
/// `struct setup_data`'s fixed part: next (u64) + type (u32) + len (u32).
const SETUP_DATA_HEADER = 16;

pub const E820Type = enum(u32) { usable = 1, reserved = 2 };

// A boot_e820_entry: exactly 20 bytes, no padding. An `extern struct` would pad
// to 24 (8-byte alignment for the trailing u32), so a packed backing integer
// pins the width.
pub const E820Entry = packed struct(u160) {
    addr: u64,
    size: u64,
    type: u32,

    pub fn toBytes(self: E820Entry) [20]u8 {
        return @bitCast(self);
    }
};

pub const Params = struct {
    header: bzimage.SetupHeader, // the image's parsed header; copied then patched
    cmdline: []const u8, //        NOT NUL-terminated; build appends the terminator
    e820: []const E820Entry, //    usable-RAM map (see defaultE820)
    // GPAs are direct offsets into `ram`: it is guest RAM mapped from GPA 0, so
    // ram[0] IS guest-physical 0 and gpa == offset.
    zero_page_gpa: Gpa, //         where the 4 KiB page goes
    cmdline_gpa: Gpa, //           where the cmdline string goes (must be < 4 GiB)
    // Optional initramfs. ramdisk_size == 0 means "no initrd": the header's
    // ramdisk_image/size stay 0 and the kernel mounts no RAM rootfs. The x86
    // counterpart of the DTB's linux,initrd-start/end.
    ramdisk_gpa: Gpa = 0, //       where the initramfs was loaded (must be < 4 GiB)
    ramdisk_size: usize = 0, //    its length in bytes (0 = none)
    // Physical address of the ACPI RSDP. 0 = none: the field stays 0 and the
    // kernel falls back to its legacy BIOS-area scan. The modern boot-protocol
    // counterpart of the DTB describing the interrupt controller.
    acpi_rsdp_gpa: Gpa = 0,
    // Where a SETUP_RNG_SEED node goes, and what it says. 0 = emit nothing.
    //
    // The kernel credits a bootloader-supplied seed as initialisation entropy
    // (add_bootloader_randomness; `random.trust_bootloader` defaults on), which is
    // the supported way for a loader to say "here is your randomness". A guest
    // given none, and with no CPU RNG of its own, instead harvests timing jitter.
    // The seed is not a secret and is not meant to be.
    setup_data_gpa: Gpa = 0,
    rng_seed: []const u8 = &.{},
};

const ZERO_PAGE_SIZE: usize = 0x1000;
const E820_MAX: usize = 128; // E820_MAX_ENTRIES_ZEROPAGE
const TYPE_OF_LOADER_UNDEFINED: u8 = 0xFF;

// The whole 4 KiB boot_params, modelled the way SetupHeader models its file: the
// written fields are named, everything else is a sized reserved gap, so the exact
// byte offsets fall out of the layout and a bitcast to [0x1000]u8 is the page.
// Offsets in comments are absolute boot_params offsets
// (arch/x86/include/uapi/asm/bootparam.h). All fields little-endian, matching an
// x86 host, so the bitcast decodes them directly.
//
// The e820 table is one wide field, not a typed array: Zig packed structs cannot
// contain arrays (the same reason SetupHeader's gaps are ints). build() packs the
// entries into a byte buffer and @bitCasts it into this field, so the struct
// layout — not a manual offset — still places the table at 0x2d0.
pub const BootParams = packed struct {
    _pad0a: u896 = 0, //   0x000  screen_info, apm, ist, ... (through 0x06f)
    acpi_rsdp_addr: u64 = 0, // 0x070  physical address of the ACPI RSDP (boot protocol 2.14+)
    _pad0b: u2944 = 0, //  0x078  hd*, sys_desc, olpc, edid, efi_info, ... (through 0x1e7)
    e820_entries: u8 = 0, // 0x1e8  number of valid e820_table entries
    _pad1: u64 = 0, //     0x1e9  eddbuf_entries..secure_boot..sentinel(0x1ef)..pad
    hdr: bzimage.SetupHeader, // 0x1f1  the setup_header, copied then patched
    _pad2: u864 = 0, //    0x264  header tail + edd_mbr_sig_buffer (through 0x2cf)
    e820_table: u20480 = 0, // 0x2d0  boot_e820_entry[128], packed little-endian
    _pad3: u6528 = 0, //   0xcd0  eddbuf + trailing pad (through 0xfff)

    pub fn toBytes(self: BootParams) [ZERO_PAGE_SIZE]u8 {
        return @bitCast(self);
    }
};

// Writes the zero page (at zero_page_gpa) AND the NUL-terminated cmdline string
// (at cmdline_gpa) into `ram`, indexing it directly by GPA. Every field the struct
// does not name — including `sentinel` (0x1ef) — stays zero, so the kernel's
// sanitize_boot_params() trusts the page.
pub fn build(ram: []u8, p: Params) !void {
    if (p.e820.len > E820_MAX) return error.TooManyE820;
    if (p.cmdline_gpa > 0xFFFF_FFFF) return error.CmdlineTooHigh; // cmd_line_ptr is u32
    // ramdisk_image/size are u32, so an initrd must sit below 4 GiB, and the
    // ext_ramdisk_* high halves stay 0). Range-check before the header patch.
    if (p.ramdisk_size != 0) {
        if (p.ramdisk_gpa > 0xFFFF_FFFF) return error.RamdiskTooHigh;
        if (p.ramdisk_size > 0xFFFF_FFFF) return error.RamdiskTooLong;
        if (p.ramdisk_gpa + p.ramdisk_size > ram.len) return error.RamdiskOutOfRange;
    }
    // cmdline_size == 0 on ancient protocols; then the 2.02+ default is 255.
    const max_cmdline: usize = if (p.header.cmdline_size != 0) p.header.cmdline_size else 255;
    if (p.cmdline.len + 1 > max_cmdline) return error.CmdlineTooLong;

    // gpa == offset (RAM is mapped from GPA 0). Range-check before the cast so the
    // @intCast can't truncate a wild GPA.
    if (p.zero_page_gpa > ram.len) return error.ZeroPageOutOfRange;
    const zp_off: usize = @intCast(p.zero_page_gpa);
    if (zp_off + ZERO_PAGE_SIZE > ram.len) return error.ZeroPageOutOfRange;
    if (p.cmdline_gpa > ram.len) return error.CmdlineOutOfRange;
    const cl_off: usize = @intCast(p.cmdline_gpa);
    if (cl_off + p.cmdline.len + 1 > ram.len) return error.CmdlineOutOfRange;

    // The setup_data chain, written before the zero page so its address is known.
    // One node, no `next`.
    var setup_data_addr: u64 = 0;
    if (p.rng_seed.len != 0 and p.setup_data_gpa != 0) {
        if (p.setup_data_gpa > ram.len) return error.SetupDataOutOfRange;
        const sd_off: usize = @intCast(p.setup_data_gpa);
        const total = SETUP_DATA_HEADER + p.rng_seed.len;
        if (sd_off + total > ram.len) return error.SetupDataOutOfRange;
        // struct setup_data { u64 next; u32 type; u32 len; u8 data[]; }
        std.mem.writeInt(u64, ram[sd_off..][0..8], 0, .little); // next: end of chain
        std.mem.writeInt(u32, ram[sd_off + 8 ..][0..4], SETUP_RNG_SEED, .little);
        std.mem.writeInt(u32, ram[sd_off + 12 ..][0..4], @intCast(p.rng_seed.len), .little);
        @memcpy(ram[sd_off + SETUP_DATA_HEADER ..][0..p.rng_seed.len], p.rng_seed);
        setup_data_addr = p.setup_data_gpa;
    }

    // Build the page as a typed value; unnamed fields keep their zero defaults.
    var hdr = p.header;
    hdr.type_of_loader = TYPE_OF_LOADER_UNDEFINED;
    hdr.setup_data = setup_data_addr;
    hdr.loadflags.loaded_high = true; // OR-in: other bits (kaslr, ...) preserved
    hdr.loadflags.can_use_heap = true;
    hdr.cmd_line_ptr = @intCast(p.cmdline_gpa);
    if (p.ramdisk_size != 0) {
        hdr.ramdisk_image = @intCast(p.ramdisk_gpa);
        hdr.ramdisk_size = @intCast(p.ramdisk_size);
    }

    // Pack the e820 entries into the table field (packed structs forbid arrays,
    // so the field is one wide int the bytes bitcast into).
    var table: [E820_MAX * 20]u8 = @splat(0);
    for (p.e820, 0..) |e, i| {
        const b = e.toBytes();
        @memcpy(table[i * 20 ..][0..20], &b);
    }

    const bp: BootParams = .{
        .acpi_rsdp_addr = p.acpi_rsdp_gpa, // 0 ⇒ kernel falls back to the BIOS scan
        .e820_entries = @intCast(p.e820.len),
        .hdr = hdr,
        .e820_table = @bitCast(table),
    };
    const bytes = bp.toBytes();
    @memcpy(ram[zp_off..][0..ZERO_PAGE_SIZE], &bytes);

    // Command line string, NUL-terminated, at its own GPA.
    @memcpy(ram[cl_off..][0..p.cmdline.len], p.cmdline);
    ram[cl_off + p.cmdline.len] = 0;
}

// The standard PC memory map for a contiguous [0, ram_size) region: usable
// conventional RAM below 640 KiB, usable extended RAM from 1 MiB.
// The 0xa0000..0x100000 legacy hole (video RAM, option ROMs, BIOS) is left out —
// reserved by omission — so the kernel never allocates into unbacked GPAs.
// Requires ram_size > 0x100000, asserted below.
pub fn defaultE820(buf: *[2]E820Entry, ram_size: u64) []E820Entry {
    std.debug.assert(ram_size > 0x100000);
    buf[0] = .{ .addr = 0x0, .size = 0xa0000, .type = @intFromEnum(E820Type.usable) };
    buf[1] = .{ .addr = 0x100000, .size = ram_size - 0x100000, .type = @intFromEnum(E820Type.usable) };
    return buf[0..2];
}

comptime {
    // 20 bytes, no padding — the e820_table stride and E820Entry bitcast need this.
    std.debug.assert(@bitSizeOf(E820Entry) == 160);
    // BootParams is exactly one page, and every named field lands at its real
    // boot_params offset — a miscounted reserved gap fails the build here instead
    // of silently shifting the header or the e820 table.
    std.debug.assert(@bitSizeOf(BootParams) == ZERO_PAGE_SIZE * 8);
    std.debug.assert(@bitOffsetOf(BootParams, "acpi_rsdp_addr") == 0x070 * 8);
    std.debug.assert(@bitOffsetOf(BootParams, "e820_entries") == 0x1e8 * 8);
    std.debug.assert(@bitOffsetOf(BootParams, "hdr") == 0x1f1 * 8);
    std.debug.assert(@bitOffsetOf(BootParams, "e820_table") == 0x2d0 * 8);
    // Cross-check: hdr begins where SetupHeader claims its file offset is.
    std.debug.assert(@bitOffsetOf(BootParams, "hdr") == bzimage.SetupHeader.OFFSET * 8);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

// Fake guest RAM based at GPA 0 (gpa == offset), big enough for the placements.
const ZP_GPA: Gpa = 0x7000;
const CL_GPA: Gpa = 0x20000;

fn fakeHeader() bzimage.SetupHeader {
    var img: [0x2000]u8 = undefined;
    _ = fakeImage(&img, 1);
    return (bzimage.parse(&img) catch unreachable).header;
}

// A minimal valid bzImage header (mirrors bzimage.zig's private fakeImage, plus
// cmdline_size so the cmdline-length guard has a real bound to check).
fn fakeImage(buf: []u8, setup_sects: u8) usize {
    @memset(buf, 0);
    buf[bzimage.SetupHeader.OFFSET] = setup_sects;
    std.mem.writeInt(u16, buf[0x1fe..][0..2], bzimage.BOOT_FLAG, .little);
    std.mem.writeInt(u32, buf[0x202..][0..4], bzimage.HDRS_MAGIC, .little);
    std.mem.writeInt(u16, buf[0x206..][0..2], 0x020f, .little); // version
    buf[0x211] = (bzimage.LoadFlags{ .loaded_high = true }).toBits(); // a real kernel already sets this
    std.mem.writeInt(u16, buf[0x236..][0..2], bzimage.XLF_KERNEL_64, .little);
    std.mem.writeInt(u32, buf[0x238..][0..4], 4096, .little); // cmdline_size
    std.mem.writeInt(u64, buf[0x258..][0..8], 0x0100_0000, .little); // pref_address
    std.mem.writeInt(u32, buf[0x260..][0..4], 0x0080_0000, .little); // init_size
    const sects: usize = if (setup_sects == 0) 4 else setup_sects;
    return (sects + 1) * 512;
}

fn buildInto(ram: []u8, cmdline: []const u8, e820: []const E820Entry) !void {
    try build(ram, .{
        .header = fakeHeader(),
        .cmdline = cmdline,
        .e820 = e820,
        .zero_page_gpa = ZP_GPA,
        .cmdline_gpa = CL_GPA,
    });
}

test "build: header copy, type_of_loader, and loadflags land at their offsets" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    try buildInto(ram, "console=ttyS0", defaultE820(&e, 512 * 1024 * 1024));

    const page = ram[ZP_GPA..][0..0x1000];
    // The setup header was copied verbatim at 0x1f1: HdrS magic and boot_flag.
    try testing.expectEqual(bzimage.BOOT_FLAG, std.mem.readInt(u16, page[0x1fe..][0..2], .little));
    try testing.expectEqual(bzimage.HDRS_MAGIC, std.mem.readInt(u32, page[0x202..][0..4], .little));
    // Patched fields.
    try testing.expectEqual(TYPE_OF_LOADER_UNDEFINED, page[0x210]);
    const lf = bzimage.LoadFlags.fromBits(page[0x211]);
    try testing.expect(lf.loaded_high);
    try testing.expect(lf.can_use_heap);
}

test "build: cmd_line_ptr points at the cmdline, which is present and NUL-terminated" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    const cmdline = "earlyprintk=serial,ttyS0,115200 console=ttyS0,115200 keep_bootcon";
    try buildInto(ram, cmdline, defaultE820(&e, 512 * 1024 * 1024));

    const page = ram[ZP_GPA..][0..0x1000];
    const ptr = std.mem.readInt(u32, page[0x228..][0..4], .little);
    try testing.expectEqual(@as(u32, CL_GPA), ptr);

    // Follow the pointer (GPA == offset in this test) and read the string back.
    const at = ram[ptr..];
    try testing.expectEqualStrings(cmdline, at[0..cmdline.len]);
    try testing.expectEqual(@as(u8, 0), at[cmdline.len]); // NUL terminator
}

test "build: e820 count and entries land at 0x1e8 / 0x2d0" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    try buildInto(ram, "x", defaultE820(&e, 512 * 1024 * 1024));

    const page = ram[ZP_GPA..][0..0x1000];
    try testing.expectEqual(@as(u8, 2), page[0x1e8]);

    // Entry 0: [0, 0xa0000) usable.
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, page[0x2d0..][0..8], .little));
    try testing.expectEqual(@as(u64, 0xa0000), std.mem.readInt(u64, page[0x2d8..][0..8], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, page[0x2e0..][0..4], .little));
    // Entry 1 begins 20 bytes later: base 0x100000.
    try testing.expectEqual(@as(u64, 0x100000), std.mem.readInt(u64, page[0x2d0 + 20 ..][0..8], .little));
}

test "build: ramdisk_image/size land at 0x218/0x21c when an initrd is given" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    try build(ram, .{
        .header = fakeHeader(),
        .cmdline = "x",
        .e820 = defaultE820(&e, 512 * 1024 * 1024),
        .zero_page_gpa = ZP_GPA,
        .cmdline_gpa = CL_GPA,
        .ramdisk_gpa = 0x28000, // within the 0x30000 test RAM
        .ramdisk_size = 0x1000,
    });

    const page = ram[ZP_GPA..][0..0x1000];
    try testing.expectEqual(@as(u32, 0x28000), std.mem.readInt(u32, page[0x218..][0..4], .little));
    try testing.expectEqual(@as(u32, 0x1000), std.mem.readInt(u32, page[0x21c..][0..4], .little));
}

test "build: no initrd leaves ramdisk_image/size zero" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    try buildInto(ram, "x", defaultE820(&e, 512 * 1024 * 1024)); // ramdisk_* default to 0

    const page = ram[ZP_GPA..][0..0x1000];
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, page[0x218..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, page[0x21c..][0..4], .little));
}

test "build: rejects an initrd above 4 GiB or running past RAM" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    const e820 = defaultE820(&e, 512 * 1024 * 1024);

    // ramdisk_image is a u32: a load GPA above 4 GiB cannot be represented.
    try testing.expectError(error.RamdiskTooHigh, build(ram, .{
        .header = fakeHeader(),
        .cmdline = "x",
        .e820 = e820,
        .zero_page_gpa = ZP_GPA,
        .cmdline_gpa = CL_GPA,
        .ramdisk_gpa = 0x1_0000_0000,
        .ramdisk_size = 16,
    }));

    // An initrd extent that runs off the end of guest RAM.
    try testing.expectError(error.RamdiskOutOfRange, build(ram, .{
        .header = fakeHeader(),
        .cmdline = "x",
        .e820 = e820,
        .zero_page_gpa = ZP_GPA,
        .cmdline_gpa = CL_GPA,
        .ramdisk_gpa = ram.len - 8,
        .ramdisk_size = 16,
    }));
}

test "build: acpi_rsdp_addr lands at 0x070 when given, stays zero otherwise" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    try build(ram, .{
        .header = fakeHeader(),
        .cmdline = "x",
        .e820 = defaultE820(&e, 512 * 1024 * 1024),
        .zero_page_gpa = ZP_GPA,
        .cmdline_gpa = CL_GPA,
        .acpi_rsdp_gpa = 0xF_0000,
    });
    const page = ram[ZP_GPA..][0..0x1000];
    try testing.expectEqual(@as(u64, 0xF_0000), std.mem.readInt(u64, page[0x070..][0..8], .little));

    // Default (no RSDP) leaves the field zero.
    @memset(ram, 0);
    try buildInto(ram, "x", defaultE820(&e, 512 * 1024 * 1024));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, page[0x070..][0..8], .little));
}

test "build: the rest of the page is zero (sentinel included)" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    try buildInto(ram, "x", defaultE820(&e, 512 * 1024 * 1024));

    const page = ram[ZP_GPA..][0..0x1000];
    try testing.expectEqual(@as(u8, 0), page[0x1ef]); // sentinel
    // A byte in an untouched gap (before the header) stays zero.
    try testing.expectEqual(@as(u8, 0), page[0x100]);
}

test "build: rejects an over-long cmdline, too many e820 entries, and a high cmdline GPA" {
    const ram = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(ram);
    var e: [2]E820Entry = undefined;
    const e820 = defaultE820(&e, 512 * 1024 * 1024);

    // cmdline_size in fakeHeader is 4096, so 4096 chars + NUL overflows it.
    const long: [4096]u8 = @splat('A');
    try testing.expectError(error.CmdlineTooLong, buildInto(ram, &long, e820));

    // > 128 e820 entries.
    var many: [E820_MAX + 1]E820Entry = undefined;
    for (&many) |*x| x.* = .{ .addr = 0, .size = 0, .type = 1 };
    try testing.expectError(error.TooManyE820, buildInto(ram, "x", &many));

    // cmd_line_ptr is a u32: a GPA above 4 GiB cannot be represented.
    try testing.expectError(error.CmdlineTooHigh, build(ram, .{
        .header = fakeHeader(),
        .cmdline = "x",
        .e820 = e820,
        .zero_page_gpa = ZP_GPA,
        .cmdline_gpa = 0x1_0000_0000,
    }));
}
