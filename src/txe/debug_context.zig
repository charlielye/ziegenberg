const std = @import("std");
const debug_var = @import("../bvm/debug_variable_provider.zig");
const TxeState = @import("txe_state.zig").TxeState;
const F = @import("../bn254/fr.zig").Fr;

pub const TxeDebugContext = struct {
    txe_state: *TxeState,

    pub fn init(txe_state: *TxeState) TxeDebugContext {
        return .{ .txe_state = txe_state };
    }

    /// Get a debug variable provider for this TxeDebugContext
    pub fn getDebugVariableProvider(self: *TxeDebugContext) debug_var.DebugVariableProvider {
        return .{
            .context = self,
            .getScopesFn = getScopesImpl,
            .getVariablesFn = getVariablesImpl,
        };
    }

    fn getScopesImpl(context: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]debug_var.DebugScope {
        const self = @as(*TxeDebugContext, @ptrCast(@alignCast(context)));

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
        for (self.txe_state.vm_state_stack.items, 0..) |state, index| {
            const vm_index: u32 = @intCast(index); // Bottom VM is 0, increases up the stack
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
        const self = @as(*TxeDebugContext, @ptrCast(@alignCast(context)));

        var variables = std.ArrayList(debug_var.DebugVariable).init(allocator);
        defer variables.deinit();

        // Determine which scope this is based on variables_reference
        const scope_type = variables_reference % 1000;

        if (scope_type == 1) {
            // TXE Global State
            try variables.append(.{
                .name = "block_number",
                .value = try std.fmt.allocPrint(allocator, "{}", .{self.txe_state.block_number}),
                .type = "u32",
            });

            try variables.append(.{
                .name = "timestamp",
                .value = try std.fmt.allocPrint(allocator, "{}", .{self.txe_state.timestamp}),
                .type = "u64",
            });

            // try variables.append(.{
            //     .name = "chain_id",
            //     .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{self.txe_state.chain_id.to_int()}),
            //     .type = "Field",
            // });

            // try variables.append(.{
            //     .name = "version",
            //     .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{self.txe_state.version.to_int()}),
            //     .type = "Field",
            // });

            // Accounts (list of addresses)
            const accounts_count = self.txe_state.accounts.count();
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
            if (call_depth < self.txe_state.vm_state_stack.items.len) {
                const state = self.txe_state.vm_state_stack.items[@intCast(call_depth)];
                try appendCallStateVariables(&variables, allocator, state, variables_reference);
            }
        } else if (scope_type == 101) {
            // Account list sub-reference (from clicking on "accounts")
            var iter = self.txe_state.accounts.iterator();
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
            if (call_depth < self.txe_state.vm_state_stack.items.len) {
                const state = self.txe_state.vm_state_stack.items[@intCast(call_depth)];
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
        state: *@import("call_state.zig").CallState,
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
