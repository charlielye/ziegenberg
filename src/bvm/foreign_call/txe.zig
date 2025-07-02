const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");
const structDispatcher = @import("./struct_dispatcher.zig").structDispatcher;

const EthAddress = F;
const AztecAddress = F;

const Point = struct {
    x: F,
    y: F,
    i: bool,
};

const NpkM = Point;
const IvpkM = Point;
const OvpkM = Point;
const TpkM = Point;

const PublicKeys = struct {
    npk_m: NpkM,
    ivpk_m: IvpkM,
    ovpk_m: OvpkM,
    tpk_m: TpkM,
};

const CompleteAddress = struct {
    address: AztecAddress,
    public_keys: PublicKeys,
};

const FunctionSelector = u32;

const CallContext = struct {
    msg_sender: AztecAddress = F.zero,
    contract_address: AztecAddress = F.zero,
    function_selector: FunctionSelector = 0,
    is_static_call: bool = false,
};

const AppendOnlyTreeSnapshot = struct {
    // Root of the append only tree when taking the snapshot.
    root: F = F.zero,
    // Index of the next available leaf in the append only tree.
    //
    // Note: We include the next available leaf index in the snapshot so that the snapshot can be used to verify that
    //       the insertion was performed at the correct place. If we only verified tree root then it could happen that
    //       some leaves would get overwritten and the tree root check would still pass.
    //       TLDR: We need to store the next available leaf index to ensure that the "append only" property was
    //             preserved when verifying state transitions.
    next_available_leaf_index: u32 = 0,
};

const PartialStateReference = struct {
    /// Snapshot of the note hash tree.
    note_hash_tree: AppendOnlyTreeSnapshot = AppendOnlyTreeSnapshot{},
    /// Snapshot of the nullifier tree.
    nullifier_tree: AppendOnlyTreeSnapshot = AppendOnlyTreeSnapshot{},
    /// Snapshot of the public data tree.
    public_data_tree: AppendOnlyTreeSnapshot = AppendOnlyTreeSnapshot{},
};

const StateReference = struct {
    /// Snapshot of the l1 to l2 message tree.
    l1_to_l2_message_tree: AppendOnlyTreeSnapshot = AppendOnlyTreeSnapshot{},
    /// Reference to the rest of the state.
    partial: PartialStateReference = PartialStateReference{},
};

const ContentCommitment = struct {
    blobs_hash: F = F.zero,
    in_hash: F = F.zero,
    out_hash: F = F.zero,
};

const GlobalVariables = struct {
    /// ChainId for the L2 block.
    chain_id: F = F.zero,
    /// Version for the L2 block.
    version: F = F.zero,
    /// Block number of the L2 block.
    block_number: u32 = 0,
    /// Slot number of the L2 block.
    slot_number: F = F.zero,
    /// Timestamp of the L2 block.
    timestamp: u64 = 0,
    /// Recipient of block reward.
    coinbase: EthAddress = F.zero,
    /// Address to receive fees.
    fee_recipient: AztecAddress = F.zero,
    /// Global gas prices for this block.
    gas_fees: GasFees = GasFees{},
};

const BlockHeader = struct {
    // Snapshot of archive before the block is applied.
    last_archive: AppendOnlyTreeSnapshot = AppendOnlyTreeSnapshot{},
    // Hash of the body of an L2 block.
    content_commitment: ContentCommitment = ContentCommitment{},
    // State reference.
    state: StateReference = StateReference{},
    // Global variables of an L2 block.
    global_variables: GlobalVariables = GlobalVariables{},
    // Total fees in the block, computed by the root rollup circuit
    total_fees: F = F.zero,
    // Total mana used in the block, computed by the root rollup circuit
    total_mana_used: F = F.zero,
};

/// Gas limits for data availability and L2 execution.
const Gas = struct {
    /// Data availability gas.
    da_gas: u32 = 0,
    /// L2 execution gas.
    l2_gas: u32 = 0,
};

/// Gas fee rates for data availability and L2 execution.
const GasFees = struct {
    /// Fee per data availability gas.
    fee_per_da_gas: u128 = 0,
    /// Fee per L2 execution gas.
    fee_per_l2_gas: u128 = 0,
};

/// Gas settings for a transaction.
const GasSettings = struct {
    /// Gas limits for the transaction.
    gas_limits: Gas = Gas{},
    /// Gas limits for teardown.
    teardown_gas_limits: Gas = Gas{},
    /// Maximum fees per gas.
    max_fees_per_gas: GasFees = GasFees{},
    /// Maximum priority fees per gas.
    max_priority_fees_per_gas: GasFees = GasFees{},
};

/// Transaction context.
const TxContext = struct {
    /// Chain ID of the transaction. Here for replay protection.
    chain_id: F = F.zero,
    /// Version of the transaction. Here for replay protection.
    version: F = F.zero,
    /// Gas limits for this transaction.
    gas_settings: GasSettings = GasSettings{},
};

const PrivateContextInputs = struct {
    call_context: CallContext,
    historical_header: BlockHeader,
    tx_context: TxContext,
    start_side_effect_counter: u32 = 0,
};

pub const Txe = struct {
    allocator: std.mem.Allocator,
    version: F = F.one,
    chain_id: F = F.one,
    block_number: u32 = 0,
    side_effect_counter: u32 = 0,
    contract_address: AztecAddress,
    msg_sender: AztecAddress,
    function_selector: u32 = 0,
    is_static_call: bool = false,
    nested_call_returndata: []F,
    //   private contractDataOracle: ContractDataOracle;

    const CHAIN_ID = 1;
    const ROLLUP_VERSION = 1;
    const GENESIS_TIMESTAMP = 1767225600;
    const AZTEC_SLOT_DURATION = 36;

    pub fn init(allocator: std.mem.Allocator) Txe {
        return .{
            .allocator = allocator,
            .contract_address = F.random(),
            .msg_sender = F.max,
            .nested_call_returndata = &[_]F{},
        };
    }

    pub fn deinit(_: *Txe) void {}

    /// Dispatch function for foreign calls.
    /// The given allocator is used for transient data and is freed by the caller.
    pub fn handleForeignCall(
        self: *Txe,
        allocator: std.mem.Allocator,
        mem: *Memory,
        fc: *const io.ForeignCall,
        params: []foreign_call.ForeignCallParam,
    ) !bool {
        return try structDispatcher(self, allocator, mem, fc, params);
    }

    pub fn reset(_: *Txe) !void {
        std.debug.print("reset called!\n", .{});
    }

    pub fn createAccount(self: *Txe, secret: F) !CompleteAddress {
        _ = self;
        std.debug.print("createAccount called: {x}\n", .{secret});
        return .{
            .address = F.random(),
            .public_keys = .{
                .npk_m = .{ .x = F.from_int(1), .y = F.from_int(2), .i = false },
                .ivpk_m = .{ .x = F.from_int(3), .y = F.from_int(4), .i = false },
                .ovpk_m = .{ .x = F.from_int(5), .y = F.from_int(6), .i = false },
                .tpk_m = .{ .x = F.from_int(7), .y = F.from_int(8), .i = false },
            },
        };
    }

    pub fn setContractAddress(self: *Txe, address: AztecAddress) !void {
        self.contract_address = address;
        std.debug.print("setContractAddress: {x}\n", .{self.contract_address});
    }

    const DeployResponse = struct {
        salt: F,
        deployer: F,
        contract_class_id: F,
        initialization_hash: F,
        public_keys: PublicKeys,
    };

    pub fn deploy(
        self: *Txe,
        path: []u8,
        name: []u8,
        initializer: []u8,
        args_len: u32,
        args: []F,
        public_keys_hash: F,
    ) ![16]F {
        std.debug.print("deploy: {s} {s} {s} {} {short} {short}\n", .{
            path,
            name,
            initializer,
            args_len,
            args,
            public_keys_hash,
        });
        var r: [16]F = undefined;
        for (&r) |*e| e.* = F.random();
        self.block_number += 1;
        return r;
    }

    pub fn getBlockNumber(self: *Txe) !u64 {
        return self.block_number;
    }

    pub fn getPrivateContextInputs(
        self: *Txe,
        block_number: ?u32,
        timestamp: ?u64,
        side_effects_counter: u32,
        is_static: bool,
    ) !PrivateContextInputs {
        const result = PrivateContextInputs{
            .tx_context = .{
                .chain_id = F.from_int(Txe.CHAIN_ID),
                .version = F.from_int(Txe.ROLLUP_VERSION),
            },
            .historical_header = .{ .global_variables = .{
                .block_number = block_number orelse self.block_number,
                .timestamp = timestamp orelse Txe.GENESIS_TIMESTAMP - Txe.AZTEC_SLOT_DURATION,
            } },
            .call_context = .{
                .msg_sender = self.msg_sender,
                .contract_address = self.contract_address,
                .function_selector = self.function_selector,
                .is_static_call = is_static,
            },
            .start_side_effect_counter = side_effects_counter,
        };
        return result;
    }
};
