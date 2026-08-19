pub const Uart = @import("uart.zig").Uart;
pub const VirtioBalloon = @import("virtio_balloon.zig").VirtioBalloon;
pub const VirtioBlk = @import("virtio_blk.zig").VirtioBlk;
pub const VirtioNet = @import("virtio_net.zig").VirtioNet;
pub const VirtioConsole = @import("virtio_console.zig").VirtioConsole;
pub const VirtioVsock = @import("virtio_vsock.zig").VirtioVsock;
pub const VirtioRng = @import("virtio_rng.zig").VirtioRng;

pub const virtqueue = @import("virtqueue.zig");
pub const packet_fifo = @import("packet_fifo.zig");
pub const virtio_mmio = @import("virtio_mmio.zig");

pub const riscv = @import("riscv/riscv.zig");
pub const x86 = @import("x86/x86.zig");
pub const arm64 = @import("arm64/arm64.zig");

test {
    _ = @import("uart.zig");
    _ = @import("virtqueue.zig");
    _ = @import("packet_fifo.zig");
    _ = @import("virtio_mmio.zig");
    _ = @import("virtio_balloon.zig");
    _ = @import("virtio_blk.zig");
    _ = @import("virtio_net.zig");
    _ = @import("virtio_console.zig");
    _ = @import("virtio_vsock.zig");
    _ = @import("virtio_rng.zig");
    _ = @import("riscv/riscv.zig");
    _ = @import("x86/x86.zig");
    _ = @import("arm64/arm64.zig");
}
