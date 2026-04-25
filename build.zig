const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const imports = create_project_imports(b, target, optimize);

    const mod = b.addModule("ZCord", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    add_project_imports(mod, imports);

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

    const sample_mod = b.createModule(.{
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sample_mod.addImport("ZCord", mod);
    sample_mod.addImport("internal", imports.internal);
    sample_mod.addImport("zrqwest", imports.zrqwest);

    const sample_exe = b.addExecutable(.{
        .name = "zcord-sample",
        .root_module = sample_mod,
    });

    const run_sample = b.addRunArtifact(sample_exe);
    const sample_step = b.step("sample", "Run the Discord REST sample using .env");
    sample_step.dependOn(&run_sample.step);
}

const ProjectImports = struct {
    internal: *std.Build.Module,
    zrqwest: *std.Build.Module,
};

fn create_project_imports(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ProjectImports {
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

    return .{
        .internal = internal_module,
        .zrqwest = zrqwest_module,
    };
}

fn add_project_imports(
    root_module: *std.Build.Module,
    imports: ProjectImports,
) void {
    root_module.addImport("internal", imports.internal);
    root_module.addImport("zrqwest", imports.zrqwest);
}
