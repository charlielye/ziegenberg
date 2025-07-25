const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const bvm = @import("../bvm/package.zig");
const cvm = @import("../cvm/package.zig");
const Dispatcher = @import("dispatcher.zig").Dispatcher;
const TxeImpl = @import("txe_impl.zig").TxeImpl;
const nargo_toml = @import("../nargo/nargo_toml.zig");
const nargo_artifact = @import("../nargo/artifact.zig");
const nargo = @import("../nargo/package.zig");
const CallState = @import("call_state.zig").CallState;
const DebugContext = @import("../bvm/debug_context.zig").DebugContext;
const DebugMode = @import("../bvm/debug_context.zig").DebugMode;

pub const ExecuteOptions = struct {
    calldata_path: ?[]const u8 = null,
    show_stats: bool = false,
    show_trace: bool = false,
    debug_mode: bool = false,
    debug_dap: bool = false,
};

pub const Txe = struct {
    allocator: std.mem.Allocator,
    fc_handler: Dispatcher,
    impl: TxeImpl,

    pub fn init(allocator: std.mem.Allocator, contract_artifacts_path: []const u8) !*Txe {
        const txe = try allocator.create(Txe);
        txe.allocator = allocator;
        txe.impl = try TxeImpl.init(allocator, contract_artifacts_path);
        txe.fc_handler = try Dispatcher.init(allocator, &txe.impl);

        // Bit circular, but the txe impl wants the same foreign call handler for its nested vms.
        txe.impl.fc_handler = &txe.fc_handler;

        return txe;
    }

    pub fn deinit(self: *Txe) void {
        self.fc_handler.deinit();
        self.impl.deinit();
        self.allocator.destroy(self);
    }

    pub fn execute(self: *Txe, artifact_path: []const u8, options: ExecuteOptions) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        // Init calldata to empty slice.
        var calldata: []F = &[_]F{};
        var program: cvm.io.Program = undefined;

        // Load the bytecode from the artifact, and calldata from Prover.toml (unless overridden).
        const artifact = try nargo_artifact.ArtifactAbi.load(allocator, artifact_path);
        const bytecode = try artifact.getBytecode(allocator);
        program = try cvm.io.deserialize(allocator, bytecode);

        if (options.calldata_path) |path| {
            calldata = try nargo.calldata.loadCalldataFromProverToml(allocator, &artifact, path);
        }

        std.debug.assert(program.functions.len == 1);
        std.debug.print("Calldata consists of {} elements.\n", .{calldata.len});

        var t = try std.time.Timer.start();
        std.debug.print("Initing...\n", .{});
        // Create and execute the circuit VM
        var circuit_vm = try cvm.CircuitVm(Dispatcher).init(allocator, &program, calldata, &self.fc_handler);
        defer circuit_vm.deinit();
        std.debug.print("Init time: {}us\n", .{t.read() / 1000});

        // Create debug context if debug mode is enabled. TODO: cli arg to enum?
        if (options.debug_dap) {
            var provider = self.impl.state.getDebugVariableProvider();
            self.impl.debug_ctx = try DebugContext.initWithVariableProvider(allocator, .dap, &provider);
        } else if (options.debug_mode) {
            var provider = self.impl.state.getDebugVariableProvider();
            self.impl.debug_ctx = try DebugContext.initWithVariableProvider(allocator, .step_by_line, &provider);
        }
        // Register the initial VM with its debug info.
        if (self.impl.debug_ctx) |*ctx| {
            const display_name = if (artifact.names) |names| names[0] else "";
            ctx.onVmEnter(try artifact.getDebugInfo(allocator), display_name[0..16]);
        }

        std.debug.print("Executing...\n", .{});
        t.reset();
        defer std.debug.print("time taken: {}us\n", .{t.read() / 1000});

        circuit_vm.executeVm(0, .{ .debug_ctx = if (self.impl.debug_ctx) |*ctx| ctx else null }) catch |err| {
            std.debug.print("Execution failed: {}\n", .{err});

            // If this was a Brillig trap, show debug info.
            std.debug.print("\nExecution Stack Trace:\n", .{});

            var level: usize = 0;
            var current_state: ?*CallState = self.impl.state.current_state;
            while (current_state) |state| : (current_state = state.parent) {
                level += 1;
            }

            // We have nested vm instances, walk the chain.
            current_state = self.impl.state.current_state;
            while (current_state) |state| : ({
                current_state = state.parent;
                level -= 1;
            }) {
                std.debug.print("\n[{}] ", .{level - 1});

                if (state.contract_abi) |abi| {
                    std.debug.print("Contract: {s} @ {x}\n", .{
                        abi.name,
                        state.contract_address,
                    });
                    std.debug.print("    Function: selector {x}\n", .{state.function_selector});

                    const f = try abi.getFunctionBySelector(state.function_selector);
                    std.debug.print("    Function name: {s}\n", .{f.name});

                    const error_ctx = state.execution_error orelse return error.NoExecutionError;
                    std.debug.print("    Source location:\n", .{});

                    // Pass the contract's file_map
                    const fn_debug_info = try f.getDebugInfo(allocator, abi.file_map);

                    // Print source location for current PC (top of stack).
                    std.debug.print("      [{d}] PC: {}\n", .{ error_ctx.callstack.len, error_ctx.pc });
                    fn_debug_info.printSourceLocation(error_ctx.pc, 2);

                    // Print source locations for callstack entries from top to bottom.
                    var i: usize = error_ctx.callstack.len;
                    while (i > 0) : (i -= 1) {
                        const return_addr = error_ctx.callstack[i - 1];
                        const pc = return_addr - 1;
                        std.debug.print("      [{d}] PC: {}\n", .{ i - 1, pc });
                        fn_debug_info.printSourceLocation(pc, 2);
                    }
                } else {
                    // Top-level execution.
                    const debug_info = try artifact.getDebugInfo(allocator);
                    const error_ctx = circuit_vm.brillig_error_context orelse return error.NoExecutionError;
                    // Print source location for current PC
                    std.debug.print("Source location:\n", .{});
                    std.debug.print("      [{d}] PC: {}\n", .{ error_ctx.callstack.len, error_ctx.pc });
                    debug_info.printSourceLocation(error_ctx.pc, 2);

                    // Print callstack from top to bottom
                    var i: usize = error_ctx.callstack.len;
                    while (i > 0) : (i -= 1) {
                        const return_addr = error_ctx.callstack[i - 1];
                        const pc = return_addr - 1;
                        std.debug.print("      [{d}] PC: {}\n", .{ i - 1, pc });
                        debug_info.printSourceLocation(pc, 2);
                    }

                    std.debug.print("Revert data: \n", .{});
                    for (error_ctx.return_data, 0..) |data, j| {
                        std.debug.print("  [{d:0>2}]: 0x{x:0>64}\n", .{ j, data });
                    }
                }
            }

            return err;
        };
    }
};
