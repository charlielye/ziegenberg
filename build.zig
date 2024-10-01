const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies.
    const yazap = b.dependency("yazap", .{});

    // Lib.
    {
        const lib = b.addStaticLibrary(.{
            .name = "zb",
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            // .code_model = std.builtin.CodeModel.large,
        });
        lib.bundle_compiler_rt = true;

        // This declares intent for the library to be installed into the standard
        // location when the user invokes the "install" step (the default step when
        // running `zig build`).
        b.installArtifact(lib);
    }

    // Brillig VM Exe.
    {
        const exe = b.addExecutable(.{
            .name = "zb-bvm",
            .root_source_file = b.path("src/zb_bvm.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        });
        exe.bundle_compiler_rt = true;
        exe.root_module.addImport("yazap", yazap.module("yazap"));
        exe.linkSystemLibrary("c");

        b.installArtifact(exe);
    }

    // AVM Exe.
    {
        const exe = b.addExecutable(.{
            .name = "zb-avm",
            .root_source_file = b.path("src/zb_avm.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        });
        exe.bundle_compiler_rt = true;
        exe.root_module.addImport("yazap", yazap.module("yazap"));
        exe.linkSystemLibrary("c");

        b.installArtifact(exe);
    }

    // Unit tests.
    {
        // Creates a step for unit testing. This only builds the test executable
        // but does not run it.
        const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
        const lib_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .filters = test_filters,
        });

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
        run_lib_unit_tests.step.dependOn(b.getInstallStep());
        run_lib_unit_tests.has_side_effects = true;

        // const exe_unit_tests = b.addTest(.{
        //     .root_source_file = b.path("src/main.zig"),
        //     .target = target,
        //     .optimize = optimize,
        // });

        // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        // Similar to creating the run step earlier, this exposes a `test` step to
        // the `zig build --help` menu, providing a way for the user to request
        // running the unit tests.
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        // test_step.dependOn(&run_exe_unit_tests.step);
    }
}
