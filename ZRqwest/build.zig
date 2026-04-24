const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const show_test_outputs = b.option(bool, "show-test-outputs", "Show test output examples") orelse false;

    const lib_module = b.addModule("zrqwest", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zrqwest",
        .root_module = lib_module,
    });

    b.installArtifact(lib);

    const lib_tests = b.addTest(.{
        .root_module = lib.root_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    if (show_test_outputs) {
        run_lib_tests.setEnvironmentVariable("SHOW_TEST_OUTPUTS", "1");
    }

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
}
