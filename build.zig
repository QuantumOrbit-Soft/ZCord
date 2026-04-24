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
    const api_module = b.createModule(.{
        .root_source_file = b.path("src/api/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const constants_module = b.createModule(.{
        .root_source_file = b.path("src/constants/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const errors_module = b.createModule(.{
        .root_source_file = b.path("src/errors/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const events_module = b.createModule(.{
        .root_source_file = b.path("src/events/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gateway_module = b.createModule(.{
        .root_source_file = b.path("src/gateway/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const internal_module = b.createModule(.{
        .root_source_file = b.path("src/internal/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const models_module = b.createModule(.{
        .root_source_file = b.path("src/models/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const utils_module = b.createModule(.{
        .root_source_file = b.path("src/utils/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    api_module.addImport("errors", errors_module);
    api_module.addImport("models", models_module);

    root_module.addImport("api", api_module);
    root_module.addImport("constants", constants_module);
    root_module.addImport("errors", errors_module);
    root_module.addImport("events", events_module);
    root_module.addImport("gateway", gateway_module);
    root_module.addImport("internal", internal_module);
    root_module.addImport("models", models_module);
    root_module.addImport("utils", utils_module);
}
