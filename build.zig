const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Leaf utility module.
    const bits = b.addModule("bits", .{
        .root_source_file = b.path("src/bits.zig"),
        .target = target,
    });

    // Device models (uart + virtio); virtio imports `bits`.
    const devices = b.addModule("devices", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    devices.addImport("bits", bits);

    // Test step: run bits.zig tests and the devices root tests.
    const bits_tests = b.addTest(.{ .root_module = bits });
    const run_bits_tests = b.addRunArtifact(bits_tests);

    const devices_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    devices_test_mod.addImport("bits", bits);
    const devices_tests = b.addTest(.{ .root_module = devices_test_mod });
    const run_devices_tests = b.addRunArtifact(devices_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_bits_tests.step);
    test_step.dependOn(&run_devices_tests.step);
}
