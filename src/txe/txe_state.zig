const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const proto = @import("../protocol/package.zig");
const ContractAbi = @import("../nargo/contract.zig").ContractAbi;
const call_state = @import("call_state.zig");
const NoteCache = @import("note_cache.zig").NoteCache;

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

    // Contains all the side effect state.
    note_cache: NoteCache,

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
            .note_cache = NoteCache.init(allocator),
            .accounts = accounts,
            .vm_state_stack = std.ArrayList(*call_state.CallState).init(allocator),
        };

        // Create initial state on heap and push to stack
        const initial_state = try allocator.create(call_state.CallState);
        initial_state.* = call_state.CallState.init(allocator, &txe.note_cache);
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
};
