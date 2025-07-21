const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const proto = @import("../protocol/package.zig");
const ContractAbi = @import("../nargo/contract.zig").ContractAbi;
const call_state = @import("call_state.zig");

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
};
