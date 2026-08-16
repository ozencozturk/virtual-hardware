const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Leaf utility module.
    const bits = b.addModule("bits", .{
        .root_source_file = b.path("src/bits/bits.zig"),
        .target = target,
    });

    // Device models (uart + virtio); virtio imports `bits`.
    const virtual_devices = b.addModule("virtual_devices", .{
        .root_source_file = b.path("src/virtual_devices/virtual_devices.zig"),
        .target = target,
    });
    virtual_devices.addImport("bits", bits);

    // Flattened device tree (DTB) serializer. std-only, no device dependency.
    const fdt = b.addModule("fdt", .{
        .root_source_file = b.path("src/fdt/fdt.zig"),
        .target = target,
    });

    // ACPI table serializer. std-only, no device dependency.
    const acpi = b.addModule("acpi", .{
        .root_source_file = b.path("src/acpi/acpi.zig"),
        .target = target,
    });

    // The x86-64 architecture: registers, page tables, instruction decode.
    const x86 = b.addModule("x86", .{
        .root_source_file = b.path("src/x86/x86.zig"),
        .target = target,
    });

    // Linux boot-protocol structures, namespaced per architecture.
    const linux_boot = b.addModule("linux_boot", .{
        .root_source_file = b.path("src/linux_boot/linux_boot.zig"),
        .target = target,
    });

    // Test step: run the bits tests and the virtual_devices root tests.
    const bits_tests = b.addTest(.{ .root_module = bits });
    const run_bits_tests = b.addRunArtifact(bits_tests);

    const devices_test_mod = b.createModule(.{
        .root_source_file = b.path("src/virtual_devices/virtual_devices.zig"),
        .target = target,
        .optimize = optimize,
    });
    devices_test_mod.addImport("bits", bits);
    const devices_tests = b.addTest(.{ .root_module = devices_test_mod });
    const run_devices_tests = b.addRunArtifact(devices_tests);

    const fdt_tests = b.addTest(.{ .root_module = fdt });
    const run_fdt_tests = b.addRunArtifact(fdt_tests);

    const acpi_tests = b.addTest(.{ .root_module = acpi });
    const run_acpi_tests = b.addRunArtifact(acpi_tests);

    const x86_tests = b.addTest(.{ .root_module = x86 });
    const run_x86_tests = b.addRunArtifact(x86_tests);

    const linux_boot_tests = b.addTest(.{ .root_module = linux_boot });
    const run_linux_boot_tests = b.addRunArtifact(linux_boot_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_bits_tests.step);
    test_step.dependOn(&run_devices_tests.step);
    test_step.dependOn(&run_fdt_tests.step);
    test_step.dependOn(&run_acpi_tests.step);
    test_step.dependOn(&run_x86_tests.step);
    test_step.dependOn(&run_linux_boot_tests.step);
}
