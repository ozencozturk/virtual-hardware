//! x86 platform devices: the ACPI PM1 event and control block, and the I/O APIC.

pub const AcpiPm = @import("acpi_pm.zig").AcpiPm;
pub const acpi_pm = @import("acpi_pm.zig");
pub const Ioapic = @import("ioapic.zig").Ioapic;
pub const ioapic = @import("ioapic.zig");

test {
    _ = @import("acpi_pm.zig");
    _ = @import("ioapic.zig");
}
