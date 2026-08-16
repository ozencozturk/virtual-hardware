//! How each architecture expects Linux to be entered: the image header formats
//! and boot-protocol structures. Placement policy (where a VMM puts the kernel,
//! initrd and DTB in guest RAM) stays with the VMM — only the formats live here.

pub const arm64 = @import("arm64.zig");

test {
    _ = @import("arm64.zig");
}
