//! The x86-64 architecture itself: control- and model-register layouts, page
//! tables over a guest RAM slice, and a decoder for the instruction behind a
//! memory-mapped access.
//!
//! Devices that happen to be x86 live under `virtual_devices.x86`; this is the
//! processor, not the board.

pub const registers = @import("registers.zig");
pub const paging = @import("paging.zig");
pub const mmio_decode = @import("mmio_decode.zig");

test {
    _ = @import("registers.zig");
    _ = @import("paging.zig");
    _ = @import("mmio_decode.zig");
}
