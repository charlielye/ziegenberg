const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // _ = b.addModule("bn254", .{
    //     .root_source_file = b.path("src/bn254/g1.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });

    const lib = b.addStaticLibrary(.{
        .name = "ziegenberg",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        // .code_model = std.builtin.CodeModel.large,
    });
    lib.bundle_compiler_rt = true;

    // zig_poseidon dependency. Leaving in as an example of how to add a dependency.
    // const poseidon = b.dependency("zig_poseidon", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // lib.root_module.addImport("poseidon", poseidon.module("poseidon"));
    // lib.linkLibrary(poseidon.artifact("zig-poseidon"));

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Leaving in as an example of how to link to a dependency.
    // lib_unit_tests.root_module.addImport("poseidon", poseidon.module("poseidon"));
    // lib_unit_tests.linkLibrary(poseidon.artifact("zig-poseidon"));

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
