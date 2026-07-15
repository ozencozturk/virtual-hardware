pub const Uart = @import("uart.zig").Uart;
pub const Virtio = @import("virtio.zig").Virtio;

test {
    _ = @import("uart.zig");
    _ = @import("virtio.zig");
}
