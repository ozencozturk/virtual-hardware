pub const Uart = @import("uart.zig").Uart;
pub const Virtio = @import("virtio.zig").Virtio;
pub const VirtioConsole = @import("vconsole.zig").VirtioConsole;

test {
    _ = @import("uart.zig");
    _ = @import("virtio.zig");
    _ = @import("vconsole.zig");
}
