const std = @import("std");
const bits = @import("bits");
const testing = std.testing;

pub const Clint = struct {
    pub const CLINT_SIZE = 0x10000;
    pub const MSIP: u64 = 0;
    pub const MTIMECMP: u64 = 0x4000;
    pub const MTIME: u64 = 0xBFF8;
    mtimecmp: u64 = 0,
    msip: u32 = 0,
    mtime: u64 = 0,

    // Registers are accessed at their natural width (RV64): msip is 4 bytes,
    // mtimecmp/mtime are 8. A mismatched width faults rather than silently
    // truncating — this keeps the bus contract that a load never returns more
    // than size*8 significant bits (see memory.load). RV32 half-word access
    // (mtime[63:32] at +4, etc.) is not supported.
    pub fn store(self: *Clint, addr: u64, comptime size: usize, value: u64) !void {
        if (!bits.inBounds(addr, size, CLINT_SIZE)) {
            return error.AccessFault;
        }
        switch (addr) {
            MSIP => {
                if (size != 4) return error.AccessFault;
                self.msip = @truncate(value);
            },
            MTIMECMP => {
                if (size != 8) return error.AccessFault;
                self.mtimecmp = value;
            },
            MTIME => {
                if (size != 8) return error.AccessFault;
                // read-only: mtime is a pure function of instret (pushed each retire)
            },
            else => return error.AccessFault,
        }
    }
    pub fn load(self: *const Clint, addr: u64, comptime size: usize) !u64 {
        if (!bits.inBounds(addr, size, CLINT_SIZE)) return error.AccessFault;

        return switch (addr) {
            MSIP => if (size == 4) @as(u64, self.msip) else error.AccessFault,
            MTIMECMP => if (size == 8) self.mtimecmp else error.AccessFault,
            MTIME => if (size == 8) self.mtime else error.AccessFault,
            else => error.AccessFault,
        };
    }
    pub fn hash(self: *const Clint, h: *std.hash.Wyhash) void {
        h.update(std.mem.asBytes(&self.mtimecmp));
        h.update(std.mem.asBytes(&self.msip));
        h.update(std.mem.asBytes(&self.mtime));
    }
};

test "natural-width access; mismatched width faults" {
    var c = Clint{};

    // mtimecmp: 8-byte access round-trips; 4-byte access faults both ways
    try c.store(Clint.MTIMECMP, 8, 0xDEADBEEF_CAFEBABE);
    try testing.expectEqual(@as(u64, 0xDEADBEEF_CAFEBABE), try c.load(Clint.MTIMECMP, 8));
    try testing.expectError(error.AccessFault, c.store(Clint.MTIMECMP, 4, 1));
    try testing.expectError(error.AccessFault, c.load(Clint.MTIMECMP, 4));

    // msip: 4-byte access only; the load never returns more than 32 bits
    try c.store(Clint.MSIP, 4, 1);
    try testing.expectEqual(@as(u64, 1), try c.load(Clint.MSIP, 4));
    try testing.expectError(error.AccessFault, c.store(Clint.MSIP, 8, 1));
    try testing.expectError(error.AccessFault, c.load(Clint.MSIP, 8));
}

test "mtime is read-only (store ignored) but width-checked" {
    var c = Clint{};
    c.mtime = 42; // as the push model would have set it
    try c.store(Clint.MTIME, 8, 0); // correct width, but ignored
    try testing.expectEqual(@as(u64, 42), try c.load(Clint.MTIME, 8));
    try testing.expectError(error.AccessFault, c.store(Clint.MTIME, 4, 0)); // wrong width faults
}
