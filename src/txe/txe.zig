const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const bvm = @import("../bvm/package.zig");
const cvm = @import("../cvm/package.zig");
const TxeDispatcher = @import("dispatcher.zig").TxeDispatcher;
const TxeImpl = @import("txe_impl.zig").TxeImpl;
const nargo_toml = @import("../nargo/nargo_toml.zig");
const nargo_artifact = @import("../nargo/artifact.zig");
const nargo = @import("../nargo/package.zig");
const CallState = @import("call_state.zig").CallState;
const DebugMode = @import("../bvm/debug_context.zig").DebugMode;
const TxeDebugContext = @import("txe_debug_context.zig").TxeDebugContext;
const TxeState = @import("txe_state.zig").TxeState;

pub const ExecuteOptions = struct {
    calldata_path: ?[]const u8 = null,
    show_stats: bool = false,
    show_trace: bool = false,
};

pub const Txe = struct {
    allocator: std.mem.Allocator,
    txe_state: TxeState,
    txe_debug_ctx: ?*TxeDebugContext = null,
    txe_impl: TxeImpl,
    txe_dispatcher: TxeDispatcher,

    pub fn init(allocator: std.mem.Allocator, contract_artifacts_path: []const u8, debug: bool) !*Txe {
        const txe = try allocator.create(Txe);
        txe.allocator = allocator;
        txe.txe_state = try TxeState.init(allocator);
        txe.txe_debug_ctx = null;
        if (debug) {
            txe.txe_debug_ctx = try TxeDebugContext.init(allocator, &txe.txe_state);
        }
        txe.txe_impl = try TxeImpl.init(
            allocator,
            contract_artifacts_path,
            &txe.txe_state,
            txe.txe_debug_ctx,
        );
        txe.txe_dispatcher = try TxeDispatcher.init(allocator, &txe.txe_impl);

        // Bit circular, but the txe impl wants the same foreign call handler for its nested vms.
        txe.txe_impl.fc_handler = &txe.txe_dispatcher;

        return txe;
    }

    pub fn deinit(self: *Txe) void {
        self.txe_dispatcher.deinit();
        self.txe_impl.deinit();
        if (self.txe_debug_ctx) |ctx| ctx.deinit();
        self.txe_state.deinit();
        self.allocator.destroy(self);
    }

    pub fn execute(self: *Txe, artifact_path: []const u8, options: ExecuteOptions) !void {
        // Init calldata to empty slice.
        var calldata: []F = &[_]F{};

        // Load the bytecode from the artifact, and calldata from Prover.toml (unless overridden).
        const artifact = try nargo_artifact.ArtifactAbi.load(self.allocator, artifact_path);
        const bytecode = try artifact.getBytecode(self.allocator);
        const program = try cvm.io.deserialize(self.allocator, bytecode);

        if (options.calldata_path) |path| {
            calldata = try nargo.calldata.loadCalldataFromProverToml(self.allocator, &artifact, path);
        }

        std.debug.assert(program.functions.len == 1);
        std.debug.print("Calldata consists of {} elements.\n", .{calldata.len});

        // Create debug context if debug mode is enabled. TODO: cli arg to enum?
        if (self.txe_debug_ctx) |ctx| {
            const display_name = if (artifact.names) |names| names[0] else "";
            ctx.onVmEnter(try artifact.getDebugInfo(self.allocator), display_name);
        }

        // Create and init circuit VM.
        var t = try std.time.Timer.start();
        std.debug.print("Initing...\n", .{});
        var circuit_vm = try cvm.CircuitVm.init(
            self.allocator,
            &program,
            calldata,
            self.txe_dispatcher.fcDispatcher(),
            if (self.txe_debug_ctx) |ctx| ctx.brilligVmHooks() else null,
        );
        defer circuit_vm.deinit();
        std.debug.print("Init time: {}us\n", .{t.read() / 1000});

        // Execute.
        std.debug.print("Executing...\n", .{});
        t.reset();
        defer std.debug.print("time taken: {}us\n", .{t.read() / 1000});
        circuit_vm.executeVm(0) catch |err| {
            if (circuit_vm.brillig_error_context != null) {
                self.txe_state.getCurrentState().execution_error = circuit_vm.brillig_error_context;
            }
            std.debug.print("Execution failed: {}\n", .{err});
            try self.dumpStackTrace(&artifact);
            return err;
        };

        if (self.txe_debug_ctx) |ctx| {
            ctx.onVmExit();
        }
    }

    fn dumpStackTrace(self: *Txe, artifact: *const nargo.ArtifactAbi) !void {
        // If this was a Brillig trap, show debug info.
        std.debug.print("\nExecution Stack Trace:\n", .{});

        const depth = self.txe_state.vm_state_stack.items.len;

        // We have nested vm instances, walk the stack from bottom to top
        for (self.txe_state.vm_state_stack.items, 0..) |state, index| {
            const level = depth - index;
            std.debug.print("\n[{}] ", .{level - 1});

            var debug_info: *const nargo.DebugInfo = undefined;
            if (state.contract_abi) |abi| {
                std.debug.print("Contract: {s} @ {x}\n", .{
                    abi.name,
                    state.contract_address,
                });
                std.debug.print("    Function: selector {x}\n", .{state.function_selector});

                const f = try abi.getFunctionBySelector(state.function_selector);
                std.debug.print("    Function name: {s}\n", .{f.name});

                // Return the debug info for this function, passing the contract's file_map
                debug_info = try f.getDebugInfo(self.allocator, abi.file_map);
            } else {
                // Top-level execution.
                debug_info = try artifact.getDebugInfo(self.allocator);
            }
            const error_ctx = state.execution_error orelse return error.NoExecutionError;

            // const error_ctx = circuit_vm.brillig_error_context orelse return error.NoExecutionError;
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
};
