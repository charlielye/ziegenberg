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

    // Call state.
    current_state: *call_state.CallState,

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
            .current_state = undefined,
        };

        // Create initial state on heap
        const initial_state = try allocator.create(call_state.CallState);
        initial_state.* = call_state.CallState.init(allocator);
        txe.current_state = initial_state;

        return txe;
    }

    pub fn deinit(self: *TxeState) void {
        // Free state chain.
        var state = self.current_state;
        while (true) {
            const parent = state.parent;
            state.deinit();
            if (parent == null) break;
            state = parent.?;
        }

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
        _ = context; // We don't need the context for scopes
        
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

        // Add Current Call State scope
        try scopes.append(.{
            .name = "Current Call State",
            .presentationHint = "locals",
            .variablesReference = var_ref_base + 2,
            .expensive = false,
        });

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

            try variables.append(.{
                .name = "chain_id",
                .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{self.chain_id.to_int()}),
                .type = "Field",
            });

            try variables.append(.{
                .name = "version",
                .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{self.version.to_int()}),
                .type = "Field",
            });

            // Accounts (list of addresses)
            const accounts_count = self.accounts.count();
            try variables.append(.{
                .name = "accounts",
                .value = try std.fmt.allocPrint(allocator, "{} accounts", .{accounts_count}),
                .type = "HashMap",
                .variablesReference = variables_reference + 100, // Sub-reference for account list
            });
        } else if (scope_type == 2) {
            // Current Call State
            const current_state = self.current_state;

            try variables.append(.{
                .name = "contract_address",
                .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{current_state.contract_address.value.to_int()}),
                .type = "AztecAddress",
            });

            try variables.append(.{
                .name = "msg_sender",
                .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{current_state.msg_sender.value.to_int()}),
                .type = "AztecAddress",
            });

            try variables.append(.{
                .name = "function_selector",
                .value = try std.fmt.allocPrint(allocator, "0x{x:0>8}", .{current_state.function_selector}),
                .type = "u32",
            });

            try variables.append(.{
                .name = "is_static_call",
                .value = if (current_state.is_static_call) "true" else "false",
                .type = "bool",
            });

            try variables.append(.{
                .name = "side_effect_counter",
                .value = try std.fmt.allocPrint(allocator, "{}", .{current_state.side_effect_counter}),
                .type = "u32",
            });

            // Number of notes in cache
            const num_notes = current_state.note_cache.getTotalNoteCount();
            try variables.append(.{
                .name = "num_notes",
                .value = try std.fmt.allocPrint(allocator, "{}", .{num_notes}),
                .type = "usize",
            });

            // Number of nullifiers
            try variables.append(.{
                .name = "num_nullifiers",
                .value = try std.fmt.allocPrint(allocator, "{}", .{current_state.nullifiers.items.len}),
                .type = "usize",
            });
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
        }

        return variables.toOwnedSlice();
    }
};
