const std = @import("std");
const debug_var = @import("../bvm/debug_variable_provider.zig");
const TxeState = @import("txe_state.zig").TxeState;
const F = @import("../bn254/fr.zig").Fr;
const bvm = @import("../bvm/package.zig");
const nargo = @import("../nargo/package.zig");

// Scope type constants
const ScopeType = enum(u32) {
    // Global scopes
    txe_global_state = 1,

    // Call state scopes (2-99)
    call_state_base = 2,
    call_state_max = 99,

    // Sub-reference scopes (100+)
    account_list = 101,

    // Call state collection sub-references (200-999)
    // Formula: (display_index + 2) * 100 + collection_type
    call_state_collections_base = 200,
    call_state_collections_max = 999,

    _,
};

// Collection types within a call state
const CollectionType = enum(u32) {
    storage_writes = 0,
    nullifiers = 1,
    private_logs = 2,
    notes = 3,
};

pub const TxeDebugContext = struct {
    allocator: std.mem.Allocator,
    txe_state: *TxeState,
    bvm_debug_ctx: bvm.DebugContext,

    // Calculate variable reference for a collection within a call state
    // Formula: (display_index + 2) * 100 + collection_type
    // This ensures each call state's collections have unique references
    fn calculateCollectionRef(display_index: usize, collection: CollectionType) u32 {
        return @as(u32, @intCast((display_index + 2) * 100 + @intFromEnum(collection)));
    }

    pub fn brilligVmHooks(self: *TxeDebugContext) bvm.brillig_vm.BrilligVmHooks {
        return .{
            .context = self,
            .afterOpcodeFn = afterOpcode,
            .onErrorFn = onError,
            .trackMemoryWriteFn = trackMemoryWrite,
        };
    }

    fn debugVariableProvider(self: *TxeDebugContext) debug_var.DebugVariableProvider {
        return .{
            .context = self,
            .getScopesFn = getScopesImpl,
            .getVariablesFn = getVariablesImpl,
        };
    }

    pub fn init(allocator: std.mem.Allocator, txe_state: *TxeState) !*TxeDebugContext {
        const txe_debug_ctx = try allocator.create(TxeDebugContext);
        txe_debug_ctx.allocator = allocator;
        txe_debug_ctx.txe_state = txe_state;
        txe_debug_ctx.bvm_debug_ctx = try bvm.DebugContext.initWithVariableProvider(
            allocator,
            txe_debug_ctx.debugVariableProvider(),
        );
        return txe_debug_ctx;
    }

    pub fn deinit(self: *TxeDebugContext) void {
        self.bvm_debug_ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn afterOpcode(context: *anyopaque, opcode: bvm.io.BrilligOpcode, vm: *bvm.BrilligVm) bool {
        const self: *TxeDebugContext = @alignCast(@ptrCast(context));
        return bvm.DebugContext.afterOpcode(&self.bvm_debug_ctx, opcode, vm);
    }

    pub fn onError(context: *anyopaque, vm: *bvm.BrilligVm) void {
        const self: *TxeDebugContext = @alignCast(@ptrCast(context));
        bvm.DebugContext.onError(&self.bvm_debug_ctx, vm);
    }

    pub fn trackMemoryWrite(context: *anyopaque, slot: usize, new_value: u256) void {
        const self: *TxeDebugContext = @alignCast(@ptrCast(context));
        bvm.DebugContext.trackMemoryWrite(&self.bvm_debug_ctx, slot, new_value);
    }

    pub fn onVmEnter(
        self: *TxeDebugContext,
        debug_info: *const nargo.DebugInfo,
        display_name: []const u8,
    ) void {
        // TODO: Move vm stack up into this. bvm doesn't know about vm stacks.
        self.bvm_debug_ctx.onVmEnter(debug_info, display_name);
    }

    pub fn onVmExit(self: *TxeDebugContext) void {
        self.bvm_debug_ctx.onVmExit();
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
            .variablesReference = var_ref_base + @intFromEnum(ScopeType.txe_global_state),
            .expensive = false,
        });

        // Add scopes for each CallState in the stack (top to bottom display order)
        const stack_len = self.txe_state.vm_state_stack.items.len;
        var stack_index: usize = stack_len;
        while (stack_index > 0) : (stack_index -= 1) {
            const display_index: u32 = @intCast(stack_index - 1); // bottom = 0, top = stack_len-1
            const state = self.txe_state.vm_state_stack.items[stack_index - 1];
            const scope_name = if (state.contract_abi) |abi|
                try std.fmt.allocPrint(allocator, "[{}] VM State: {s}", .{ display_index, abi.name })
            else
                try std.fmt.allocPrint(allocator, "[{}] VM State", .{display_index});

            try scopes.append(.{
                .name = scope_name,
                .presentationHint = if (display_index == 0) "locals" else "arguments",
                .variablesReference = var_ref_base + @intFromEnum(ScopeType.call_state_base) + display_index,
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

        std.debug.print("DEBUG getVariablesImpl: variables_reference={}, scope_type={}\n", .{ variables_reference, scope_type });

        // Check for individual note expansion first (>= 10000)
        if (variables_reference >= 10000) {
            // Individual note expansion
            // We encoded as: collection_ref + 10000 + note_index
            // For 10303: original collection_ref = 303, note_index = 0
            // For 10304: original collection_ref = 303, note_index = 1
            const base_value = variables_reference - 10000; // Remove the 10000 offset

            // Extract collection reference and note index
            // Since notes collection type = 3, refs end in 3 (203, 303, etc)
            // We need to find the base collection ref
            const collection_hundreds = (base_value / 100) * 100;
            const remainder = base_value % 100;

            // If remainder < 10, it's the collection type + note index
            // E.g., 303 = 300 + 3 (type) + 0 (index)
            // E.g., 304 = 300 + 3 (type) + 1 (index)
            const collection_ref = collection_hundreds + 3; // 3 is notes type
            const actual_note_index = remainder - 3;

            // Extract display index from collection ref
            const display_index = (collection_ref / 100) - 2;

            if (display_index < self.txe_state.vm_state_stack.items.len) {
                const state = self.txe_state.vm_state_stack.items[@intCast(display_index)];

                // Find the note by index
                var outer_iter = state.note_cache.notes.iterator();
                var current_index: usize = 0;
                while (outer_iter.next()) |contract_entry| {
                    var inner_iter = contract_entry.value_ptr.iterator();
                    while (inner_iter.next()) |slot_entry| {
                        const note_list = slot_entry.value_ptr;
                        for (note_list.items) |note| {
                            if (current_index == actual_note_index) {
                                // Found the note - show its fields
                                try variables.append(.{
                                    .name = "contract_address",
                                    .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{note.contract_address.value.to_int()}),
                                    .type = "AztecAddress",
                                });

                                try variables.append(.{
                                    .name = "storage_slot",
                                    .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{note.storage_slot.to_int()}),
                                    .type = "Field",
                                });

                                try variables.append(.{
                                    .name = "note_nonce",
                                    .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{note.note_nonce.to_int()}),
                                    .type = "Field",
                                });

                                try variables.append(.{
                                    .name = "note_hash",
                                    .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{note.note_hash.to_int()}),
                                    .type = "Field",
                                });

                                try variables.append(.{
                                    .name = "siloed_nullifier",
                                    .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{note.siloed_nullifier.to_int()}),
                                    .type = "Field",
                                });

                                // Show note fields
                                try variables.append(.{
                                    .name = "num_fields",
                                    .value = try std.fmt.allocPrint(allocator, "{}", .{note.note.items.len}),
                                    .type = "usize",
                                });

                                // Show individual fields
                                for (note.note.items, 0..) |field, i| {
                                    const field_name = try std.fmt.allocPrint(allocator, "field[{}]", .{i});
                                    try variables.append(.{
                                        .name = field_name,
                                        .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{field.to_int()}),
                                        .type = "Field",
                                    });
                                }

                                return variables.toOwnedSlice();
                            }
                            current_index += 1;
                        }
                    }
                }
            }
            return variables.toOwnedSlice();
        }

        if (scope_type == @intFromEnum(ScopeType.txe_global_state)) {
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
                .variablesReference = variables_reference - @intFromEnum(ScopeType.txe_global_state) + @intFromEnum(ScopeType.account_list), // Sub-reference for account list
            });
        } else if (scope_type >= @intFromEnum(ScopeType.call_state_base) and scope_type <= @intFromEnum(ScopeType.call_state_max)) {
            // Call State at specific display index
            const display_index = scope_type - @intFromEnum(ScopeType.call_state_base);
            const stack_len = self.txe_state.vm_state_stack.items.len;

            // Direct mapping: display_index = stack_index
            if (display_index < stack_len) {
                const stack_index = display_index;
                const state = self.txe_state.vm_state_stack.items[@intCast(stack_index)];
                try appendCallStateVariables(&variables, allocator, state, display_index);
            }
        } else if (scope_type == @intFromEnum(ScopeType.account_list)) {
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
        } else if (scope_type >= @intFromEnum(ScopeType.call_state_collections_base) and scope_type <= @intFromEnum(ScopeType.call_state_collections_max)) {
            // Sub-references for CallState collections
            const sub_type = scope_type % 100;
            const display_index = (scope_type / 100 - 2);
            const stack_len = self.txe_state.vm_state_stack.items.len;

            // Convert display index to stack index and get the CallState
            if (display_index < stack_len) {
                const stack_index = display_index; // direct mapping now
                const state = self.txe_state.vm_state_stack.items[@intCast(stack_index)];
                if (sub_type == @intFromEnum(CollectionType.storage_writes)) {
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
                } else if (sub_type == @intFromEnum(CollectionType.nullifiers)) {
                    // Nullifiers
                    for (state.nullifiers.items, 0..) |nullifier, i| {
                        const name = try std.fmt.allocPrint(allocator, "[{}]", .{i});
                        try variables.append(.{
                            .name = name,
                            .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{nullifier.to_int()}),
                            .type = "Field",
                        });
                    }
                } else if (sub_type == @intFromEnum(CollectionType.private_logs)) {
                    // Private logs
                    for (state.private_logs.items, 0..) |log, i| {
                        const name = try std.fmt.allocPrint(allocator, "[{}]", .{i});
                        const value_str = if (log.emitted_length > 0)
                            try std.fmt.allocPrint(allocator, "[{}]F = 0x{x:0>64}...", .{ log.emitted_length, log.fields[0].to_int() })
                        else
                            try std.fmt.allocPrint(allocator, "[0]F", .{});
                        try variables.append(.{
                            .name = name,
                            .value = value_str,
                            .type = "PrivateLog",
                        });
                    }
                } else if (sub_type == @intFromEnum(CollectionType.notes)) {
                    var outer_iter = state.note_cache.notes.iterator();
                    var index: usize = 0;
                    while (outer_iter.next()) |contract_entry| {
                        var inner_iter = contract_entry.value_ptr.iterator();
                        while (inner_iter.next()) |slot_entry| {
                            const note_list = slot_entry.value_ptr;
                            for (note_list.items) |note| {
                                // Create expandable note with sub-reference
                                const name = try std.fmt.allocPrint(allocator, "[{}]", .{index});
                                const value_str = try std.fmt.allocPrint(allocator, "Note at slot {}", .{note.storage_slot});
                                // Simple encoding: just add 10000 to make it unique
                                // We'll store the collection ref and index separately
                                const note_ref: u32 = @intCast(variables_reference + 10000 + index);

                                try variables.append(.{
                                    .name = name,
                                    .value = value_str,
                                    .type = "Note",
                                    .variablesReference = note_ref,
                                });
                                index += 1;
                            }
                        }
                    }
                    // If no notes were found, show a message
                    if (index == 0) {
                        try variables.append(.{
                            .name = "(empty)",
                            .value = "No notes in cache",
                            .type = "string",
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
        display_index: usize,
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

        // Notes list (expandable) - only show if there are actually notes
        // We need to check if the cache actually has notes, not just rely on getTotalNoteCount
        // which might return incorrect values for empty caches
        var actual_note_count: usize = 0;
        var note_check_iter = state.note_cache.notes.iterator();
        while (note_check_iter.next()) |contract_entry| {
            var storage_iter = contract_entry.value_ptr.iterator();
            while (storage_iter.next()) |storage_entry| {
                actual_note_count += storage_entry.value_ptr.items.len;
            }
        }

        if (actual_note_count > 0) {
            const notes_ref = calculateCollectionRef(display_index, CollectionType.notes);
            try variables.append(.{
                .name = "notes",
                .value = try std.fmt.allocPrint(allocator, "{} notes", .{actual_note_count}),
                .type = "NoteCache",
                .variablesReference = notes_ref,
            });
        }

        // Nullifiers list (expandable)
        if (state.nullifiers.items.len > 0) {
            try variables.append(.{
                .name = "nullifiers",
                .value = try std.fmt.allocPrint(allocator, "{} nullifiers", .{state.nullifiers.items.len}),
                .type = "ArrayList",
                .variablesReference = calculateCollectionRef(display_index, CollectionType.nullifiers),
            });
        }

        // Storage writes (expandable)
        if (state.storage_writes.count() > 0) {
            try variables.append(.{
                .name = "storage_writes",
                .value = try std.fmt.allocPrint(allocator, "{} writes", .{state.storage_writes.count()}),
                .type = "StringHashMap",
                .variablesReference = calculateCollectionRef(display_index, CollectionType.storage_writes),
            });
        }

        // Private logs list (expandable)
        if (state.private_logs.items.len > 0) {
            try variables.append(.{
                .name = "private_logs",
                .value = try std.fmt.allocPrint(allocator, "{} logs", .{state.private_logs.items.len}),
                .type = "ArrayList",
                .variablesReference = calculateCollectionRef(display_index, CollectionType.private_logs),
            });
        }
    }
};
