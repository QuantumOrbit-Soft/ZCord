const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ZCord", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    add_project_imports(b, mod, target, optimize);

    const lib = b.addLibrary(.{
        .name = "ZCord",
        .root_module = mod,
    });

    b.installArtifact(lib);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);
}

fn add_project_imports(
    b: *std.Build,
    root_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const internal_module = b.createModule(.{
        .root_source_file = b.path("src/internal/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zrqwest_module = b.createModule(.{
        .root_source_file = b.path("ZRqwest/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    root_module.addImport("internal", internal_module);
    root_module.addImport("zrqwest", zrqwest_module);
}
