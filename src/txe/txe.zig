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

pub const ExecuteOptions = struct {
    calldata_path: ?[]const u8 = null,
    show_stats: bool = false,
    show_trace: bool = false,
    debug_mode: bool = false,
};

pub const Txe = struct {
    allocator: std.mem.Allocator,
    fc_handler: Dispatcher,
    // Debug context (optional) - passed to all nested VM executions
    // debug_ctx: ?*DebugContext = null,
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

        // var t = try std.time.Timer.start();
        // std.debug.print("Initing...\n", .{});

        // Create debug context if needed
        // var debug_ctx_storage: ?DebugContext = null;
        // defer if (debug_ctx_storage) |*ctx| ctx.deinit();

        // var debug_ctx_ptr: ?*DebugContext = null;
        // if (options.debug_mode or options.show_trace) {
        //     const mode: DebugMode = if (options.debug_mode) .step_by_line else .trace;
        //     debug_ctx_storage = DebugContext.init(allocator, mode);
        //     debug_ctx_ptr = &debug_ctx_storage.?;

        //     // Load debug symbols if available
        //     if (debug_ctx_ptr) |ctx| {
        //         const function_name = if (std.mem.indexOf(u8, artifact_path, "test") != null) "test" else "main";
        //         ctx.loadDebugSymbols(artifact_path, function_name) catch |err| {
        //             std.debug.print("Warning: Could not load debug symbols: {}\n", .{err});
        //         };
        //     }
        // }

        // std.debug.print("Init time: {}us\n", .{t.read() / 1000});

        std.debug.print("Executing...\n", .{});
        // t.reset();

        var t = try std.time.Timer.start();

        // Create and execute the circuit VM
        var circuit_vm = try cvm.CircuitVm(Dispatcher).init(allocator, &program, calldata, &self.fc_handler);
        defer circuit_vm.deinit();

        // Execute with debug context
        const result = circuit_vm.executeVm(0, .{ .debug_ctx = null });
        std.debug.print("time taken: {}us\n", .{t.read() / 1000});

        result catch |err| {
            std.debug.print("Execution failed: {}\n", .{err});

            // If this was a Brillig trap, show debug info
            if (err == error.Trapped) {
                std.debug.print("\nExecution Stack Trace:\n", .{});

                // Walk the CallState chain if we have access to Txe
                // Always try to walk the chain, even if parent is null (we might be at root)
                {
                    // We have nested calls, walk the chain
                    var level: usize = 0;
                    var current_state: ?*CallState = self.impl.state.current_state;

                    while (current_state) |state| : (current_state = state.parent) {
                        std.debug.print("\n[{}] ", .{level});

                        if (state.contract_abi) |abi| {
                            std.debug.print("Contract: {s} @ {x}\n", .{
                                abi.name,
                                state.contract_address,
                            });
                            std.debug.print("    Function: selector {x}\n", .{state.function_selector});

                            // Try to find function name
                            for (abi.functions) |func| {
                                if (func.selector == state.function_selector) {
                                    std.debug.print("    Function name: {s}\n", .{func.name});
                                    break;
                                }
                            }

                            // Show source location if we have error context for this level
                            const error_ctx = state.execution_error;

                            if (error_ctx != null) {
                                std.debug.print("    Source location:\n", .{});

                                // Find the function name for this selector
                                var func_name: []const u8 = "unknown";
                                for (abi.functions) |f| {
                                    if (f.selector == state.function_selector) {
                                        func_name = f.name;
                                        break;
                                    }
                                }

                                // Always use the test artifact path which contains all debug symbols
                                bvm.debug_info.lookupSourceLocation(allocator, artifact_path, func_name, error_ctx.?.pc) catch |lookup_err| {
                                    std.debug.print("      Could not resolve: {}\n", .{lookup_err});
                                };
                            }
                        } else {
                            // Top-level test execution
                            bvm.debug_info.lookupSourceLocation(allocator, artifact_path, "", circuit_vm.brillig_error_context.?.pc) catch |lookup_err| {
                                std.debug.print("      Could not resolve: {}\n", .{lookup_err});
                            };
                        }

                        level += 1;
                    }
                }
            }

            return err;
        };
    }
};
