//! x86 platform devices: the ACPI PM1 block, the I/O APIC and the local APIC.

pub const AcpiPm = @import("acpi_pm.zig").AcpiPm;
pub const acpi_pm = @import("acpi_pm.zig");
pub const Ioapic = @import("ioapic.zig").Ioapic;
pub const ioapic = @import("ioapic.zig");
pub const Lapic = @import("lapic.zig").Lapic;
pub const lapic = @import("lapic.zig");

test {
    _ = @import("acpi_pm.zig");
    _ = @import("ioapic.zig");
    _ = @import("lapic.zig");
}
