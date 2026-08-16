//! x86 platform devices: the ACPI PM1 event and control block.

pub const AcpiPm = @import("acpi_pm.zig").AcpiPm;
pub const acpi_pm = @import("acpi_pm.zig");

test {
    _ = @import("acpi_pm.zig");
}
