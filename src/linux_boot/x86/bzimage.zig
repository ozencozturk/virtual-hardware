const std = @import("std");

// Parses a Linux x86 bzImage: the `struct setup_header` at file offset 0x1f1
// (Documentation/arch/x86/boot.rst), and the protected-mode kernel that follows
// the real-mode setup. Only the fields a loader reads or writes are named; the
// rest are reserved padding, so every field lands at its real byte offset when
// the raw bytes are @bitCast. All fields are little-endian, matching an x86 host,
// so the cast decodes them directly. Offsets in comments are the ABSOLUTE file
// offset (struct base 0x1f1 + the field's position).

/// setup_header.loadflags (offset 0x211): a bitfield the loader both reads and
/// sets. Bits per Documentation/arch/x86/boot.rst.
pub const LoadFlags = packed struct(u8) {
    loaded_high: bool = false, //   0  protected-mode kernel at 0x100000 (0 = 0x10000)
    kaslr: bool = false, //         1  KASLR_FLAG (kernel-set; loader may clear to disable)
    _r0: u3 = 0, //                 2..4  reserved
    quiet: bool = false, //         5  QUIET_FLAG (suppress early printk)
    keep_segments: bool = false, // 6  KEEP_SEGMENTS (don't reload segment regs)
    can_use_heap: bool = false, //  7  CAN_USE_HEAP (heap_end_ptr is valid)

    pub fn fromBits(v: u8) LoadFlags {
        return @bitCast(v);
    }
    pub fn toBits(self: LoadFlags) u8 {
        return @bitCast(self);
    }
};

/// setup_header.xloadflags (offset 0x236): the 64-bit/EFI capability word the
/// kernel publishes about itself — read-only from a loader's point of view,
/// unlike loadflags. Bits per Documentation/arch/x86/boot.rst.
pub const XLoadFlags = packed struct(u16) {
    kernel_64: bool = false, //         0  64-bit entrypoint at +0x200 (XLF_KERNEL_64)
    can_be_loaded_above_4g: bool = false, // 1  kernel/initrd may sit above 4 GiB
    efi_handover_32: bool = false, //    2  32-bit EFI handover protocol
    efi_handover_64: bool = false, //    3  64-bit EFI handover protocol
    efi_kexec: bool = false, //          4  kexec EFI boot with runtime support
    level5: bool = false, //             5  supports 5-level paging
    level5_enabled: bool = false, //     6  5-level paging enabled in this build
    mem_encryption: bool = false, //     7  supports memory encryption (SME/SEV)
    _r0: u8 = 0, //                      8..15  reserved

    pub fn fromBits(v: u16) XLoadFlags {
        return @bitCast(v);
    }
    pub fn toBits(self: XLoadFlags) u16 {
        return @bitCast(self);
    }
};

pub const SetupHeader = packed struct {
    setup_sects: u8, //         0x1f1  # of setup sectors after the boot sector (0 means 4);
    //                                 real-mode size = (setup_sects + 1) * 512
    _r0: u96, //                0x1f2  root_flags, syssize, ram_size, vid_mode, root_dev
    boot_flag: u16, //          0x1fe  must be 0xAA55
    _r1: u16, //                0x200  jump
    header: u32, //             0x202  must be "HdrS"
    version: u16, //            0x206  boot-protocol version
    _r2: u64, //                0x208  realmode_swtch, start_sys_seg, kernel_version
    type_of_loader: u8, //      0x210  loader identity; 0xFF = undefined/unregistered
    loadflags: LoadFlags, //    0x211  LOADED_HIGH / CAN_USE_HEAP
    _r3: u16, //                0x212  setup_move_size
    code32_start: u32, //       0x214  load-addr hint
    ramdisk_image: u32, //      0x218  initrd load address (low 32 bits; loader-set)
    ramdisk_size: u32, //       0x21c  initrd length in bytes (low 32 bits; loader-set)
    _r4: u64, //                0x220  bootsect_kludge, heap_end_ptr, ext_loader_ver/type
    cmd_line_ptr: u32, //       0x228  command-line address (loader-set)
    _r5: u32, //                0x22c  initrd_addr_max
    kernel_alignment: u32, //   0x230
    relocatable_kernel: u8, //  0x234
    _r6: u8, //                 0x235  min_alignment
    xloadflags: XLoadFlags, //  0x236  kernel-published capabilities
    cmdline_size: u32, //       0x238  max cmdline length
    _r7a: u32, //               0x23c  hardware_subarch
    _r7b: u64, //               0x240  hardware_subarch_data
    _r7c: u32, //               0x248  payload_offset
    _r7d: u32, //               0x24c  payload_length
    /// Head of the setup_data chain, or 0 for none. A loader hangs typed nodes
    /// here to hand the kernel things the header has no field for, an RNG seed
    /// among them.
    setup_data: u64, //         0x250
    pref_address: u64, //       0x258  preferred load addr
    init_size: u32, //          0x260  contiguous RAM the kernel needs at load addr

    pub const OFFSET = 0x1f1; // file offset where setup_header begins
    /// Byte length of the header, derived from the layout above. @bitSizeOf, not
    /// @sizeOf: this is a packed struct, whose ABI size may round up past the true
    /// bit length.
    pub const SIZE = @bitSizeOf(SetupHeader) / 8;

    pub fn fromBits(v: [SIZE]u8) SetupHeader {
        return @bitCast(v);
    }
};

pub const HDRS_MAGIC: u32 = 0x53726448; // "HdrS" little-endian
pub const BOOT_FLAG: u16 = 0xAA55;

/// Where the 64-bit entrypoint sits relative to the start of the protected-mode
/// kernel (Documentation/arch/x86/boot.rst — the entry XLF_KERNEL_64 advertises).
/// NOT to be confused with the unrelated 0x200 that is the *file* offset of the
/// header's `jump` field; these are equal by coincidence, not by definition.
pub const ENTRY64_OFFSET = 0x200;

/// The bit pattern of an xloadflags carrying XLF_KERNEL_64 alone, for callers that
/// plant a raw header into a byte buffer.
pub const XLF_KERNEL_64: u16 = (XLoadFlags{ .kernel_64 = true }).toBits();

pub const Kernel = struct {
    header: SetupHeader,
    protected_mode: []const u8,
};

/// Sanity floor for a plausible bzImage, and the bound that keeps `parse`'s header
/// read in-bounds; the comptime block asserts it covers the header.
pub const MIN_IMAGE_LEN = 0x1000;

pub fn parse(image: []const u8) !Kernel {
    if (image.len < MIN_IMAGE_LEN) {
        return error.ShortImage;
    }
    const hdr = SetupHeader.fromBits(image[SetupHeader.OFFSET..][0..SetupHeader.SIZE].*);
    if (hdr.boot_flag != BOOT_FLAG) {
        return error.BadBootFlag;
    }
    if (hdr.header != HDRS_MAGIC) {
        return error.BadSetupMagic;
    }
    if (!hdr.xloadflags.kernel_64) return error.No64BitEntry;

    const sects = if (hdr.setup_sects == 0) 4 else hdr.setup_sects;
    const rm_size = (@as(usize, sects) + 1) * 512;

    if (rm_size > image.len) return error.TruncatedSetup;
    return .{ .header = hdr, .protected_mode = image[rm_size..] };
}

comptime {
    // The header occupies exactly the spec's 0x1f1..0x264 extent, in whole bytes,
    // and each load-bearing field sits at its real file offset — a miscounted
    // reserved field fails the build here instead of silently misreading a kernel.
    std.debug.assert(@bitSizeOf(SetupHeader) % 8 == 0);
    std.debug.assert(SetupHeader.SIZE == 0x264 - SetupHeader.OFFSET); // 115 bytes, through init_size
    // parse()'s only length check is MIN_IMAGE_LEN, so it must cover the whole
    // header slice — otherwise a change to OFFSET/SIZE would make that read run
    // past a just-large-enough image.
    std.debug.assert(MIN_IMAGE_LEN >= SetupHeader.OFFSET + SetupHeader.SIZE);
    const off = struct {
        fn of(comptime name: []const u8, comptime file_off: usize) void {
            std.debug.assert(@bitOffsetOf(SetupHeader, name) == (file_off - SetupHeader.OFFSET) * 8);
        }
    };
    off.of("setup_sects", 0x1f1);
    off.of("boot_flag", 0x1fe);
    off.of("header", 0x202);
    off.of("version", 0x206);
    off.of("type_of_loader", 0x210);
    off.of("loadflags", 0x211);
    off.of("code32_start", 0x214);
    off.of("ramdisk_image", 0x218);
    off.of("ramdisk_size", 0x21c);
    off.of("cmd_line_ptr", 0x228);
    off.of("kernel_alignment", 0x230);
    off.of("xloadflags", 0x236);
    off.of("pref_address", 0x258);
    off.of("init_size", 0x260);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

// Build a minimal valid bzImage into `buf`: a well-formed setup header at 0x1f1
// for the given `setup_sects`, plus a recognizable byte pattern filling the
// protected-mode part. Returns the real-mode size (where the PM kernel begins) so
// a test can check the strip boundary. `buf` must be larger than that size.
fn fakeImage(buf: []u8, setup_sects: u8) usize {
    @memset(buf, 0);
    buf[SetupHeader.OFFSET] = setup_sects;
    std.mem.writeInt(u16, buf[0x1fe..][0..2], BOOT_FLAG, .little);
    std.mem.writeInt(u32, buf[0x202..][0..4], HDRS_MAGIC, .little);
    std.mem.writeInt(u16, buf[0x206..][0..2], 0x020f, .little); // version
    std.mem.writeInt(u16, buf[0x236..][0..2], XLF_KERNEL_64, .little); // xloadflags
    std.mem.writeInt(u64, buf[0x258..][0..8], 0x0100_0000, .little); // pref_address
    std.mem.writeInt(u32, buf[0x260..][0..4], 0x0080_0000, .little); // init_size
    const sects: usize = if (setup_sects == 0) 4 else setup_sects;
    const rm = (sects + 1) * 512;
    for (buf[rm..], 0..) |*b, i| b.* = @truncate(i +% 0xC0); // PM pattern
    return rm;
}

// The two flag words are decoded from (and, for loadflags, written back into) a
// real kernel's header, where a one-bit drift would silently misread the kernel's
// capabilities or mis-set the loader's and no build error would catch it. Shift
// expressions pin the positions.
test "LoadFlags / XLoadFlags: bit positions and round-trip" {
    try testing.expectEqual(@as(u8, 1 << 0), (LoadFlags{ .loaded_high = true }).toBits());
    try testing.expectEqual(@as(u8, 1 << 1), (LoadFlags{ .kaslr = true }).toBits());
    try testing.expectEqual(@as(u8, 1 << 5), (LoadFlags{ .quiet = true }).toBits());
    try testing.expectEqual(@as(u8, 1 << 7), (LoadFlags{ .can_use_heap = true }).toBits());
    // The pair boot_params.build sets on the way in.
    const lf = LoadFlags{ .loaded_high = true, .can_use_heap = true };
    try testing.expectEqual(@as(u8, (1 << 0) | (1 << 7)), lf.toBits());
    try testing.expectEqual(lf, LoadFlags.fromBits(lf.toBits()));

    try testing.expectEqual(@as(u16, 1 << 0), (XLoadFlags{ .kernel_64 = true }).toBits());
    try testing.expectEqual(@as(u16, 1 << 1), (XLoadFlags{ .can_be_loaded_above_4g = true }).toBits());
    try testing.expectEqual(@as(u16, 1 << 3), (XLoadFlags{ .efi_handover_64 = true }).toBits());
    try testing.expectEqual(@as(u16, 1 << 5), (XLoadFlags{ .level5 = true }).toBits());
    try testing.expectEqual(@as(u16, 1 << 7), (XLoadFlags{ .mem_encryption = true }).toBits());
    // XLF_KERNEL_64 is bit 0 — the one a 64-bit entry is gated on.
    try testing.expectEqual(@as(u16, 1 << 0), XLF_KERNEL_64);
    // A real kernel sets several at once; kernel_64 must still decode independently.
    const xf = XLoadFlags.fromBits((1 << 0) | (1 << 1) | (1 << 3));
    try testing.expect(xf.kernel_64 and xf.can_be_loaded_above_4g and xf.efi_handover_64);
    try testing.expect(!xf.efi_handover_32 and !xf.mem_encryption);
}

test "parse: decodes header fields and returns the protected-mode kernel" {
    var buf: [0x2000]u8 = undefined;
    const rm = fakeImage(&buf, 1); // setup_sects=1 → rm = (1+1)*512 = 1024
    const k = try parse(&buf);

    try testing.expectEqual(@as(u8, 1), k.header.setup_sects);
    try testing.expectEqual(BOOT_FLAG, k.header.boot_flag);
    try testing.expectEqual(HDRS_MAGIC, k.header.header);
    try testing.expectEqual(@as(u16, 0x020f), k.header.version);
    try testing.expectEqual(@as(u64, 0x0100_0000), k.header.pref_address);
    try testing.expectEqual(@as(u32, 0x0080_0000), k.header.init_size);

    // protected_mode is exactly the tail after the real-mode part.
    try testing.expectEqual(buf.len - rm, k.protected_mode.len);
    try testing.expectEqual(buf[rm], k.protected_mode[0]); // strip boundary is correct
    try testing.expectEqual(@as(u8, 0xC0), k.protected_mode[0]); // (the pattern's first byte)
}

test "parse: setup_sects == 0 is treated as 4 sectors (real-mode size 0xA00)" {
    var buf: [0x2000]u8 = undefined;
    const rm = fakeImage(&buf, 0);
    try testing.expectEqual(@as(usize, 5 * 512), rm); // (4+1)*512
    const k = try parse(&buf);
    try testing.expectEqual(buf.len - 0xA00, k.protected_mode.len);
}

test "parse: rejects a bad boot flag" {
    var buf: [0x2000]u8 = undefined;
    _ = fakeImage(&buf, 1);
    std.mem.writeInt(u16, buf[0x1fe..][0..2], 0x1234, .little);
    try testing.expectError(error.BadBootFlag, parse(&buf));
}

test "parse: rejects a bad setup magic" {
    var buf: [0x2000]u8 = undefined;
    _ = fakeImage(&buf, 1);
    std.mem.writeInt(u32, buf[0x202..][0..4], 0xdead_beef, .little);
    try testing.expectError(error.BadSetupMagic, parse(&buf));
}

test "parse: rejects a kernel without a 64-bit entry (XLF_KERNEL_64 clear)" {
    var buf: [0x2000]u8 = undefined;
    _ = fakeImage(&buf, 1);
    std.mem.writeInt(u16, buf[0x236..][0..2], 0, .little); // clear xloadflags
    try testing.expectError(error.No64BitEntry, parse(&buf));
}

test "parse: rejects an image too short to hold the header" {
    var buf: [0x100]u8 = @splat(0);
    try testing.expectError(error.ShortImage, parse(&buf));
}

test "parse: rejects a truncated setup (real-mode part exceeds the file)" {
    // Long enough to clear the ShortImage gate, but setup_sects claims a real-mode
    // part far bigger than the file — so the strip would run off the end.
    var buf: [0x1200]u8 = @splat(0);
    buf[SetupHeader.OFFSET] = 200; // rm = (200+1)*512 = 102912 ≫ 0x1200
    std.mem.writeInt(u16, buf[0x1fe..][0..2], BOOT_FLAG, .little);
    std.mem.writeInt(u32, buf[0x202..][0..4], HDRS_MAGIC, .little);
    std.mem.writeInt(u16, buf[0x236..][0..2], XLF_KERNEL_64, .little);
    try testing.expectError(error.TruncatedSetup, parse(&buf));
}
