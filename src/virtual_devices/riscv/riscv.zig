//! RISC-V platform devices: the interrupt controller and the core-local timer.

pub const Plic = @import("plic.zig").Plic;
pub const Clint = @import("clint.zig").Clint;

test {
    _ = @import("plic.zig");
    _ = @import("clint.zig");
}
