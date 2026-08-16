const std = @import("std");
const regs = @import("registers.zig");

// x86-64 4-level page tables over a guest RAM slice — both directions:
//
//   buildIdentityMap()  writes the boot identity map and returns its CR3.
//   translate() /
//   fetchInstruction()  walk the guest's own tables to resolve a virtual address
//                       (and read the instruction bytes there).
//
// The walk needs only CR3 and the RAM slice, so it resolves an address under
// whatever tables the guest has installed for itself, not just the boot map.
//
// **`ram` is indexed by guest-physical address**: guest RAM starts at GPA 0 and
// `gpa == offset` throughout. Nothing here performs I/O.

// Where the boot identity map's three table pages live, as offsets into guest
// RAM. CR3 and every table it reaches must be memory the guest can address, so
// these sit inside the slice; a caller placing anything else in low RAM keeps it
// clear of them.
pub const PML4_OFF = 0x1000;
pub const PDPT_OFF = 0x2000;
pub const PD_OFF = 0x3000;

// Leaf page sizes, as the shift count each level maps.
const SHIFT_4K: u6 = 12;
const SHIFT_2M: u6 = 21;
const SHIFT_1G: u6 = 30;

fn writeU64(ram: []u8, off: usize, val: u64) void {
    std.mem.writeInt(u64, ram[off..][0..8], val, .little);
}

fn readU64(ram: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, ram[off..][0..8], .little);
}

/// Write a 4-level identity map (2 MiB pages) into `ram` and return the CR3
/// value, which is the PML4's guest-physical address. 512 leaf PDEs identity-map
/// the low 1 GiB; only the part backed by `ram` is real memory, so a guest
/// touching beyond it reads nothing.
pub fn buildIdentityMap(ram: []u8) u64 {
    // GPA == offset, so the table offsets ARE their guest-physical addresses.
    const pml4_gpa = PML4_OFF;
    const pdpt_gpa = PDPT_OFF;
    const pd_gpa = PD_OFF;

    const Pte = regs.PageTableEntry;
    // Present, writable table links: PML4[0] → PDPT, PDPT[0] → PD.
    writeU64(ram, PML4_OFF, (Pte{ .p = true, .rw = true, .frame = @intCast(pdpt_gpa >> 12) }).toBits());
    writeU64(ram, PDPT_OFF, (Pte{ .p = true, .rw = true, .frame = @intCast(pd_gpa >> 12) }).toBits());
    // PD[i]: present, writable 2 MiB leaf (PS) mapping guest-physical i*2MiB.
    for (0..512) |i| {
        const pde = Pte{ .p = true, .rw = true, .ps = true, .frame = @intCast((i * 0x20_0000) >> 12) };
        writeU64(ram, PD_OFF + i * 8, pde.toBits());
    }
    return pml4_gpa;
}

/// Translate a guest virtual address to a guest-physical address using the
/// page tables rooted at `cr3`. Returns null if any level is not present or an
/// entry lies outside `ram` (a malformed or not-yet-mapped address).
pub fn translate(ram: []const u8, cr3: u64, va: u64) ?u64 {
    const la = regs.LinearAddress.fromBits(va);

    // CR3 holds the PML4's physical address in the same frame field an entry
    // uses, so decoding it the same way keeps one representation.
    const root = regs.PageTableEntry.fromBits(cr3).frameAddr();

    const pml4e = readEntry(ram, root, la.pml4) orelse return null;
    if (!pml4e.p) return null;

    // PDPT: a table link, or a 1 GiB leaf.
    const pdpte = readEntry(ram, pml4e.frameAddr(), la.pdpt) orelse return null;
    if (!pdpte.p) return null;
    if (pdpte.ps) return leaf(pdpte, la, SHIFT_1G);

    // PD: a table link, or a 2 MiB leaf.
    const pde = readEntry(ram, pdpte.frameAddr(), la.pd) orelse return null;
    if (!pde.p) return null;
    if (pde.ps) return leaf(pde, la, SHIFT_2M);

    // PT: the 4 KiB frame.
    const pte = readEntry(ram, pde.frameAddr(), la.pt) orelse return null;
    if (!pte.p) return null;
    return leaf(pte, la, SHIFT_4K);
}

/// Physical address a leaf entry maps `la` to. The frame supplies the bits above
/// the page and the address supplies the bits within it. A large page's frame is
/// aligned down first, since hardware ignores the frame bits it overlaps.
fn leaf(entry: regs.PageTableEntry, la: regs.LinearAddress, page_shift: u6) u64 {
    const base = std.mem.alignBackward(u64, entry.frameAddr(), @as(u64, 1) << page_shift);
    return base | la.offsetIn(page_shift);
}

/// Read entry `index` of the 512-entry table at `table_gpa`, or null if it falls
/// outside guest RAM.
fn readEntry(ram: []const u8, table_gpa: u64, index: u9) ?regs.PageTableEntry {
    const off = table_gpa + @as(u64, index) * 8;
    if (off + 8 > ram.len) return null;
    return regs.PageTableEntry.fromBits(
        std.mem.readInt(u64, ram[@intCast(off)..][0..8], .little),
    );
}

/// Copy up to `out.len` instruction bytes starting at virtual address `rip` into
/// `out`, returning the bytes actually read. Walks per page so an instruction
/// that straddles a page boundary is assembled from both frames (the pages need
/// not be physically contiguous). Returns null if even the first byte cannot be
/// translated, and a short slice when a later page is unmapped.
pub fn fetchInstruction(ram: []const u8, cr3: u64, rip: u64, out: []u8) ?[]const u8 {
    var n: usize = 0;
    while (n < out.len) {
        const gpa = translate(ram, cr3, rip + n) orelse break;
        if (gpa >= ram.len) break;
        // Bytes left in this 4 KiB frame. 4 KiB granularity also holds inside a
        // large page, which is contiguous, so the next boundary just re-translates.
        const in_page = 0x1000 - @as(u64, regs.LinearAddress.fromBits(gpa).offset);
        const want = @min(out.len - n, @min(in_page, ram.len - gpa));
        @memcpy(out[n..][0..want], ram[@intCast(gpa)..][0..want]);
        n += want;
    }
    return if (n == 0) null else out[0..n];
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

// Table placement inside the fake RAM. The first three ARE the real boot-map
// offsets (so these tests and buildIdentityMap can never drift apart); PT is a
// fourth level only these tests use, since the boot map stops at 2 MiB leaves.
const PML4 = PML4_OFF;
const PDPT = PDPT_OFF;
const PD = PD_OFF;
const PT = 0x4000;

/// A present table link (or, with `ps`, a leaf) at `pa`, as the guest would
/// write it — built through the struct rather than OR-ing raw bits.
fn entryAt(pa: u64, ps: bool) u64 {
    return (regs.PageTableEntry{
        .p = true,
        .ps = ps,
        .frame = @intCast(pa >> 12),
    }).toBits();
}

/// Byte offset of table entry `index` within its 512-entry page.
fn slot(index: u9) usize {
    return @as(usize, index) * 8;
}

fn put(ram: []u8, gpa: usize, val: u64) void {
    std.mem.writeInt(u64, ram[gpa..][0..8], val, .little);
}

/// A fake RAM with a 4-level table mapping `va` → `pa` via a 4 KiB leaf.
fn map4k(ram: []u8, va: u64, pa: u64) void {
    put(ram, PML4 + slot(regs.LinearAddress.fromBits(va).pml4), entryAt(PDPT, false));
    put(ram, PDPT + slot(regs.LinearAddress.fromBits(va).pdpt), entryAt(PD, false));
    put(ram, PD + slot(regs.LinearAddress.fromBits(va).pd), entryAt(PT, false));
    put(ram, PT + slot(regs.LinearAddress.fromBits(va).pt), entryAt(pa, false));
}

test "buildIdentityMap: writes a 4-level identity map and returns the PML4 GPA as CR3" {
    var buf: [0x4000]u8 = @splat(0);
    const cr3 = buildIdentityMap(&buf);

    // CR3 is the PML4 guest-physical address.
    try testing.expectEqual(@as(u64, PML4_OFF), cr3);
    // Table links: PML4[0] → PDPT, PDPT[0] → PD, both with P|RW (low 12 bits 0x3).
    try testing.expectEqual(@as(u64, PDPT_OFF | 0x3), readU64(&buf, PML4_OFF));
    try testing.expectEqual(@as(u64, PD_OFF | 0x3), readU64(&buf, PDPT_OFF));
    // Decoded rather than masked: the flags are named fields, and nothing
    // above bit 11 is a flag.
    const link = regs.PageTableEntry.fromBits(readU64(&buf, PML4_OFF));
    try testing.expect(link.p and link.rw and !link.ps);
    // Leaf PDEs: PD[0] maps GPA 0, PD[1] maps 2 MiB, PD[255] maps 255*2 MiB.
    try testing.expectEqual(@as(u64, 0x83), readU64(&buf, PD_OFF));
    try testing.expectEqual(@as(u64, 0x20_0000 | 0x83), readU64(&buf, PD_OFF + 8));
    try testing.expectEqual(@as(u64, (255 * 0x20_0000) | 0x83), readU64(&buf, PD_OFF + 255 * 8));
    // Every one of the 512 PDEs is a present, writable 2 MiB leaf (P|RW|PS).
    for (0..512) |i| {
        const pde = regs.PageTableEntry.fromBits(readU64(&buf, PD_OFF + i * 8));
        try testing.expect(pde.p);
        try testing.expect(pde.rw);
        try testing.expect(pde.ps); // 2 MiB leaf
        try testing.expectEqual(@as(u40, @intCast(i * 0x20_0000 >> 12)), pde.frame);
    }
}

// The identity map the builder writes must be walkable by the walker in this same
// module — the two directions agree, which neither test proved on its own before.
test "buildIdentityMap + translate: the boot map identity-maps the low 1 GiB" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const cr3 = buildIdentityMap(ram);

    // Identity: VA == GPA, including inside a 2 MiB leaf and at a page boundary.
    try testing.expectEqual(@as(?u64, 0), translate(ram, cr3, 0));
    try testing.expectEqual(@as(?u64, 0x1234), translate(ram, cr3, 0x1234));
    try testing.expectEqual(@as(?u64, 0x20_0000), translate(ram, cr3, 0x20_0000));
    try testing.expectEqual(@as(?u64, 0x1FF_FFFF), translate(ram, cr3, 0x1FF_FFFF));
}

test "translate: a 4 KiB mapping resolves, preserving the page offset" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const va: u64 = 0xffff_8000_1234_5000;
    map4k(ram, va, 0x9000);
    try testing.expectEqual(@as(?u64, 0x9000), translate(ram, PML4, va));
    try testing.expectEqual(@as(?u64, 0x9abc), translate(ram, PML4, va + 0xabc));
}

test "translate: a 2 MiB leaf (PS at the PD level) supplies the low 21 bits" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const va: u64 = 0xffff_8000_0060_0000; // inside the 2 MiB page at 0x600000
    put(ram, PML4 + slot(regs.LinearAddress.fromBits(va).pml4), entryAt(PDPT, false));
    put(ram, PDPT + slot(regs.LinearAddress.fromBits(va).pdpt), entryAt(PD, false));
    put(ram, PD + slot(regs.LinearAddress.fromBits(va).pd), entryAt(0x0080_0000, true));

    // The PD entry maps 2 MiB at physical 0x800000; va's low 21 bits are the offset.
    try testing.expectEqual(@as(?u64, 0x0080_0000), translate(ram, PML4, va));
    try testing.expectEqual(@as(?u64, 0x0080_1234), translate(ram, PML4, va + 0x1234));
}

test "translate: a 1 GiB leaf (PS at the PDPT level) supplies the low 30 bits" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const va: u64 = 0xffff_8000_4000_0000;
    put(ram, PML4 + slot(regs.LinearAddress.fromBits(va).pml4), entryAt(PDPT, false));
    put(ram, PDPT + slot(regs.LinearAddress.fromBits(va).pdpt), entryAt(0x4000_0000, true));
    try testing.expectEqual(@as(?u64, 0x4000_0000), translate(ram, PML4, va));
    try testing.expectEqual(@as(?u64, 0x4000_0555), translate(ram, PML4, va + 0x555));
}

test "translate: a non-present entry at any level yields null" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0); // everything non-present

    const va: u64 = 0xffff_8000_1234_5000;
    try testing.expectEqual(@as(?u64, null), translate(ram, PML4, va));

    // Present down to the PD, but the leaf PTE is absent.
    put(ram, PML4 + slot(regs.LinearAddress.fromBits(va).pml4), entryAt(PDPT, false));
    put(ram, PDPT + slot(regs.LinearAddress.fromBits(va).pdpt), entryAt(PD, false));
    put(ram, PD + slot(regs.LinearAddress.fromBits(va).pd), entryAt(PT, false));
    try testing.expectEqual(@as(?u64, null), translate(ram, PML4, va));
}

test "translate: a table pointing outside guest RAM yields null" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const va: u64 = 0xffff_8000_1234_5000;
    // PML4 entry points at a PDPT far past the end of this RAM.
    put(ram, PML4 + slot(regs.LinearAddress.fromBits(va).pml4), entryAt(0x8000_0000, false));
    try testing.expectEqual(@as(?u64, null), translate(ram, PML4, va));
}

test "fetchInstruction: reads the bytes at RIP through the page tables" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const va: u64 = 0xffff_8000_1234_5000;
    map4k(ram, va, 0x9000);
    // Plant "mov [rdx], eax" (89 02) at the mapped physical page.
    ram[0x9000] = 0x89;
    ram[0x9001] = 0x02;

    var buf: [16]u8 = undefined;
    const got = fetchInstruction(ram, PML4, va, &buf).?;
    try testing.expectEqual(@as(u8, 0x89), got[0]);
    try testing.expectEqual(@as(u8, 0x02), got[1]);
}

// An instruction may straddle a page boundary, and the two pages need not be
// physically adjacent — the fetch must follow the tables for each.
test "fetchInstruction: assembles across a page boundary into discontiguous frames" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const va: u64 = 0xffff_8000_1234_5000;
    map4k(ram, va, 0x9000); // first page  → physical 0x9000
    map4k(ram, va + 0x1000, 0xe000); // second page → physical 0xe000 (not adjacent)

    // Put the last byte of page one and the first of page two next to each other
    // virtually: RIP starts 1 byte before the boundary.
    ram[0x9fff] = 0x89; // opcode at the very end of the first frame
    ram[0xe000] = 0x02; // ModRM at the start of the second

    var buf: [16]u8 = undefined;
    const got = fetchInstruction(ram, PML4, va + 0xfff, &buf).?;
    try testing.expect(got.len >= 2);
    try testing.expectEqual(@as(u8, 0x89), got[0]);
    try testing.expectEqual(@as(u8, 0x02), got[1]);
}

test "fetchInstruction: an untranslatable RIP yields null" {
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), fetchInstruction(ram, PML4, 0xffff_8000_1234_5000, &buf));
}

// The end-to-end shape the run loop depends on: fetch at RIP, then decode.
test "fetchInstruction + decode: a walked instruction decodes with its length" {
    const mmio_decode = @import("mmio_decode.zig");
    const ram = try testing.allocator.alloc(u8, 0x20000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const va: u64 = 0xffff_8000_1234_5000;
    map4k(ram, va, 0x9000);
    // mov [rdx+0x10], eax → 89 42 10 (a 3-byte instruction, IOWIN-style offset)
    ram[0x9000] = 0x89;
    ram[0x9001] = 0x42;
    ram[0x9002] = 0x10;

    var buf: [16]u8 = undefined;
    const bytes = fetchInstruction(ram, PML4, va, &buf).?;
    const op = mmio_decode.decode(bytes).?;
    try testing.expectEqual(mmio_decode.Mov.Dir.write, op.dir);
    try testing.expectEqual(@as(u4, 0), op.reg); // eax
    try testing.expectEqual(@as(u8, 3), op.len); // RIP advances by 3
}
