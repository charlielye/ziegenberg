const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies.
    const yazap = b.dependency("yazap", .{});
    const lmdb = b.dependency("lmdb", .{});

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
        lib.root_module.addImport("lmdb", lmdb.module("lmdb"));
        // lib.root_module.addSystemIncludePath(lazy_path: LazyPath)
        lib.bundle_compiler_rt = true;
        lib.linkLibC();

        // This declares intent for the library to be installed into the standard
        // location when the user invokes the "install" step (the default step when
        // running `zig build`).
        b.installArtifact(lib);
    }

    // Exe.
    {
        const exe = b.addExecutable(.{
            .name = "zb",
            .root_source_file = b.path("src/zb.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        });
        exe.bundle_compiler_rt = true;
        exe.root_module.addImport("yazap", yazap.module("yazap"));
        // exe.linkLibC();

        b.installArtifact(exe);
    }

    // Unit tests.
    {
        // Creates a step for unit testing. This only builds the test executable
        // but does not run it.
        const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
        const lib_unit_tests = b.addTest(.{
            .name = "tests",
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .filters = test_filters,
        });
        // std.debug.print("{s}\n", .{lib_unit_tests.getEmittedBin().getPath(b)});
        lib_unit_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        lib_unit_tests.linkLibC();
        b.installArtifact(lib_unit_tests);

        // b.getInstallStep().dependOn(&b.addInstallArtifact(lib_unit_tests, .{
        //     .dest_dir = .{ .override = .{ .custom = "bin" } },
        //     // .dest_sub_path = "tests",
        // }).step);

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
        const test_exe_step = b.step("test-exe", "Build unit tests");
        test_exe_step.dependOn(&lib_unit_tests.step);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        // test_step.dependOn(&run_exe_unit_tests.step);
    }
}
