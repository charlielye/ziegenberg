const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const ForeignCallParam = @import("./param.zig").ForeignCallParam;
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");
const structDispatcher = @import("./struct_dispatcher.zig").structDispatcher;
const proto = @import("../../protocol/package.zig");
const constants = @import("../../protocol/package.zig").constants;
const ContractAbi = @import("../../nargo/contract.zig").ContractAbi;
const structToFields = @import("./struct_field_conversion.zig").structToFields;
const fieldsToStructHelper = @import("./struct_field_conversion.zig").fieldsToStructHelper;
const cvm = @import("../../cvm/package.zig");
const ForeignCallDispatcher = @import("dispatcher.zig").Dispatcher;

const EthAddress = F;

const Point = struct {
    x: F,
    y: F,
    i: bool,
};

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

const IncludeByTimestamp = struct {
    is_some: bool = false,
    value: u64 = 0,
};

const ReadRequest = struct {
    value: F = F.zero,
    counter: u32 = 0,
};

const KeyValidationRequest = struct {
    pk_m: Point = Point{ .x = F.zero, .y = F.zero, .i = false },
    sk_app: F = F.zero,
};

const KeyValidationRequestAndGenerator = struct {
    request: KeyValidationRequest = KeyValidationRequest{},
    sk_app_generator: F = F.zero,
};

const NoteHash = struct {
    value: F = F.zero,
    counter: u32 = 0,
};

const Nullifier = struct {
    value: F = F.zero,
    counter: u32 = 0,
    note_hash: F = F.zero,
};

const PrivateCallRequest = struct {
    call_context: CallContext = CallContext{},
    args_hash: F = F.zero,
    returns_hash: F = F.zero,
    start_side_effect_counter: u32 = 0,
    end_side_effect_counter: u32 = 0,
};

const PublicCallRequest = struct {
    msg_sender: proto.AztecAddress = proto.AztecAddress.zero,
    contract_address: proto.AztecAddress = proto.AztecAddress.zero,
    is_static_call: bool = false,
    calldata_hash: F = F.zero,
};

const CountedPublicCallRequest = struct {
    request: PublicCallRequest = PublicCallRequest{},
    counter: u32 = 0,
};

const CountedL2ToL1Message = struct {
    message: L2ToL1Message = L2ToL1Message{},
    counter: u32 = 0,
};

const L2ToL1Message = struct {
    recipient: EthAddress = F.zero,
    content: F = F.zero,
};

const PrivateLog = struct {
    fields: [18]F = [_]F{F.zero} ** 18,
    emitted_length: u32 = 0,
};

const PrivateLogData = struct {
    log: PrivateLog = PrivateLog{},
    note_hash_counter: u32 = 0,
    counter: u32 = 0,
};

const LogHash = struct {
    value: F = F.zero,
    length: u32 = 0,
};

const CountedLogHash = struct {
    log_hash: LogHash = LogHash{},
    counter: u32 = 0,
};

// Generic wrapper for arrays with claimed length
fn ClaimedLengthArray(comptime T: type, comptime MAX_SIZE: u32) type {
    return struct {
        data: [MAX_SIZE]T = [_]T{T{}} ** MAX_SIZE,
        claimed_length: u32 = 0,
    };
}

const PrivateCircuitPublicInputs = struct {
    call_context: CallContext = CallContext{},
    args_hash: F = F.zero,
    returns_hash: F = F.zero,
    min_revertible_side_effect_counter: F = F.zero,
    is_fee_payer: bool = false,
    include_by_timestamp: IncludeByTimestamp = IncludeByTimestamp{},
    note_hash_read_requests: ClaimedLengthArray(ReadRequest, constants.MAX_NOTE_HASH_READ_REQUESTS_PER_CALL) = ClaimedLengthArray(ReadRequest, constants.MAX_NOTE_HASH_READ_REQUESTS_PER_CALL){},
    nullifier_read_requests: ClaimedLengthArray(ReadRequest, constants.MAX_NULLIFIER_READ_REQUESTS_PER_CALL) = ClaimedLengthArray(ReadRequest, constants.MAX_NULLIFIER_READ_REQUESTS_PER_CALL){},
    key_validation_requests_and_generators: ClaimedLengthArray(KeyValidationRequestAndGenerator, constants.MAX_KEY_VALIDATION_REQUESTS_PER_CALL) = ClaimedLengthArray(KeyValidationRequestAndGenerator, constants.MAX_KEY_VALIDATION_REQUESTS_PER_CALL){},
    note_hashes: ClaimedLengthArray(NoteHash, constants.MAX_NOTE_HASHES_PER_CALL) = ClaimedLengthArray(NoteHash, constants.MAX_NOTE_HASHES_PER_CALL){},
    nullifiers: ClaimedLengthArray(Nullifier, constants.MAX_NULLIFIERS_PER_CALL) = ClaimedLengthArray(Nullifier, constants.MAX_NULLIFIERS_PER_CALL){},
    private_call_requests: ClaimedLengthArray(PrivateCallRequest, constants.MAX_PRIVATE_CALL_STACK_LENGTH_PER_CALL) = ClaimedLengthArray(PrivateCallRequest, constants.MAX_PRIVATE_CALL_STACK_LENGTH_PER_CALL){},
    public_call_requests: ClaimedLengthArray(CountedPublicCallRequest, constants.MAX_ENQUEUED_CALLS_PER_CALL) = ClaimedLengthArray(CountedPublicCallRequest, constants.MAX_ENQUEUED_CALLS_PER_CALL){},
    public_teardown_call_request: PublicCallRequest = PublicCallRequest{},
    l2_to_l1_msgs: ClaimedLengthArray(CountedL2ToL1Message, constants.MAX_L2_TO_L1_MSGS_PER_CALL) = ClaimedLengthArray(CountedL2ToL1Message, constants.MAX_L2_TO_L1_MSGS_PER_CALL){},
    private_logs: ClaimedLengthArray(PrivateLogData, constants.MAX_PRIVATE_LOGS_PER_CALL) = ClaimedLengthArray(PrivateLogData, constants.MAX_PRIVATE_LOGS_PER_CALL){},
    contract_class_logs_hashes: ClaimedLengthArray(CountedLogHash, constants.MAX_CONTRACT_CLASS_LOGS_PER_CALL) = ClaimedLengthArray(CountedLogHash, constants.MAX_CONTRACT_CLASS_LOGS_PER_CALL){},
    start_side_effect_counter: F = F.zero,
    end_side_effect_counter: F = F.zero,
    historical_header: BlockHeader = BlockHeader{},
    tx_context: TxContext = TxContext{},
};

/// Computes a fast hash (SHA-1) of a file at the given path.
/// Returns the hash as a hex string.
// pub fn fastHashFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
//     var file = try std.fs.cwd().openFile(path, .{});
//     defer file.close();

//     // TODO: SHA1 is considered cryptographically broken?
//     var sha1 = std.crypto.hash.Sha1.init(.{});
//     var buf: [4096]u8 = undefined;

//     while (true) {
//         const n = try file.read(&buf);
//         if (n == 0) break;
//         sha1.update(buf[0..n]);
//     }

//     var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
//     sha1.final(&digest);

//     // Convert digest to hex string
//     return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
// }

pub const Txe = struct {
    allocator: std.mem.Allocator,
    version: F = F.one,
    chain_id: F = F.one,
    block_number: u32 = 0,
    side_effect_counter: u32 = 0,
    contract_address: proto.AztecAddress = proto.AztecAddress.zero,
    msg_sender: proto.AztecAddress,
    function_selector: u32 = 0,
    is_static_call: bool = false,
    nested_call_returndata: []F,
    contracts_artifacts_path: []const u8,
    contract_artifact_cache: std.AutoHashMap(F, ContractAbi),
    contract_instance_cache: std.AutoHashMap(proto.AztecAddress, proto.ContractInstance),
    args_hash_map: std.AutoHashMap(F, []F),
    fc_handler: *ForeignCallDispatcher = undefined,
    // Capsule storage: key is "address:slot", value is array of F elements
    capsule_storage: std.StringHashMap([]F),
    //   private contractDataOracle: ContractDataOracle;
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(12345),

    const CHAIN_ID = 1;
    const ROLLUP_VERSION = 1;
    const GENESIS_TIMESTAMP = 1767225600;
    const AZTEC_SLOT_DURATION = 36;

    pub fn init(allocator: std.mem.Allocator, contract_artifacts_path: []const u8) Txe {
        return .{
            .allocator = allocator,
            .msg_sender = proto.AztecAddress.init(F.max),
            .nested_call_returndata = &[_]F{},
            .contracts_artifacts_path = contract_artifacts_path,
            .contract_artifact_cache = std.AutoHashMap(F, ContractAbi).init(allocator),
            .contract_instance_cache = std.AutoHashMap(proto.AztecAddress, proto.ContractInstance).init(allocator),
            .args_hash_map = std.AutoHashMap(F, []F).init(allocator),
            .capsule_storage = std.StringHashMap([]F).init(allocator),
        };
    }

    pub fn deinit(self: *Txe) void {
        // Free all capsule data
        var iter = self.capsule_storage.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.capsule_storage.deinit();
        self.args_hash_map.deinit();
        self.contract_instance_cache.deinit();
        self.contract_artifact_cache.deinit();
    }

    /// Dispatch function for foreign calls.
    /// The given allocator is used for transient data and is freed by the caller.
    pub fn handleForeignCall(
        self: *Txe,
        allocator: std.mem.Allocator,
        mem: *Memory,
        fc: *const io.ForeignCall,
        params: []ForeignCallParam,
        fc_handler: *ForeignCallDispatcher,
    ) !bool {
        // We save the handler like this so we don't have to pass it to every handler function.
        self.fc_handler = fc_handler;
        return try structDispatcher(self, allocator, mem, fc, params);
    }

    pub fn reset(self: *Txe, _: std.mem.Allocator) !void {
        std.debug.print("reset called!\n", .{});

        // Clear all capsule storage
        var iter = self.capsule_storage.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.capsule_storage.clearRetainingCapacity();

        // Reset other state
        self.side_effect_counter = 0;
        self.is_static_call = false;

        std.debug.print("reset: cleared capsule storage and reset state\n", .{});
    }

    pub fn createAccount(self: *Txe, _: std.mem.Allocator, secret: F) !struct {
        address: proto.AztecAddress,
        public_keys: proto.PublicKeys,
    } {
        _ = self;
        std.debug.print("createAccount called: {x}\n", .{secret});

        // TODO: Why do we use the secret for both args here?
        // TS code unhelpfully just says "Footgun!"...
        const complete_address = proto.CompleteAddress.fromSecretKeyAndPartialAddress(
            secret,
            proto.PartialAddress.init(secret),
        );

        return .{
            .address = complete_address.aztec_address,
            .public_keys = complete_address.public_keys,
        };
    }

    pub fn getContractAddress(self: *Txe, _: std.mem.Allocator) !proto.AztecAddress {
        return self.contract_address;
    }

    pub fn setContractAddress(self: *Txe, _: std.mem.Allocator, address: proto.AztecAddress) !void {
        self.contract_address = address;
        std.debug.print("setContractAddress: {x}\n", .{self.contract_address});
    }

    pub fn deploy(
        self: *Txe,
        tmp_allocator: std.mem.Allocator,
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

        if (!std.mem.eql(u8, path, "")) {
            return error.Unimplemented;
        }

        const contract_path = try std.fmt.allocPrint(tmp_allocator, "{s}/{s}.json", .{
            self.contracts_artifacts_path,
            contract_name,
        });
        // Note use of long lived allocator as we will cache it.
        const contract_abi = try ContractAbi.load(self.allocator, contract_path);
        const contract_instance = proto.ContractInstance.fromDeployParams(tmp_allocator, contract_abi, .{
            .constructor_name = initializer,
            .constructor_args = args,
            .salt = F.one,
            .public_keys = public_keys,
        });

        try self.contract_artifact_cache.put(contract_abi.class_id, contract_abi);
        try self.contract_instance_cache.put(contract_instance.address, contract_instance);

        std.debug.print("Deployed contract {s} with class id {x} at address {x}\n", .{
            contract_name,
            contract_abi.class_id,
            contract_instance.address,
        });

        self.block_number += 1;

        const mnpk_inf: u256 = if (public_keys.master_nullifier_public_key.is_infinity()) 1 else 0;
        const mivpk_inf: u256 = if (public_keys.master_incoming_viewing_public_key.is_infinity()) 1 else 0;
        const movpk_inf: u256 = if (public_keys.master_outgoing_viewing_public_key.is_infinity()) 1 else 0;
        const mtpk_inf: u256 = if (public_keys.master_tagging_public_key.is_infinity()) 1 else 0;

        return [16]F{
            contract_instance.salt,
            contract_instance.deployer.value,
            contract_instance.current_contract_class_id,
            contract_instance.initialization_hash,
            public_keys.master_nullifier_public_key.x,
            public_keys.master_nullifier_public_key.y,
            F.from_int(mnpk_inf),
            public_keys.master_incoming_viewing_public_key.x,
            public_keys.master_incoming_viewing_public_key.y,
            F.from_int(mivpk_inf),
            public_keys.master_outgoing_viewing_public_key.x,
            public_keys.master_outgoing_viewing_public_key.y,
            F.from_int(movpk_inf),
            public_keys.master_tagging_public_key.x,
            public_keys.master_tagging_public_key.y,
            F.from_int(mtpk_inf),
        };
    }

    pub fn getBlockNumber(self: *Txe, _: std.mem.Allocator) !u64 {
        return self.block_number;
    }

    pub fn getPrivateContextInputs(
        self: *Txe,
        allocator: std.mem.Allocator,
        block_number: ?u32,
        timestamp: ?u64,
    ) !PrivateContextInputs {
        return self.getPrivateContextInputsInternal(allocator, block_number, timestamp, self.side_effect_counter, false);
    }

    fn getPrivateContextInputsInternal(
        self: *Txe,
        _: std.mem.Allocator,
        block_number: ?u32,
        timestamp: ?u64,
        side_effect_counter: u32,
        is_static_call: bool,
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
                .is_static_call = is_static_call,
            },
            .start_side_effect_counter = side_effect_counter,
        };
        return result;
    }

    // Since the argument is a slice, noir automatically adds a length field to oracle call.
    pub fn storeInExecutionCache(
        self: *Txe,
        _: std.mem.Allocator,
        _: F,
        args: []F,
        hash: F,
    ) !void {
        std.debug.print("storeInExecutionCache called with args: {x} and hash: {x}\n", .{
            args,
            hash,
        });
        try self.args_hash_map.put(hash, args);
    }

    /// Executes an external/private function call on a target contract.
    pub fn callPrivateFunction(
        self: *Txe,
        allocator: std.mem.Allocator,
        target_contract_address: proto.AztecAddress,
        function_selector: FunctionSelector,
        args_hash: F,
        side_effect_counter: u32,
        is_static_call: bool,
    ) ![2]F {
        // Store current environment
        const current_contract_address = self.contract_address;
        const current_msg_sender = self.msg_sender;
        const current_function_selector = self.function_selector;

        // Set up new environment for the call
        self.msg_sender = self.contract_address;
        self.contract_address = target_contract_address;
        self.function_selector = function_selector;

        const contract_instance = self.contract_instance_cache.get(target_contract_address) orelse {
            return error.ContractInstanceNotFound;
        };
        const function = try contract_instance.abi.getFunctionBySelector(function_selector);

        std.debug.print("Executing external function: {s}@{x} (static: {})\n", .{
            function.name,
            target_contract_address,
            is_static_call,
        });
        std.debug.print("Function parameters: {}\n", .{function.abi.parameters.len});
        for (function.abi.parameters, 0..) |param, idx| {
            std.debug.print("  Param[{}]: {s} (type: {s})\n", .{ idx, param.name, param.type.kind });
        }

        const args = self.args_hash_map.get(args_hash) orelse {
            std.debug.print("No args found for hash {x}\n", .{args_hash});
            return error.ArgsNotFound;
        };

        const private_context_inputs = try self.getPrivateContextInputsInternal(
            self.allocator,
            self.block_number - 1,
            Txe.GENESIS_TIMESTAMP - Txe.AZTEC_SLOT_DURATION,
            side_effect_counter,
            is_static_call,
        );

        var calldata = std.ArrayList(F).init(allocator);
        const context_start = calldata.items.len;
        try structToFields(PrivateContextInputs, private_context_inputs, &calldata);
        const context_size = calldata.items.len - context_start;
        std.debug.print("Actual PrivateContextInputs serialized to {} fields\n", .{context_size});

        for (args) |arg| {
            try calldata.append(arg);
        }

        std.debug.print("Total calldata size: {} (context: {}, args: {})\n", .{ calldata.items.len, context_size, args.len });
        std.debug.print("calldata: {x}\n", .{calldata.items});

        const program = try cvm.deserialize(allocator, try function.getBytecode(allocator));

        var circuit_vm = try cvm.CircuitVm.init(allocator, &program, calldata.items, self.fc_handler);
        std.debug.print("callPrivateFunction: Entering nested cvm\n", .{});
        circuit_vm.executeVm(0, false) catch |err| {
            if (err == error.Trapped) {
                // Print detailed error information
                circuit_vm.printBrilligTrapError(function.name, function_selector, "data/contracts/Counter.json" // TODO: Get actual artifact path
                );
            }
            return err;
        };
        std.debug.print("callPrivateFunction: Exited nested cvm\n", .{});

        // Extract public inputs from execution result
        const start = function.sizeInFields() + constants.PRIVATE_CONTEXT_INPUTS_LENGTH;
        const public_inputs_fields = try circuit_vm.witnesses.getWitnessesRange(
            allocator,
            start,
            start + constants.PRIVATE_CIRCUIT_PUBLIC_INPUTS_LENGTH,
        );

        const private_circuit_public_inputs = try fieldsToStructHelper(PrivateCircuitPublicInputs, public_inputs_fields);
        const end_side_effect_counter = private_circuit_public_inputs.end_side_effect_counter;
        const returns_hash = private_circuit_public_inputs.returns_hash;

        // // Marshal the fields into the PrivateCircuitPublicInputs struct
        // std.debug.print("Attempting to deserialize {} fields into PrivateCircuitPublicInputs\n", .{public_inputs_fields.len});

        // For now, just print some of the raw fields to understand the structure
        std.debug.print("First 50 fields:\n", .{});
        for (public_inputs_fields[0..@min(50, public_inputs_fields.len)], 0..) |field, i| {
            std.debug.print("  [{d:3}] {x}\n", .{ i, field.to_int() });
        }

        // // For now, manually extract key fields we need
        // // Based on the TypeScript implementation and observed output:
        // // The end_side_effect_counter should be near the end of the struct
        // // Looking at the fields, it appears to be around index 746-747
        // const end_side_effect_counter_index = 747;
        // const returns_hash_index = 43; // Based on observation, this seems to be the returns_hash

        // const end_side_effect_counter = if (end_side_effect_counter_index < public_inputs_fields.len)
        //     public_inputs_fields[end_side_effect_counter_index]
        // else
        //     F.zero;

        // const returns_hash = if (returns_hash_index < public_inputs_fields.len)
        //     public_inputs_fields[returns_hash_index]
        // else
        //     F.zero;

        std.debug.print("Extracted: end_side_effect_counter={x}, returns_hash={x}\n", .{
            end_side_effect_counter.to_int(),
            returns_hash.to_int(),
        });

        // Apply side effects
        self.side_effect_counter = @intCast(end_side_effect_counter.to_int() + 1);

        // TODO: Add private logs
        // await this.addPrivateLogs(...);

        // Restore previous environment
        self.contract_address = current_contract_address;
        self.msg_sender = current_msg_sender;
        self.function_selector = current_function_selector;

        // Return result (endSideEffectCounter, returnsHash)
        return [2]F{ end_side_effect_counter, returns_hash };
    }

    pub fn getContractInstance(
        self: *Txe,
        _: std.mem.Allocator,
        address: proto.AztecAddress,
    ) !struct {
        salt: F,
        deployer: proto.AztecAddress,
        contract_class_id: F,
        initialization_hash: F,
        public_keys: proto.PublicKeys,
    } {
        const instance = self.contract_instance_cache.get(address);
        if (instance) |i| {
            return .{
                .salt = i.salt,
                .deployer = i.deployer,
                .contract_class_id = i.current_contract_class_id,
                .initialization_hash = i.initialization_hash,
                .public_keys = i.public_keys,
            };
        } else {
            return error.ContractInstanceNotFound;
        }
    }

    fn makeCapsuleKey(allocator: std.mem.Allocator, contract_address: proto.AztecAddress, slot: F) ![]u8 {
        // Format with consistent width (64 hex chars = 256 bits) to ensure keys match
        return std.fmt.allocPrint(allocator, "{x:0>64}:{x:0>64}", .{ contract_address.value.to_int(), slot.to_int() });
    }

    pub fn storeCapsule(
        self: *Txe,
        _: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        slot: F,
        capsule: []F,
    ) !void {
        // Check if contract is allowed to access this storage.
        if (!contract_address.eql(self.contract_address)) {
            std.debug.print("Contract {x} is not allowed to access {x}'s storage\n", .{
                contract_address,
                self.contract_address,
            });
            return error.UnauthorizedContractAccess;
        }

        const key = try makeCapsuleKey(self.allocator, contract_address, slot);

        // If there's existing data, free it.
        if (self.capsule_storage.get(key)) |existing| {
            self.allocator.free(existing);
        }

        // Store new data.
        const capsule_copy = try self.allocator.alloc(F, capsule.len);
        @memcpy(capsule_copy, capsule);

        try self.capsule_storage.put(key, capsule_copy);
    }

    pub fn loadCapsule(
        self: *Txe,
        allocator: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        slot: F,
        response_len: u32,
    ) !?[]F {
        _ = response_len;

        // Check if contract is allowed to access this storage.
        if (!contract_address.eql(self.contract_address)) {
            std.debug.print("Contract {x} is not allowed to access {x}'s storage\n", .{
                contract_address,
                self.contract_address,
            });
            return error.UnauthorizedContractAccess;
        }

        const key = try makeCapsuleKey(allocator, contract_address, slot);
        defer allocator.free(key);

        if (self.capsule_storage.get(key)) |capsule| {
            // Return a copy of the data
            const result = try allocator.alloc(F, capsule.len);
            @memcpy(result, capsule);
            return result;
        }

        return null;
    }

    pub fn debugLog(
        _: *Txe,
        _: std.mem.Allocator,
        msg: []const u8,
        _: F,
        fields: []F,
    ) !void {
        std.debug.print("Debug Log: {s}\n", .{msg});
        if (fields.len > 0) {
            std.debug.print("Fields: ", .{});
            for (fields) |field| {
                std.debug.print("{x} ", .{field});
            }
            std.debug.print("\n", .{});
        }
    }

    pub fn fetchTaggedLogs(
        self: *Txe,
        allocator: std.mem.Allocator,
        pending_tagged_log_array_base_slot: F,
    ) !void {
        // The TypeScript implementation populates this array with tagged logs from the blockchain.
        // For our minimal implementation, we'll store an empty array.
        var empty_array = [_]F{F.zero};

        // Store the empty array at the base slot.
        try self.storeCapsule(allocator, self.contract_address, pending_tagged_log_array_base_slot, empty_array[0..]);
    }

    pub fn bulkRetrieveLogs(
        self: *Txe,
        allocator: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        log_retrieval_requests_array_base_slot: F,
        log_retrieval_responses_array_base_slot: F,
    ) !void {
        // Check authorization.
        if (!contract_address.eql(self.contract_address)) {
            return error.UnauthorizedContractAccess;
        }

        // Load the requests array to get the count
        const requests_key = try makeCapsuleKey(allocator, contract_address, log_retrieval_requests_array_base_slot);
        defer allocator.free(requests_key);

        var num_requests: u32 = 0;
        if (self.capsule_storage.get(requests_key)) |data| {
            if (data.len > 0) {
                num_requests = @intCast(data[0].to_int());
            }
        }

        // For minimal implementation, create empty responses for each request
        var length_array = [_]F{F.from_int(num_requests)};
        try self.storeCapsule(allocator, contract_address, log_retrieval_responses_array_base_slot, length_array[0..]);

        // Store Option::none for each response
        var none_response = [_]F{F.zero};
        var i: u32 = 0;
        while (i < num_requests) : (i += 1) {
            const response_slot = log_retrieval_responses_array_base_slot.add(F.from_int(i + 1));
            try self.storeCapsule(allocator, contract_address, response_slot, none_response[0..]);
        }
    }

    pub fn validateEnqueuedNotesAndEvents(
        self: *Txe,
        _: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        _: F,
        _: F,
    ) !void {
        // Check authorization.
        if (!contract_address.eql(self.contract_address)) {
            return error.UnauthorizedContractAccess;
        }
    }

    pub fn getRandomField(self: *Txe, _: std.mem.Allocator) !F {
        return F.pseudo_random(&self.prng);
    }

    pub fn getIndexedTaggingSecretAsSender(
        self: *Txe,
        _: std.mem.Allocator,
        sender: proto.AztecAddress,
        recipient: proto.AztecAddress,
    ) !struct { app_tagging_secret: F, index: u32 } {
        _ = self;
        // For minimal implementation, return a deterministic but unique secret
        // In a real implementation, this would derive proper tagging secrets
        const combined = sender.value.add(recipient.value);
        const secret = combined.mul(F.from_int(0x1337));

        return .{
            .app_tagging_secret = secret,
            .index = 0,
        };
    }

    pub fn notifyCreatedNote(
        self: *Txe,
        _: std.mem.Allocator,
        storage_slot: F,
        note_type_id: u32,
        note_items: []F,
        note_hash: F,
        counter: u64,
    ) !void {
        _ = self;
        std.debug.print("notifyCreatedNote called with storage_slot: {x}, note_type_id: {}, note_items: {x}, note_hash: {x}, counter: {}\n", .{
            storage_slot,
            note_type_id,
            note_items,
            note_hash,
            counter,
        });
    }
};
