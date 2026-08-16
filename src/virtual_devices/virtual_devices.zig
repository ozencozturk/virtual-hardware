pub const Uart = @import("uart.zig").Uart;
pub const Virtio = @import("virtio.zig").Virtio;
pub const VirtioConsole = @import("vconsole.zig").VirtioConsole;

pub const riscv = @import("riscv/riscv.zig");
pub const x86 = @import("x86/x86.zig");

test {
    _ = @import("uart.zig");
    _ = @import("virtio.zig");
    _ = @import("vconsole.zig");
    _ = @import("riscv/riscv.zig");
    _ = @import("x86/x86.zig");
}
