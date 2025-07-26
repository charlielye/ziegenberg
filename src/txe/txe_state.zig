const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const proto = @import("../protocol/package.zig");
const ContractAbi = @import("../nargo/contract.zig").ContractAbi;
const call_state = @import("call_state.zig");
const debug_var = @import("../bvm/debug_variable_provider.zig");

pub const TxeState = struct {
    allocator: std.mem.Allocator,

    // Block and chain data.
    version: F,
    chain_id: F,
    block_number: u32,
    timestamp: u64,

    // Contract data.
    contract_artifact_cache: *std.AutoHashMap(F, ContractAbi),
    contract_instance_cache: *std.AutoHashMap(proto.AztecAddress, proto.ContractInstance),

    // Account data.
    accounts: *std.AutoHashMap(proto.AztecAddress, proto.CompleteAddress),

    // Call state stack (bottom VM is at index 0, increases up the stack)
    vm_state_stack: std.ArrayList(*call_state.CallState),

    pub const CHAIN_ID = 1;
    pub const ROLLUP_VERSION = 1;
    pub const GENESIS_TIMESTAMP = 1767225600;
    pub const AZTEC_SLOT_DURATION = 36;

    pub fn init(allocator: std.mem.Allocator) !TxeState {
        // Create global state components
        const contract_artifact_cache = try allocator.create(std.AutoHashMap(F, ContractAbi));
        contract_artifact_cache.* = std.AutoHashMap(F, ContractAbi).init(allocator);

        const contract_instance_cache = try allocator.create(std.AutoHashMap(proto.AztecAddress, proto.ContractInstance));
        contract_instance_cache.* = std.AutoHashMap(proto.AztecAddress, proto.ContractInstance).init(allocator);

        const accounts = try allocator.create(std.AutoHashMap(proto.AztecAddress, proto.CompleteAddress));
        accounts.* = std.AutoHashMap(proto.AztecAddress, proto.CompleteAddress).init(allocator);

        var txe = TxeState{
            .allocator = allocator,
            .version = F.one,
            .chain_id = F.one,
            .block_number = 0,
            .timestamp = TxeState.GENESIS_TIMESTAMP,
            .contract_artifact_cache = contract_artifact_cache,
            .contract_instance_cache = contract_instance_cache,
            .accounts = accounts,
            .vm_state_stack = std.ArrayList(*call_state.CallState).init(allocator),
        };

        // Create initial state on heap and push to stack
        const initial_state = try allocator.create(call_state.CallState);
        initial_state.* = call_state.CallState.init(allocator);
        try txe.vm_state_stack.append(initial_state);

        return txe;
    }

    /// Get the current (top) call state
    pub fn getCurrentState(self: *TxeState) *call_state.CallState {
        // The current state is always the last one on the stack
        return self.vm_state_stack.items[self.vm_state_stack.items.len - 1];
    }

    /// Push a new call state onto the stack
    pub fn pushState(self: *TxeState, state: *call_state.CallState) !void {
        try self.vm_state_stack.append(state);
    }

    /// Pop the current call state from the stack
    pub fn popState(self: *TxeState) *call_state.CallState {
        return self.vm_state_stack.pop() orelse unreachable;
    }

    pub fn deinit(self: *TxeState) void {
        // Free all states in the stack
        for (self.vm_state_stack.items) |state| {
            state.deinit();
            self.allocator.destroy(state);
        }
        self.vm_state_stack.deinit();

        // Deinit components
        self.contract_artifact_cache.deinit();
        self.allocator.destroy(self.contract_artifact_cache);

        self.contract_instance_cache.deinit();
        self.allocator.destroy(self.contract_instance_cache);

        self.accounts.deinit();
        self.allocator.destroy(self.accounts);
    }

    /// Get a debug variable provider for this TxeState
    pub fn getDebugVariableProvider(self: *TxeState) debug_var.DebugVariableProvider {
        return .{
            .context = self,
            .getScopesFn = getScopesImpl,
            .getVariablesFn = getVariablesImpl,
        };
    }

    fn getScopesImpl(context: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]debug_var.DebugScope {
        const self = @as(*TxeState, @ptrCast(@alignCast(context)));

        var scopes = std.ArrayList(debug_var.DebugScope).init(allocator);
        defer scopes.deinit();

        // We'll use frame_id as a variable reference base
        // Frame ID 0 -> variables reference 1000
        // Frame ID 1 -> variables reference 2000, etc.
        const var_ref_base = (frame_id + 1) * 1000;

        // Add TXE Global State scope
        try scopes.append(.{
            .name = "TXE Global State",
            .presentationHint = "globals",
            .variablesReference = var_ref_base + 1,
            .expensive = false,
        });

        // Add scopes for each CallState in the stack (bottom to top)
        for (self.vm_state_stack.items, 0..) |state, index| {
            const vm_index: u32 = @intCast(index);  // Bottom VM is 0, increases up the stack
            const scope_name = if (state.contract_abi) |abi|
                try std.fmt.allocPrint(allocator, "[{}] VM State: {s}", .{ vm_index, abi.name })
            else
                try std.fmt.allocPrint(allocator, "[{}] VM State", .{vm_index});

            try scopes.append(.{
                .name = scope_name,
                .presentationHint = if (vm_index == 0) "locals" else "arguments",
                .variablesReference = var_ref_base + 2 + vm_index,
                .expensive = false,
            });
        }

        return scopes.toOwnedSlice();
    }

    fn getVariablesImpl(context: *anyopaque, allocator: std.mem.Allocator, variables_reference: u32) anyerror![]debug_var.DebugVariable {
        const self = @as(*TxeState, @ptrCast(@alignCast(context)));

        var variables = std.ArrayList(debug_var.DebugVariable).init(allocator);
        defer variables.deinit();

        // Determine which scope this is based on variables_reference
        const scope_type = variables_reference % 1000;

        if (scope_type == 1) {
            // TXE Global State
            try variables.append(.{
                .name = "block_number",
                .value = try std.fmt.allocPrint(allocator, "{}", .{self.block_number}),
                .type = "u32",
            });

            try variables.append(.{
                .name = "timestamp",
                .value = try std.fmt.allocPrint(allocator, "{}", .{self.timestamp}),
                .type = "u64",
            });

            // try variables.append(.{
            //     .name = "chain_id",
            //     .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{self.chain_id.to_int()}),
            //     .type = "Field",
            // });

            // try variables.append(.{
            //     .name = "version",
            //     .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{self.version.to_int()}),
            //     .type = "Field",
            // });

            // Accounts (list of addresses)
            const accounts_count = self.accounts.count();
            try variables.append(.{
                .name = "accounts",
                .value = try std.fmt.allocPrint(allocator, "{} accounts", .{accounts_count}),
                .type = "HashMap",
                .variablesReference = variables_reference + 100, // Sub-reference for account list
            });
        } else if (scope_type >= 2 and scope_type < 100) {
            // Call State at specific depth (2 = current, 3 = parent, etc.)
            const call_depth = scope_type - 2;

            // Get the CallState at the requested index from the stack
            if (call_depth < self.vm_state_stack.items.len) {
                const state = self.vm_state_stack.items[@intCast(call_depth)];
                try appendCallStateVariables(&variables, allocator, state, variables_reference);
            }
        } else if (scope_type == 101) {
            // Account list sub-reference (from clicking on "accounts")
            var iter = self.accounts.iterator();
            var index: usize = 0;
            while (iter.next()) |entry| {
                const name = try std.fmt.allocPrint(allocator, "[{}]", .{index});
                try variables.append(.{
                    .name = name,
                    .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{entry.key_ptr.value.to_int()}),
                    .type = "AztecAddress",
                });
                index += 1;
            }
        } else if (scope_type >= 200 and scope_type < 300) {
            // Sub-references for CallState collections
            const sub_type = scope_type % 100;
            const call_depth = (scope_type / 100 - 2);

            // Get the CallState at the requested index from the stack
            if (call_depth < self.vm_state_stack.items.len) {
                const state = self.vm_state_stack.items[@intCast(call_depth)];
                if (sub_type == 0) {
                    // Storage writes
                    var iter = state.storage_writes.iterator();
                    var index: usize = 0;
                    while (iter.next()) |entry| {
                        const name = try std.fmt.allocPrint(allocator, "[{}] {s}", .{ index, entry.key_ptr.* });
                        const value_str = if (entry.value_ptr.*.len > 0)
                            try std.fmt.allocPrint(allocator, "[{}]F = 0x{x:0>64}...", .{ entry.value_ptr.*.len, entry.value_ptr.*[0].to_int() })
                        else
                            try std.fmt.allocPrint(allocator, "[0]F", .{});
                        try variables.append(.{
                            .name = name,
                            .value = value_str,
                            .type = "[]F",
                        });
                        index += 1;
                    }
                } else if (sub_type == 1) {
                    // Nullifiers
                    for (state.nullifiers.items, 0..) |nullifier, i| {
                        const name = try std.fmt.allocPrint(allocator, "[{}]", .{i});
                        try variables.append(.{
                            .name = name,
                            .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{nullifier.to_int()}),
                            .type = "Field",
                        });
                    }
                }
            }
        }

        return variables.toOwnedSlice();
    }

    fn appendCallStateVariables(
        variables: *std.ArrayList(debug_var.DebugVariable),
        allocator: std.mem.Allocator,
        state: *call_state.CallState,
        base_ref: u32,
    ) !void {
        try variables.append(.{
            .name = "contract_address",
            .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{state.contract_address.value.to_int()}),
            .type = "AztecAddress",
        });

        try variables.append(.{
            .name = "msg_sender",
            .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{state.msg_sender.value.to_int()}),
            .type = "AztecAddress",
        });

        try variables.append(.{
            .name = "function_selector",
            .value = try std.fmt.allocPrint(allocator, "0x{x:0>8}", .{state.function_selector}),
            .type = "u32",
        });

        try variables.append(.{
            .name = "is_static_call",
            .value = if (state.is_static_call) "true" else "false",
            .type = "bool",
        });

        try variables.append(.{
            .name = "side_effect_counter",
            .value = try std.fmt.allocPrint(allocator, "{}", .{state.side_effect_counter}),
            .type = "u32",
        });

        // Number of notes in cache
        const num_notes = state.note_cache.getTotalNoteCount();
        try variables.append(.{
            .name = "num_notes",
            .value = try std.fmt.allocPrint(allocator, "{}", .{num_notes}),
            .type = "usize",
        });

        // Number of nullifiers
        try variables.append(.{
            .name = "num_nullifiers",
            .value = try std.fmt.allocPrint(allocator, "{}", .{state.nullifiers.items.len}),
            .type = "usize",
        });

        // Number of storage writes
        try variables.append(.{
            .name = "num_storage_writes",
            .value = try std.fmt.allocPrint(allocator, "{}", .{state.storage_writes.count()}),
            .type = "usize",
        });

        // Number of private logs
        try variables.append(.{
            .name = "num_private_logs",
            .value = try std.fmt.allocPrint(allocator, "{}", .{state.private_logs.items.len}),
            .type = "usize",
        });

        // Add expandable references for collections if they have items
        if (state.storage_writes.count() > 0) {
            try variables.append(.{
                .name = "storage_writes",
                .value = try std.fmt.allocPrint(allocator, "{} writes", .{state.storage_writes.count()}),
                .type = "StringHashMap",
                .variablesReference = base_ref + 200, // Sub-reference for storage writes
            });
        }

        if (state.nullifiers.items.len > 0) {
            try variables.append(.{
                .name = "nullifiers_list",
                .value = try std.fmt.allocPrint(allocator, "{} nullifiers", .{state.nullifiers.items.len}),
                .type = "ArrayList",
                .variablesReference = base_ref + 201, // Sub-reference for nullifiers
            });
        }
    }
};
