const std = @import("std");
const io = @import("io.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const nargo = @import("../nargo/package.zig");
const nargo_toml = @import("../nargo/nargo_toml.zig");
const prover_toml = @import("../nargo/prover_toml.zig");
const nargo_artifact = @import("../nargo/artifact.zig");
const toml = @import("toml");
const bvm = @import("../bvm/package.zig");
const CircuitVm = @import("circuit_vm.zig").CircuitVm;
const DebugContext = @import("../bvm/debug_context.zig").DebugContext;
const DebugMode = @import("../bvm/debug_context.zig").DebugMode;

pub const ExecuteOptions = struct {
    // If null, the current working directory is used.
    project_path: ?[]const u8 = null,
    // Absolute or relative to project_path.
    artifact_path: ?[]const u8 = null,
    witness_path: ?[]const u8 = null,
    bytecode_path: ?[]const u8 = null,
    calldata_path: ?[]const u8 = null,
    show_stats: bool = false,
    show_trace: bool = false,
    debug_mode: bool = false,
    debug_dap: bool = false,
    binary: bool = false,
};

pub fn execute(options: ExecuteOptions) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const project_path = options.project_path orelse try std.fs.cwd().realpathAlloc(allocator, ".");

    // Load Nargo.toml.
    const nt_path = try std.fmt.allocPrint(allocator, "{s}/Nargo.toml", .{project_path});
    const nt = nargo_toml.load(allocator, nt_path) catch null;
    const name = if (nt) |t| t.package.name else std.fs.path.basename(project_path);

    const artifact_path = if (options.artifact_path) |path|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, path })
    else
        try std.fmt.allocPrint(allocator, "{s}/target/{s}.json", .{ project_path, name });

    // Init calldata to empty slice.
    var calldata: []Fr = &[_]Fr{};
    var program: io.Program = undefined;

    if (options.bytecode_path) |path| {
        std.debug.print("Loading bytecode from {s}...\n", .{path});
        // If bytecode path is provided, load bytecode from it, and optionally load calldata from given path if given.
        program = try io.load(allocator, path);

        if (options.calldata_path) |calldata_path| {
            const artifact = try nargo_artifact.ArtifactAbi.load(allocator, artifact_path);
            const pt_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, calldata_path });
            calldata = try nargo.calldata.loadCalldataFromProverToml(allocator, &artifact, pt_path);
        }
    } else {
        // Otherwise, load the bytecode from the artifact, and calldata from Prover.toml (unless overridden).
        const artifact = try nargo_artifact.ArtifactAbi.load(allocator, artifact_path);
        const bytecode = try artifact.getBytecode(allocator);
        program = try io.deserialize(allocator, bytecode);

        if (options.calldata_path) |path| {
            const pt_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, path });
            calldata = try nargo.calldata.loadCalldataFromProverToml(allocator, &artifact, pt_path);
        } else {
            // If default Prover.toml doesn't exist we continue with empty calldata.
            const pt_path = try std.fmt.allocPrint(allocator, "{s}/Prover.toml", .{project_path});
            calldata = nargo.calldata.loadCalldataFromProverToml(allocator, &artifact, pt_path) catch |err| switch (err) {
                error.FileNotFound => calldata,
                else => return err,
            };
        }
    }

    std.debug.assert(program.functions.len == 1);
    std.debug.print("Calldata consists of {} elements.\n", .{calldata.len});

    // Init.
    var t = try std.time.Timer.start();
    std.debug.print("Initing...\n", .{});
    var fc_handler = try bvm.foreign_call.Dispatcher.init(allocator);
    defer fc_handler.deinit();
    var circuit_vm = try CircuitVm(bvm.foreign_call.Dispatcher).init(allocator, &program, calldata, &fc_handler);
    defer circuit_vm.deinit();
    std.debug.print("Init time: {}us\n", .{t.read() / 1000});

    // Create debug context if debug mode is enabled
    var debug_ctx: ?DebugContext = null;
    if (options.debug_dap) {
        debug_ctx = try DebugContext.init(allocator, .dap);
    } else if (options.debug_mode) {
        debug_ctx = try DebugContext.init(allocator, .step_by_line);
    }
    defer if (debug_ctx) |*ctx| ctx.deinit();

    // Register the initial VM with its debug info if using artifacts
    if (debug_ctx != null and options.artifact_path != null) {
        const artifact = try nargo_artifact.ArtifactAbi.load(allocator, artifact_path);
        const debug_info = try artifact.getDebugInfo(allocator);
        debug_ctx.?.onVmEnter(debug_info);
    }

    // Execute.
    std.debug.print("Executing...\n", .{});
    t.reset();
    const result = circuit_vm.executeVm(0, .{
        .show_trace = options.show_trace,
        .debug_ctx = if (debug_ctx) |*ctx| ctx else null,
    });
    std.debug.print("time taken: {}us\n", .{t.read() / 1000});
    result catch |err| {
        std.debug.print("Execution failed: {}\n", .{err});
        return err;
    };

    if (options.witness_path) |witness_path| {
        const file_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, witness_path });
        const file = try std.fs.cwd().createFile(file_name, .{ .truncate = true });
        defer file.close();
        std.debug.print("Writing witnesses to {s}\n", .{file_name});
        // Create a writer for the file that gzips the output.
        var compressor = try std.compress.gzip.compressor(file.writer(), .{});
        // Write the witnesses to the file.
        try circuit_vm.witnesses.writeWitnesses(options.binary, compressor.writer());
        try compressor.finish();
    } else {
        try circuit_vm.witnesses.printWitnesses(options.binary);
    }
}
