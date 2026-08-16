pub const Uart = @import("uart.zig").Uart;
pub const Virtio = @import("virtio.zig").Virtio;
pub const VirtioConsole = @import("vconsole.zig").VirtioConsole;

pub const riscv = @import("riscv/root.zig");

test {
    _ = @import("uart.zig");
    _ = @import("virtio.zig");
    _ = @import("vconsole.zig");
    _ = @import("riscv/root.zig");
}
