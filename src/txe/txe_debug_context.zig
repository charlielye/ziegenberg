const std = @import("std");
const debug_var = @import("../bvm/debug_variable_provider.zig");
const TxeState = @import("txe_state.zig").TxeState;
const F = @import("../bn254/fr.zig").Fr;
const bvm = @import("../bvm/package.zig");
const nargo = @import("../nargo/package.zig");

// Variable reference types - no more magic numbers!
const VariableRef = struct {
    kind: enum {
        txe_global_state,
        call_state,
        account_list,
        collection,
        note_detail,
        memory_writes,
    },
    vm_index: ?usize = null,
    collection_type: ?CollectionType = null,
    item_index: ?usize = null,
};

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

    // Reference management - no more magic numbers!
    ref_map: std.AutoHashMap(u32, VariableRef),
    next_ref: u32 = 1,

    fn allocateRef(self: *TxeDebugContext, ref_data: VariableRef) !u32 {
        const ref = self.next_ref;
        self.next_ref += 1;
        try self.ref_map.put(ref, ref_data);
        return ref;
    }

    fn clearRefs(self: *TxeDebugContext) void {
        self.ref_map.clearRetainingCapacity();
        self.next_ref = 1;
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
        txe_debug_ctx.ref_map = std.AutoHashMap(u32, VariableRef).init(allocator);
        txe_debug_ctx.next_ref = 1;
        txe_debug_ctx.bvm_debug_ctx = try bvm.DebugContext.initWithVariableProvider(
            allocator,
            txe_debug_ctx.debugVariableProvider(),
        );
        return txe_debug_ctx;
    }

    pub fn deinit(self: *TxeDebugContext) void {
        self.ref_map.deinit();
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

    fn getScopesImpl(context: *anyopaque, allocator: std.mem.Allocator, _: u32) anyerror![]debug_var.DebugScope {
        const self = @as(*TxeDebugContext, @ptrCast(@alignCast(context)));

        var scopes = std.ArrayList(debug_var.DebugScope).init(allocator);
        defer scopes.deinit();

        // Clear old references for this frame (only relevant if we're reusing frame_id)
        self.clearRefs();

        // Add TXE Global State scope
        const global_ref = try self.allocateRef(.{ .kind = .txe_global_state });
        try scopes.append(.{
            .name = "TXE Global State",
            .presentationHint = "globals",
            .variablesReference = global_ref,
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

            const call_ref = try self.allocateRef(.{
                .kind = .call_state,
                .vm_index = display_index,
            });

            try scopes.append(.{
                .name = scope_name,
                .presentationHint = if (display_index == 0) "locals" else "arguments",
                .variablesReference = call_ref,
                .expensive = false,
            });
        }

        return scopes.toOwnedSlice();
    }

    fn getVariablesImpl(context: *anyopaque, allocator: std.mem.Allocator, variables_reference: u32) anyerror![]debug_var.DebugVariable {
        const self = @as(*TxeDebugContext, @ptrCast(@alignCast(context)));

        var variables = std.ArrayList(debug_var.DebugVariable).init(allocator);
        defer variables.deinit();

        // Look up the reference in our HashMap
        const ref_data = self.ref_map.get(variables_reference) orelse {
            // Return empty if reference not found
            return variables.toOwnedSlice();
        };

        std.debug.print("DEBUG getVariablesImpl: ref={}, kind={s}\n", .{ variables_reference, @tagName(ref_data.kind) });

        switch (ref_data.kind) {
            .txe_global_state => {
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

                // Accounts (list of addresses)
                const accounts_count = self.txe_state.accounts.count();
                if (accounts_count > 0) {
                    const accounts_ref = try self.allocateRef(.{ .kind = .account_list });
                    try variables.append(.{
                        .name = "accounts",
                        .value = try std.fmt.allocPrint(allocator, "{} accounts", .{accounts_count}),
                        .type = "HashMap",
                        .variablesReference = accounts_ref,
                    });
                }
            },
            .call_state => {
                const display_index = ref_data.vm_index.?;
                if (display_index < self.txe_state.vm_state_stack.items.len) {
                    const state = self.txe_state.vm_state_stack.items[@intCast(display_index)];

                    try appendCallStateVariables(&variables, allocator, state, display_index, self);
                }
            },
            .account_list => {
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
            },
            .collection => {
                const display_index = ref_data.vm_index.?;
                const collection_type = ref_data.collection_type.?;

                if (display_index < self.txe_state.vm_state_stack.items.len) {
                    const state = self.txe_state.vm_state_stack.items[@intCast(display_index)];

                    switch (collection_type) {
                        .storage_writes => {
                            // Storage writes not implemented yet
                            // var iter = state.storage_writes.iterator();
                            // var index: usize = 0;
                            // while (iter.next()) |entry| {
                            //     const name = try std.fmt.allocPrint(allocator, "[{}] {s}", .{ index, entry.key_ptr.* });
                            //     const value_str = if (entry.value_ptr.*.len > 0)
                            //         try std.fmt.allocPrint(allocator, "[{}]F = 0x{x:0>64}...", .{ entry.value_ptr.*.len, entry.value_ptr.*[0].to_int() })
                            //     else
                            //         try std.fmt.allocPrint(allocator, "[0]F", .{});
                            //     try variables.append(.{
                            //         .name = name,
                            //         .value = value_str,
                            //         .type = "[]F",
                            //     });
                            //     index += 1;
                            // }
                        },
                        .nullifiers => {
                            for (state.public_nullifiers.items, 0..) |nullifier, i| {
                                const name = try std.fmt.allocPrint(allocator, "[{}]", .{i});
                                try variables.append(.{
                                    .name = name,
                                    .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{nullifier.to_int()}),
                                    .type = "Field",
                                });
                            }
                        },
                        .private_logs => {
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
                        },
                        .notes => {
                            for (state.note_cache.notes.items, 0..) |note, index| {
                                const name = try std.fmt.allocPrint(allocator, "[{}]", .{index});
                                const value_str = try std.fmt.allocPrint(allocator, "Note at slot {}", .{note.storage_slot});

                                // Allocate a reference for this specific note
                                const note_ref = try self.allocateRef(.{
                                    .kind = .note_detail,
                                    .vm_index = display_index,
                                    .item_index = index,
                                });

                                try variables.append(.{
                                    .name = name,
                                    .value = value_str,
                                    .type = "Note",
                                    .variablesReference = note_ref,
                                });
                            }
                            // If no notes were found, show a message
                            if (state.note_cache.notes.items.len == 0) {
                                try variables.append(.{
                                    .name = "(empty)",
                                    .value = "No notes in cache",
                                    .type = "string",
                                });
                            }
                        },
                    }
                }
            },
            .note_detail => {
                const display_index = ref_data.vm_index.?;
                const note_index = ref_data.item_index.?;

                if (display_index < self.txe_state.vm_state_stack.items.len) {
                    const state = self.txe_state.vm_state_stack.items[@intCast(display_index)];

                    // Find the note by index
                    if (note_index < state.note_cache.notes.items.len) {
                        const note = state.note_cache.notes.items[note_index];
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
                            .value = try std.fmt.allocPrint(allocator, "{}", .{note.note_fields.len}),
                            .type = "usize",
                        });

                        // Show individual fields
                        for (note.note_fields, 0..) |field, i| {
                            const field_name = try std.fmt.allocPrint(allocator, "field[{}]", .{i});
                            try variables.append(.{
                                .name = field_name,
                                .value = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{field.to_int()}),
                                .type = "Field",
                            });
                        }
                    }
                }
            },
            .memory_writes => {
                // Not implemented yet
            },
        }

        return variables.toOwnedSlice();
    }

    fn appendCallStateVariables(
        variables: *std.ArrayList(debug_var.DebugVariable),
        allocator: std.mem.Allocator,
        state: *@import("call_state.zig").CallState,
        display_index: usize,
        self: *TxeDebugContext,
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
        // We need to check if the cache actually has notes
        const actual_note_count = state.note_cache.notes.items.len;

        if (actual_note_count > 0) {
            const notes_ref = try self.allocateRef(.{
                .kind = .collection,
                .vm_index = display_index,
                .collection_type = .notes,
            });
            try variables.append(.{
                .name = "notes",
                .value = try std.fmt.allocPrint(allocator, "{} notes", .{actual_note_count}),
                .type = "NoteCache",
                .variablesReference = notes_ref,
            });
        }

        // Nullifiers list (expandable)
        if (state.public_nullifiers.items.len > 0) {
            const nullifiers_ref = try self.allocateRef(.{
                .kind = .collection,
                .vm_index = display_index,
                .collection_type = .nullifiers,
            });
            try variables.append(.{
                .name = "nullifiers",
                .value = try std.fmt.allocPrint(allocator, "{} nullifiers", .{state.public_nullifiers.items.len}),
                .type = "ArrayList",
                .variablesReference = nullifiers_ref,
            });
        }

        // Storage writes (expandable) - commented out as storage_writes is not available
        // if (state.storage_writes.count() > 0) {
        //     const storage_ref = try self.allocateRef(.{
        //         .kind = .collection,
        //         .vm_index = display_index,
        //         .collection_type = .storage_writes,
        //     });
        //     try variables.append(.{
        //         .name = "storage_writes",
        //         .value = try std.fmt.allocPrint(allocator, "{} writes", .{state.storage_writes.count()}),
        //         .type = "StringHashMap",
        //         .variablesReference = storage_ref,
        //     });
        // }

        // Private logs list (expandable)
        if (state.private_logs.items.len > 0) {
            const logs_ref = try self.allocateRef(.{
                .kind = .collection,
                .vm_index = display_index,
                .collection_type = .private_logs,
            });
            try variables.append(.{
                .name = "private_logs",
                .value = try std.fmt.allocPrint(allocator, "{} logs", .{state.private_logs.items.len}),
                .type = "ArrayList",
                .variablesReference = logs_ref,
            });
        }
    }
};
