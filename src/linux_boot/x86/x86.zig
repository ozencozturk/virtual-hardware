//! The x86 Linux boot protocol: the bzImage setup header and the 4 KiB
//! boot_params zero page (Documentation/arch/x86/boot.rst).

pub const bzimage = @import("bzimage.zig");
pub const boot_params = @import("boot_params.zig");

test {
    _ = @import("bzimage.zig");
    _ = @import("boot_params.zig");
}
