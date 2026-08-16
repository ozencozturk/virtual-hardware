const bits = @import("bits");
const std = @import("std");
const testing = std.testing;
pub const Plic = struct {
    pub const PLIC_SIZE = 0x0400_0000;
    pub const UART0_IRQ = 10;
    pub const VIRTIO0_IRQ = 1;
    pub const NUM_SOURCES = 54; // QEMU constant
    pub const NUM_CONTEXT = 2; // QEMU const -- m & s. Note if we need to support multiple heart 2=h1-m, 3=h2-s etc
    pub const PENDING_BASE = 0x0000_1000;
    pub const ENABLE_BASE = 0x0000_2000;
    pub const THRESHOLD_CLAIM_BASE = 0x0020_0000;
    const WORDS = (NUM_SOURCES + 31) / 32; // = 2 (sources 0..31 in word 0, 32..53 in word 1)
    priority: [NUM_SOURCES]u32 = @splat(0),

    enable: [NUM_CONTEXT][WORDS]u32 = @splat(@splat(0)), // source 40 owns enable[ctx][1]'s 8th bit
    //enable[ctx][0]  → sources 0..31   (bit b = source b)
    //enable[ctx][1]  → sources 32..53  (bit b = source 32 + b)
    threshold: [NUM_CONTEXT]u32 = @splat(0),

    line: [NUM_SOURCES]bool = @splat(false),
    in_service: [NUM_SOURCES]bool = @splat(false),

    // Per-context memo of hasActionableInterrupt: null = stale (recompute on read), value = cached.
    // Derived state — deliberately excluded from hash(). Invalidated by every mutator (raise/lower on
    // transition, claim, complete, store), so a real change can never be masked by a stale entry.
    actionable: [NUM_CONTEXT]?bool = .{ null, null },

    fn invalidate(self: *Plic) void {
        self.actionable = .{ null, null };
    }

    const EnableCtx = struct {
        ctx: u1 = 0,
        word: u64 = 0,
    };

    fn pending(self: *const Plic, s: usize) bool {
        return self.line[s] and !self.in_service[s];
    }

    // Decode an enable-region address to (ctx, word). Returns null for an in-window
    // hole (ctx/word out of range) — the PLIC does not fault inside its own window
    // (real hw / QEMU: reserved slots read 0 / ignore writes). Out-of-window is the
    // bus decoder's job, not ours.
    fn parseEnableCtx(addr: u64) ?EnableCtx {
        const off = addr - ENABLE_BASE;
        const ctx = off / 0x80;
        if (ctx >= NUM_CONTEXT) return null;
        const word = (off % 0x80) / 4;
        if (word >= WORDS) return null;
        return .{ .ctx = @truncate(ctx), .word = word };
    }

    pub fn store(self: *Plic, addr: u64, comptime size: usize, value: u64) !void {
        // Word-only: sub-word / misaligned access faults (deliberate strictness tripwire —
        // no real driver does sub-word PLIC access). In-window holes below are permissive.
        if (size != 4 or !bits.isAligned(addr, 4)) {
            return error.AccessFault;
        }
        if (addr < PENDING_BASE) {
            const source = addr / 4;
            // source 0 reserved (hardwired 0); source >= NUM_SOURCES is an in-window hole → ignore
            if (source != 0 and source < NUM_SOURCES) {
                self.priority[source] = @truncate(value);
            }
        } else if (addr < ENABLE_BASE) {
            // pending is read-only (derived) — writes ignored
        } else if (addr < THRESHOLD_CLAIM_BASE) {
            if (parseEnableCtx(addr)) |ec| {
                self.enable[ec.ctx][ec.word] = @truncate(value);
            } // else: in-window hole → ignore
        } else {
            const off = addr - THRESHOLD_CLAIM_BASE;
            const ctx = off / 0x1000;
            if (ctx < NUM_CONTEXT) {
                switch (off % 0x1000) {
                    0 => self.threshold[ctx] = @truncate(value), // r/w
                    4 => self.complete(@truncate(value)),
                    else => {},
                }
            } // else: context out of range → ignore
        }
        self.invalidate(); // any config/complete write can change selectWinner's result
    }

    pub fn load(self: *Plic, addr: u64, comptime size: usize) !u64 {
        if (size != 4 or !bits.isAligned(addr, 4)) {
            return error.AccessFault;
        }
        if (addr < PENDING_BASE) {
            const source = addr / 4;
            // source 0 reserved, source >= NUM_SOURCES an in-window hole → both read 0
            return if (source == 0 or source >= NUM_SOURCES) 0 else self.priority[source];
        } else if (addr < ENABLE_BASE) {
            const word = (addr - PENDING_BASE) / 4;
            if (word >= WORDS) return 0; // out-of-range word → read 0 (permissive)
            var result: u32 = 0;
            for (0..32) |b| {
                const s = word * 32 + b;
                if (s < NUM_SOURCES and self.pending(s)) {
                    result |= @as(u32, 1) << @intCast(b);
                }
            }
            return result;
        } else if (addr < THRESHOLD_CLAIM_BASE) {
            return if (parseEnableCtx(addr)) |ec| self.enable[ec.ctx][ec.word] else 0;
        } else {
            const off = addr - THRESHOLD_CLAIM_BASE;
            const ctx = off / 0x1000;
            if (ctx >= NUM_CONTEXT) return 0; // context out of range → read 0
            return switch (off % 0x1000) {
                0 => self.threshold[ctx], // r/w
                4 => claim(self, @intCast(ctx)),
                else => 0,
            };
        }
    }

    pub fn complete(self: *Plic, id: usize) void {
        if (id < NUM_SOURCES) {
            self.in_service[id] = false;
            self.invalidate();
        }
    }
    fn selectWinner(self: *const Plic, ctx: u1) u64 {
        var best_id: u64 = 0;
        var best_prio: u32 = 0;
        for (self.priority, 0..) |p, s| {
            const enabled = (self.enable[ctx][s / 32] >> @intCast(s % 32)) & 1 != 0;
            const has_prio = p > self.threshold[ctx];
            if (self.pending(s) and enabled and has_prio) {
                if (p > best_prio) {
                    best_prio = p;
                    best_id = s;
                }
            }
        }
        return best_id;
    }
    pub fn claim(self: *Plic, ctx: u1) u64 {
        const winner = self.selectWinner(ctx);
        if (winner != 0) {
            self.in_service[winner] = true; // the ONLY side effect
            self.invalidate();
        }
        return winner;
    }

    pub fn hash(self: *const Plic, h: *std.hash.Wyhash) void {
        h.update(std.mem.asBytes(&self.priority));
        h.update(std.mem.asBytes(&self.enable));
        h.update(std.mem.asBytes(&self.threshold));
        h.update(std.mem.asBytes(&self.line));
        h.update(std.mem.asBytes(&self.in_service));
    }

    // raise/lower are the device-side gateway (the interrupt "wire"), called by trusted
    // device models — not guest MMIO. An out-of-range source is a device-model bug, so
    // assert the contract rather than fault (contrast the guest-facing load/store paths).
    pub fn raise(self: *Plic, src: usize) void {
        std.debug.assert(src < NUM_SOURCES);
        if (!self.line[src]) { // transition-guarded so per-retire re-drives don't invalidate
            self.line[src] = true;
            self.invalidate();
        }
    }

    pub fn lower(self: *Plic, src: usize) void {
        std.debug.assert(src < NUM_SOURCES);
        if (self.line[src]) {
            self.line[src] = false;
            self.invalidate();
        }
    }
    // Memoized: recompute only when actionable[ctx] is stale (null). Callers query this every retire,
    // so the cache turns the common no-change case into an O(1) lookup instead of a full source scan.
    pub fn hasActionableInterrupt(self: *Plic, ctx: u1) bool {
        return self.actionable[ctx] orelse {
            const a = self.selectWinner(ctx) != 0;
            self.actionable[ctx] = a;
            return a;
        };
    }
};
test "claim: highest priority wins, lowest-id tiebreak, and clears on claim" {
    var p = Plic{};
    // Sources 1 and 10, both signalled, both enabled for ctx 1, threshold 0.
    p.line[1] = true;
    p.line[10] = true;
    p.priority[1] = 1;
    p.priority[10] = 1;
    p.enable[1][0] = (1 << 1) | (1 << 10); // both in word 0
    p.threshold[1] = 0;

    // Equal priority → tie broken by lowest source id → 1.
    try testing.expectEqual(@as(u64, 1), p.claim(1));

    // claim() must have set in_service[1] → pending(1) is now false, so the next
    // claim skips 1 and returns 10.
    try testing.expectEqual(@as(u64, 10), p.claim(1));
}
test "load routes claim address (forces claim-branch analysis)" {
    var p = Plic{};
    _ = try p.load(0x20_1004, 4); // ctx1 claim → hits `claim(self, ...)` in load
}

test "complete clears in-service; line held high re-arms (drives store/load decode)" {
    var p = Plic{};
    p.raise(10);
    p.priority[10] = 1;
    p.enable[1][0] = (1 << 10);
    p.threshold[1] = 0;

    // claim via the bus-facing path (exercises load decode → claim())
    try testing.expectEqual(@as(u64, 10), try p.load(0x20_1004, 4)); // ctx1 claim → 10
    try testing.expectEqual(@as(u64, 0), try p.load(0x20_1004, 4)); // in service → nothing more

    // complete via store; line still high → pending re-derives → claimable again
    try p.store(0x20_1004, 4, 10);
    try testing.expectEqual(@as(u64, 10), try p.load(0x20_1004, 4));

    // drop the line, complete → truly done
    p.lower(10);
    try p.store(0x20_1004, 4, 10);
    try testing.expectEqual(@as(u64, 0), try p.load(0x20_1004, 4));

    // regression: a store to a hole (offset 8) must NOT be treated as complete
    p.raise(10);
    _ = try p.load(0x20_1004, 4); // claim → in service
    try p.store(0x20_1008, 4, 10); // hole: must be ignored, not a complete
    try testing.expect(p.in_service[10]); // still in service
}

test "width and alignment faults (PLIC is word-only)" {
    var p = Plic{};
    // wrong widths fault on both paths
    try testing.expectError(error.AccessFault, p.store(0x28, 1, 1));
    try testing.expectError(error.AccessFault, p.store(0x28, 8, 1));
    try testing.expectError(error.AccessFault, p.load(0x28, 2));
    // misaligned word access faults (0x2a % 4 != 0), even at the right width
    try testing.expectError(error.AccessFault, p.load(0x2a, 4));
    try testing.expectError(error.AccessFault, p.store(0x26, 4, 1));
}

test "threshold gates claim with strict >" {
    var p = Plic{};
    p.raise(10);
    p.priority[10] = 1;
    p.enable[1][0] = (1 << 10);

    // priority == threshold must NOT forward (needs strict >)
    p.threshold[1] = 1;
    try testing.expectEqual(@as(u64, 0), p.claim(1));

    // priority > threshold → claimable
    p.threshold[1] = 0;
    try testing.expectEqual(@as(u64, 10), p.claim(1));
}

test "enable gates claim per context (wrong-context enable does not help)" {
    var p = Plic{};
    p.raise(10);
    p.priority[10] = 5;
    p.threshold[1] = 0;

    // signalled + prioritised but not enabled for ctx1 → not claimable
    try testing.expectEqual(@as(u64, 0), p.claim(1));

    // enabling it for ctx0 (M) must not make it claimable for ctx1 (S)
    p.enable[0][0] = (1 << 10);
    try testing.expectEqual(@as(u64, 0), p.claim(1));

    // enabling for ctx1 → claimable
    p.enable[1][0] = (1 << 10);
    try testing.expectEqual(@as(u64, 10), p.claim(1));
}

test "pending register: derived read-only bitmap, per-word, cleared by claim" {
    var p = Plic{};
    // nothing signalled → word 0 reads 0
    try testing.expectEqual(@as(u64, 0), try p.load(0x1000, 4));

    // raise sources 1 and 10 (both in word 0) → both bits set in the first register
    p.raise(1);
    p.raise(10);
    try testing.expectEqual(@as(u64, (1 << 1) | (1 << 10)), try p.load(0x1000, 4)); // 0x402

    // raise source 40 → lands in word 1 (bit 40%32 = 8), NOT word 0. Exercises the word decode
    // and the `s < NUM_SOURCES` overhang guard (loop reaches s=54..63, must skip them).
    p.raise(40);
    try testing.expectEqual(@as(u64, (1 << 1) | (1 << 10)), try p.load(0x1000, 4)); // word 0 unchanged
    try testing.expectEqual(@as(u64, 1 << 8), try p.load(0x1004, 4)); // word 1

    // pending is DERIVED: claiming source 10 sets in_service → its pending bit clears
    p.priority[10] = 1;
    p.enable[1][0] = (1 << 10);
    p.threshold[1] = 0;
    try testing.expectEqual(@as(u64, 10), p.claim(1)); // in_service[10] = true
    try testing.expectEqual(@as(u64, 1 << 1), try p.load(0x1000, 4)); // 10 gone (in service), 1 remains

    // READ-ONLY: a write to the pending region is ignored (no MMIO path to set pending)
    try p.store(0x1000, 4, 0xFFFF_FFFF);
    try testing.expectEqual(@as(u64, 1 << 1), try p.load(0x1000, 4)); // unchanged by the store
}

test "in-window out-of-range is permissive (read 0 / ignore write), not a fault" {
    var p = Plic{};
    // out-of-range source (>= NUM_SOURCES) in the priority region: read 0, write ignored, no fault
    const oob_prio = 4 * 60; // source 60, beyond NUM_SOURCES=54
    try testing.expectEqual(@as(u64, 0), try p.load(oob_prio, 4));
    try p.store(oob_prio, 4, 0xDEAD); // ignored, must not fault
    try testing.expectEqual(@as(u64, 0), try p.load(oob_prio, 4));

    // out-of-range context in the enable region (ctx 5): read 0, write ignored
    const oob_enable = Plic.ENABLE_BASE + 0x80 * 5;
    try testing.expectEqual(@as(u64, 0), try p.load(oob_enable, 4));
    try p.store(oob_enable, 4, 0xFF); // ignored

    // out-of-range context in the threshold/claim region: read 0, write ignored
    const oob_thresh = Plic.THRESHOLD_CLAIM_BASE + 0x1000 * 5;
    try testing.expectEqual(@as(u64, 0), try p.load(oob_thresh, 4));
    try p.store(oob_thresh, 4, 3); // ignored

    // a valid nearby register still works (permissiveness didn't swallow real ones)
    try p.store(0x28, 4, 7); // priority[10]
    try testing.expectEqual(@as(u64, 7), try p.load(0x28, 4));

    // width/alignment is still a real fault (deliberate word-only strictness)
    try testing.expectError(error.AccessFault, p.load(oob_prio, 2));
    try testing.expectError(error.AccessFault, p.load(oob_prio + 1, 4));
}
