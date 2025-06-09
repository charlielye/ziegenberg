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
    const toml = b.dependency("toml", .{});

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
        lib.root_module.addImport("toml", toml.module("zig-toml"));
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
        exe.root_module.addImport("toml", toml.module("zig-toml"));
        // exe.linkLibC();

        b.installArtifact(exe);
    }

    // List tests.
    {
        const list_tests = b.addTest(.{
            .name = "list-tests",
            .root_source_file = b.path("src/lib.zig"),
            .test_runner = .{ .path = b.path("test_list.zig"), .mode = .simple },
            .target = target,
            .optimize = optimize,
        });
        list_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        list_tests.root_module.addImport("toml", toml.module("zig-toml"));
        list_tests.linkLibC();
        const list_tests_install = b.addInstallArtifact(list_tests, .{});

        const run_list_tests = b.addRunArtifact(list_tests);
        run_list_tests.step.dependOn(&list_tests_install.step);

        const run_list_tests_step = b.step("list-tests", "List unit tests");
        run_list_tests_step.dependOn(&run_list_tests.step);
    }

    // Unit tests.
    {
        // Creates a step to build the unit tests. This only builds the test executable but does not run it.
        const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
        const lib_unit_tests = b.addTest(.{
            .name = "tests",
            .root_source_file = b.path("src/lib.zig"),
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
            .target = target,
            .optimize = optimize,
            .filters = test_filters,
        });
        lib_unit_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        lib_unit_tests.root_module.addImport("toml", toml.module("zig-toml"));
        lib_unit_tests.linkLibC();

        // A step to install the unit tests into zig-out/bin. Depends on them being built.
        const lib_unit_tests_install = b.addInstallArtifact(lib_unit_tests, .{});

        // A step to run the unit tests. Depends on them being built.
        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
        run_lib_unit_tests.step.dependOn(&lib_unit_tests.step);
        run_lib_unit_tests.has_side_effects = true;
        if (b.args) |args| {
            run_lib_unit_tests.addArgs(args);
        }

        // A command step to just build and install test executable.
        const test_exe_step = b.step("test-exe", "Build unit tests");
        test_exe_step.dependOn(&lib_unit_tests_install.step);

        // A command step to build and run the unit tests.
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
    }
}
