const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const ForeignCallParam = @import("./param.zig").ForeignCallParam;
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");
const structDispatcher = @import("./struct_dispatcher.zig").structDispatcher;
const proto = @import("../../protocol/package.zig");
const loadContract = @import("../../nargo/contract.zig").load;

const EthAddress = F;

const Point = struct {
    x: F,
    y: F,
    i: bool,
};

const NpkM = Point;
const IvpkM = Point;
const OvpkM = Point;
const TpkM = Point;

// const PublicKeys = struct {
//     npk_m: NpkM,
//     ivpk_m: IvpkM,
//     ovpk_m: OvpkM,
//     tpk_m: TpkM,
// };

const FunctionSelector = u32;

const CallContext = struct {
    msg_sender: proto.AztecAddress = proto.AztecAddress.zero,
    contract_address: proto.AztecAddress = proto.AztecAddress.zero,
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
    fee_recipient: proto.AztecAddress = proto.AztecAddress.zero,
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

/// Computes a fast hash (SHA-1) of a file at the given path.
/// Returns the hash as a hex string.
pub fn fastHashFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // TODO: SHA1 is considered cryptographically broken?
    var sha1 = std.crypto.hash.Sha1.init(.{});
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        sha1.update(buf[0..n]);
    }

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);

    // Convert digest to hex string
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

pub const Txe = struct {
    allocator: std.mem.Allocator,
    version: F = F.one,
    chain_id: F = F.one,
    block_number: u32 = 0,
    side_effect_counter: u32 = 0,
    contract_address: proto.AztecAddress,
    msg_sender: proto.AztecAddress,
    function_selector: u32 = 0,
    is_static_call: bool = false,
    nested_call_returndata: []F,
    contracts_artifacts_path: []const u8,
    //   private contractDataOracle: ContractDataOracle;

    const CHAIN_ID = 1;
    const ROLLUP_VERSION = 1;
    const GENESIS_TIMESTAMP = 1767225600;
    const AZTEC_SLOT_DURATION = 36;

    pub fn init(allocator: std.mem.Allocator, contract_artifacts_path: []const u8) Txe {
        return .{
            .allocator = allocator,
            .contract_address = proto.AztecAddress.random(),
            .msg_sender = proto.AztecAddress.init(F.max),
            .nested_call_returndata = &[_]F{},
            .contracts_artifacts_path = contract_artifacts_path,
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
        params: []ForeignCallParam,
    ) !bool {
        return try structDispatcher(self, allocator, mem, fc, params);
    }

    pub fn reset(_: *Txe) !void {
        std.debug.print("reset called!\n", .{});
    }

    pub fn createAccount(self: *Txe, secret: F) !struct {
        address: proto.AztecAddress,
        public_keys: proto.PublicKeys,
    } {
        _ = self;
        std.debug.print("createAccount called: {x}\n", .{secret});

        // TODO: Why do we use the secret for both args here?
        // TS code unhelpfully just says "Footgun!"...
        const complete_address = proto.CompleteAddress.fromSecretKeyAndPartialAddress(secret, secret);

        return .{
            .address = complete_address.aztec_address,
            .public_keys = complete_address.public_keys,
        };
    }

    pub fn getContractAddress(self: *Txe) !proto.AztecAddress {
        return self.contract_address;
    }

    pub fn setContractAddress(self: *Txe, address: proto.AztecAddress) !void {
        self.contract_address = address;
        std.debug.print("setContractAddress: {x}\n", .{self.contract_address});
    }

    const DeployResponse = struct {
        salt: F,
        deployer: F,
        contract_class_id: F,
        initialization_hash: F,
        public_keys: proto.PublicKeys,
    };

    pub fn deploy(
        self: *Txe,
        path: []u8,
        contract_name: []u8,
        initializer: []u8,
        args_len: u32,
        args: []F,
        secret: F,
    ) ![16]F {
        std.debug.print("deploy: {s} {s} {s} {} {short} {short}\n", .{
            path,
            contract_name,
            initializer,
            args_len,
            args,
            secret,
        });

        const public_keys = if (secret.is_zero()) proto.PublicKeys.default() else proto.deriveKeys(secret).public_keys;
        const public_keys_hash = public_keys.hash();
        _ = public_keys_hash;

        if (std.mem.eql(u8, path, "")) {
            const contract_path = try std.fmt.allocPrint(self.allocator, "data/contracts/{s}.json", .{contract_name});
            const contract_abi = try loadContract(self.allocator, contract_path);
            const contract_instance = proto.ContractInstance.fromDeployParams(contract_abi, .{
                .constructor_name = initializer,
                .constructor_args = args,
                .salt = F.one,
                .public_keys = public_keys,
            });
            _ = contract_instance;
        } else {
            return error.Unimplemented;
        }

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
                .is_static_call = false,
            },
            .start_side_effect_counter = self.side_effect_counter,
        };
        return result;
    }

    /// Executes an external/private function call on a target contract.
    /// This is a port of the TypeScript logic, with some placeholders and comments.
    pub fn callPrivateFunction(
        self: *Txe,
        target_contract_address: proto.AztecAddress,
        function_selector: FunctionSelector,
        args_hash: F,
        side_effect_counter: u32,
        is_static_call: bool,
    ) !void {
        _ = args_hash;
        _ = side_effect_counter;
        _ = is_static_call;
        // Log the function call (verbose)
        // TODO: Implement debug function name lookup and logging
        // std.debug.print("Executing external function {}@{} isStaticCall={}\n", .{function_selector, target_contract_address, is_static_call});

        // Store current environment
        const current_contract_address = self.contract_address;
        const current_msg_sender = self.msg_sender;
        const current_function_selector = self.function_selector;

        // Set up new environment for the call
        self.msg_sender = self.contract_address;
        self.contract_address = target_contract_address;
        self.function_selector = function_selector;

        // TODO: Fetch the contract artifact for the target contract/function
        // let artifact = await this.contractDataProvider.getFunctionArtifact(targetContractAddress, functionSelector);
        // if (!artifact) { throw ... }

        // TODO: Prepare initial witness for circuit execution
        // let initialWitness = await this.getInitialWitness(...);

        // TODO: Set up callback/oracle and timer
        // let acvmCallback = new Oracle(this);
        // let timer = new Timer();

        // TODO: Execute the user circuit (simulate contract execution)
        // let acirExecutionResult = await this.simulator.executeUserCircuit(...);

        // TODO: Extract public inputs from execution result
        // let publicInputs = extractPrivateCircuitPublicInputs(...);

        // TODO: Log execution stats (duration, input/output size, etc.)

        // Apply side effects
        // let endSideEffectCounter = publicInputs.endSideEffectCounter;
        // self.side_effect_counter = endSideEffectCounter + 1;

        // TODO: Add private logs
        // await this.addPrivateLogs(...);

        // Restore previous environment
        self.contract_address = current_contract_address;
        self.msg_sender = current_msg_sender;
        self.function_selector = current_function_selector;

        // TODO: Return result (endSideEffectCounter, returnsHash)
        // return { endSideEffectCounter, returnsHash: publicInputs.returnsHash };
    }
};
