const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const proto = @import("../protocol/package.zig");
const ContractAbi = @import("../nargo/contract.zig").ContractAbi;
const bvm = @import("../bvm/package.zig");
const cvm = @import("../cvm/package.zig");
const poseidon = @import("../poseidon2/poseidon2.zig");
const note_cache = @import("note_cache.zig");
const call_state = @import("call_state.zig");
const TxeState = @import("txe_state.zig").TxeState;
const Dispatcher = @import("dispatcher.zig").Dispatcher;

const constants = proto.constants;

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

const PrivateLog = call_state.PrivateLog;

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

        pub fn items(self: *const @This()) []const T {
            return self.data[0..self.claimed_length];
        }
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

// Generic BoundedVec type that matches Noir's BoundedVec serialization format
// A BoundedVec is serialized as [flattened_array_data, length]
// The flattened array is padded to max_size * element_size
pub fn BoundedVec(comptime T: type) type {
    return struct {
        items: []const T,
        allocator: std.mem.Allocator,
        max_size: usize, // Runtime max size
        element_size: usize, // Number of fields per element when flattened

        pub fn toForeignCallParams(self: @This()) [2]bvm.foreign_call.ForeignCallParam {
            std.debug.print("BoundedVec.toForeignCallParams called with {} items\n", .{self.items.len});
            // BoundedVec is always serialized as 2 params: [flattened_data, length]
            var result: [2]bvm.foreign_call.ForeignCallParam = undefined;

            // First param: flattened array of all data
            var flattened = std.ArrayList(bvm.foreign_call.ForeignCallParam).init(self.allocator);

            // Convert each item to ForeignCallParams and flatten
            for (self.items) |item| {
                if (@hasDecl(T, "toForeignCallParam")) {
                    const param = item.toForeignCallParam(self.allocator) catch unreachable;
                    switch (param) {
                        .Single => flattened.append(param) catch unreachable,
                        .Array => {
                            // Flatten nested arrays
                            for (param.Array) |elem| {
                                switch (elem) {
                                    .Single => flattened.append(elem) catch unreachable,
                                    .Array => unreachable, // Shouldn't have deeply nested arrays here
                                }
                            }
                        },
                    }
                } else {
                    // For simple types, just convert directly
                    const params = bvm.foreign_call.marshal.structToForeignCallParams(self.allocator, item) catch unreachable;
                    for (params) |param| {
                        switch (param) {
                            .Single => flattened.append(param) catch unreachable,
                            .Array => {
                                for (param.Array) |elem| {
                                    flattened.append(elem) catch unreachable;
                                }
                            },
                        }
                    }
                }
            }

            // Pad the array to max_size * element_size
            const total_expected_size = self.max_size * self.element_size;
            const current_size = flattened.items.len;

            if (current_size < total_expected_size) {
                // Add padding with zeros
                var i = current_size;
                while (i < total_expected_size) : (i += 1) {
                    flattened.append(.{ .Single = 0 }) catch unreachable;
                }
            }

            result[0] = .{ .Array = flattened.toOwnedSlice() catch unreachable };

            // Second param: actual length of the bounded vector (number of items, not flattened size)
            result[1] = .{ .Single = self.items.len };

            return result;
        }
    };
}

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

pub const TxeImpl = struct {
    allocator: std.mem.Allocator,
    // Foreign call handler.
    fc_handler: *Dispatcher = undefined,
    // Random number generator.
    prng: *std.Random.DefaultPrng,
    state: TxeState,
    contract_artifacts_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, contract_artifacts_path: []const u8) !TxeImpl {
        const prng = try allocator.create(std.Random.DefaultPrng);
        prng.* = std.Random.DefaultPrng.init(12345);

        const txe_state = try TxeState.init(allocator);

        return TxeImpl{
            .allocator = allocator,
            .prng = prng,
            .state = txe_state,
            .contract_artifacts_path = contract_artifacts_path,
        };
    }

    pub fn deinit(self: *TxeImpl) void {
        self.state.deinit();
        self.allocator.destroy(self.prng);
    }

    pub fn reset(self: *TxeImpl, _: std.mem.Allocator) !void {
        std.debug.print("reset called!\n", .{});

        // By the time reset is called, we should already be at the root state
        // since child states are cleaned up in defer blocks
        self.state.current_state.deinit();
        self.state.current_state.* = call_state.CallState.init(self.allocator);

        std.debug.print("reset: cleared capsule storage and reset state\n", .{});
    }

    pub fn createAccount(self: *TxeImpl, _: std.mem.Allocator, secret: F) !struct {
        address: proto.AztecAddress,
        public_keys: proto.PublicKeys,
    } {
        std.debug.print("createAccount called: {x}\n", .{secret});

        // TODO: Why do we use the secret for both args here?
        // TS code unhelpfully just says "Footgun!"...
        const complete_address = proto.CompleteAddress.fromSecretKeyAndPartialAddress(
            secret,
            proto.PartialAddress.init(secret),
        );

        // Store the account for later retrieval
        try self.state.accounts.put(complete_address.aztec_address, complete_address);

        return .{
            .address = complete_address.aztec_address,
            .public_keys = complete_address.public_keys,
        };
    }

    pub fn getContractAddress(self: *TxeImpl, _: std.mem.Allocator) !proto.AztecAddress {
        return self.state.current_state.contract_address;
    }

    pub fn setContractAddress(self: *TxeImpl, _: std.mem.Allocator, address: proto.AztecAddress) !void {
        self.state.current_state.contract_address = address;
        std.debug.print("setContractAddress: {x}\n", .{address});
    }

    pub fn deploy(
        self: *TxeImpl,
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
            self.contract_artifacts_path,
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

        try self.state.contract_artifact_cache.put(contract_abi.class_id, contract_abi);
        try self.state.contract_instance_cache.put(contract_instance.address, contract_instance);

        std.debug.print("Deployed contract {s} with class id {x} at address {x}\n", .{
            contract_name,
            contract_abi.class_id,
            contract_instance.address,
        });

        self.state.block_number += 1;

        // Get public key fields using toFields
        const key_fields = public_keys.toFields();

        // Build result array using array concatenation
        return [4]F{
            contract_instance.salt,
            contract_instance.deployer.value,
            contract_instance.current_contract_class_id,
            contract_instance.initialization_hash,
        } ++ key_fields;
    }

    pub fn getBlockNumber(self: *TxeImpl, _: std.mem.Allocator) !u64 {
        return self.state.block_number;
    }

    pub fn getTimestamp(self: *TxeImpl, _: std.mem.Allocator) !u64 {
        return self.state.timestamp;
    }

    pub fn getVersion(self: *TxeImpl, _: std.mem.Allocator) !F {
        return self.state.version;
    }

    pub fn getChainId(self: *TxeImpl, _: std.mem.Allocator) !F {
        return self.state.chain_id;
    }

    pub fn getPrivateContextInputs(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        block_number: ?u32,
        timestamp: ?u64,
    ) !PrivateContextInputs {
        return self.getPrivateContextInputsInternal(
            allocator,
            block_number,
            timestamp,
            self.state.current_state.side_effect_counter,
            false,
        );
    }

    fn getPrivateContextInputsInternal(
        self: *TxeImpl,
        _: std.mem.Allocator,
        block_number: ?u32,
        timestamp: ?u64,
        side_effect_counter: u32,
        is_static_call: bool,
    ) !PrivateContextInputs {
        const result = PrivateContextInputs{
            .tx_context = .{
                .chain_id = F.from_int(TxeState.CHAIN_ID),
                .version = F.from_int(TxeState.ROLLUP_VERSION),
            },
            .historical_header = .{ .global_variables = .{
                .block_number = block_number orelse self.state.block_number,
                .timestamp = timestamp orelse self.state.timestamp - TxeState.AZTEC_SLOT_DURATION,
            } },
            .call_context = .{
                .msg_sender = self.state.current_state.msg_sender,
                .contract_address = self.state.current_state.contract_address,
                .function_selector = self.state.current_state.function_selector,
                .is_static_call = is_static_call,
            },
            .start_side_effect_counter = side_effect_counter,
        };
        return result;
    }

    // Since the argument is a slice, noir automatically adds a length field to oracle call.
    pub fn storeInExecutionCache(
        self: *TxeImpl,
        _: std.mem.Allocator,
        _: F,
        args: []F,
        hash: F,
    ) !void {
        std.debug.print("storeInExecutionCache called with args: {x} and hash: {x}\n", .{
            args,
            hash,
        });
        try self.state.current_state.execution_cache.put(hash, try self.allocator.dupe(F, args));
    }

    pub fn loadFromExecutionCache(
        self: *TxeImpl,
        _: std.mem.Allocator,
        args_hash: F,
    ) ![]F {
        // Special case: hash 0 returns empty array
        if (args_hash.eql(F.zero)) {
            return &[_]F{};
        }

        if (self.state.current_state.getFromExecutionCache(args_hash)) |result| {
            std.debug.print("loadFromExecutionCache: Found cached args with hash {x}\n", .{args_hash});
            return result;
        }

        return &[_]F{};
    }

    /// Executes an external/private function call on a target contract.
    pub fn callPrivateFunction(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        target_contract_address: proto.AztecAddress,
        function_selector: FunctionSelector,
        args_hash: F,
        side_effect_counter: u32,
        is_static_call: bool,
    ) ![2]F {
        std.debug.print("callPrivateFunction called with:\n", .{});
        std.debug.print("  target: {x}\n", .{target_contract_address});
        std.debug.print("  selector: {x}\n", .{function_selector});
        std.debug.print("  args_hash: {x}\n", .{args_hash});
        std.debug.print("  side_effect_counter: {}\n", .{side_effect_counter});
        std.debug.print("  is_static_call: {}\n", .{is_static_call});
        std.debug.print("  current_state.parent: {}\n", .{self.state.current_state.parent != null});

        // Create child state for the nested call
        const child_state = try self.state.current_state.createChild(
            self.allocator,
            target_contract_address,
            function_selector,
            is_static_call,
        );
        child_state.side_effect_counter = side_effect_counter;

        // Save current state and switch to child
        const saved_current = self.state.current_state;
        self.state.current_state = child_state;

        // Retrieve the function to execute from the target contract's ABI.
        const contract_instance = self.state.contract_instance_cache.get(target_contract_address) orelse {
            std.debug.print("Contract instance not found for address: {x}\n", .{target_contract_address});
            return error.ContractInstanceNotFound;
        };
        const function = contract_instance.abi.getFunctionBySelector(function_selector) catch |err| {
            std.debug.print("Function not found for selector: {x} in contract {x}\n", .{ function_selector, target_contract_address });
            return err;
        };

        // Set the contract ABI reference for debugging
        child_state.contract_abi = &contract_instance.abi;

        std.debug.print("Executing external function: {s}@{x} (static: {})\n", .{
            function.name,
            target_contract_address,
            is_static_call,
        });

        const args = self.state.current_state.getFromExecutionCache(args_hash) orelse {
            std.debug.print("No args found for hash {x}\n", .{args_hash});
            return error.ArgsNotFound;
        };

        const private_context_inputs = try self.getPrivateContextInputsInternal(
            self.allocator,
            self.state.block_number - 1,
            self.state.timestamp - TxeState.AZTEC_SLOT_DURATION,
            side_effect_counter,
            is_static_call,
        );

        // Build calldata from private context inputs and function arguments.
        var calldata = std.ArrayList(F).init(allocator);
        defer calldata.deinit();
        try bvm.foreign_call.convert.structToFields(PrivateContextInputs, private_context_inputs, &calldata);
        for (args) |arg| {
            try calldata.append(arg);
        }

        const program = try cvm.deserialize(allocator, try function.getBytecode(allocator));

        // Execute private function in nested circuit vm.
        var circuit_vm = try cvm.CircuitVm(Dispatcher).init(allocator, &program, calldata.items, self.fc_handler);

        // Set artifact path and function name on CircuitVm for nested BrilligCalls
        circuit_vm.artifact_path = contract_instance.abi.artifact_path;
        circuit_vm.function_name = function.name;

        std.debug.print("callPrivateFunction: Entering nested cvm (function: {s})\n", .{function.name});
        circuit_vm.executeVm(
            0,
            .{ .debug_ctx = null },
        ) catch |err| {
            // If this was a trap, capture the error context in the child state
            if (err == error.Trapped and circuit_vm.brillig_error_context != null) {
                child_state.execution_error = circuit_vm.brillig_error_context;
            }
            return err;
        };
        std.debug.print("callPrivateFunction: Exited nested cvm\n", .{});

        // Extract public inputs from execution result.
        const start = function.sizeInFields() + constants.PRIVATE_CONTEXT_INPUTS_LENGTH;
        const public_inputs_fields = try circuit_vm.witnesses.getWitnessesRange(
            allocator,
            start,
            start + constants.PRIVATE_CIRCUIT_PUBLIC_INPUTS_LENGTH,
        );
        const private_circuit_public_inputs = try bvm.foreign_call.convert.fieldsToStruct(
            PrivateCircuitPublicInputs,
            public_inputs_fields,
        );

        const end_side_effect_counter = private_circuit_public_inputs.end_side_effect_counter;
        const returns_hash = private_circuit_public_inputs.returns_hash;

        // Apply side effects to child state.
        child_state.side_effect_counter = @intCast(end_side_effect_counter.to_int() + 1);

        // Add private logs to child state.
        for (private_circuit_public_inputs.private_logs.items()) |private_log| {
            var log = private_log.log;
            log.fields[0] = poseidon.hash(&[_]F{ target_contract_address.value, log.fields[0] });
            try child_state.private_logs.append(log);
        }

        // Add nullifiers from public inputs to child state
        for (private_circuit_public_inputs.nullifiers.items()) |nullifier| {
            if (!nullifier.value.eql(F.zero)) {
                try child_state.nullifiers.append(nullifier.value);
            }
        }

        // Success path: merge state and cleanup
        if (!is_static_call) {
            try saved_current.mergeChild(child_state);
        }
        child_state.deinit();
        self.allocator.destroy(child_state);

        // Restore parent state only on success
        self.state.current_state = saved_current;

        return [2]F{ end_side_effect_counter, returns_hash };
    }

    pub fn getContractInstance(
        self: *TxeImpl,
        _: std.mem.Allocator,
        address: proto.AztecAddress,
    ) !struct {
        salt: F,
        deployer: proto.AztecAddress,
        contract_class_id: F,
        initialization_hash: F,
        public_keys: proto.PublicKeys,
    } {
        const instance = self.state.contract_instance_cache.get(address);
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

    pub fn storeCapsule(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        slot: F,
        capsule: []F,
    ) !void {
        // Check if contract is allowed to access this storage.
        if (!contract_address.eql(self.state.current_state.contract_address)) {
            std.debug.print("Contract {x} is not allowed to access {x}'s storage\n", .{
                self.state.current_state.contract_address,
                contract_address,
            });
            return error.UnauthorizedContractAccess;
        }

        // Store using the new CallState method
        try self.state.current_state.storeCapsuleAtSlot(allocator, slot, capsule);
    }

    pub fn loadCapsule(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        slot: F,
        response_len: u32,
    ) !?[]F {
        _ = response_len;

        // Authorization check - contracts can only access their own capsule storage
        if (!contract_address.eql(self.state.current_state.contract_address)) {
            std.debug.print("Capsule access denied: Contract {x} is not allowed to access {x}'s storage\n", .{
                self.state.current_state.contract_address,
                contract_address,
            });
            return error.UnauthorizedCapsuleAccess;
        }

        return try self.state.current_state.loadCapsuleAtSlot(allocator, slot);
    }

    pub fn debugLog(
        _: *TxeImpl,
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
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        pending_tagged_log_array_base_slot: F,
    ) !void {
        // The TypeScript implementation populates this array with tagged logs from the blockchain.
        // For our minimal implementation, we'll store an empty array.
        var empty_array = [_]F{F.zero};

        // Store the empty array at the base slot.
        try self.state.current_state.storeCapsuleAtSlot(allocator, pending_tagged_log_array_base_slot, empty_array[0..]);
    }

    pub fn bulkRetrieveLogs(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        log_retrieval_requests_array_base_slot: F,
        log_retrieval_responses_array_base_slot: F,
    ) !void {
        // Authorization check - contracts can only access their own capsule storage
        if (!contract_address.eql(self.state.current_state.contract_address)) {
            std.debug.print("Capsule access denied: Contract {x} is not allowed to access {x}'s storage\n", .{
                self.state.current_state.contract_address,
                contract_address,
            });
            return error.UnauthorizedCapsuleAccess;
        }

        // Load the requests array to get the count
        var num_requests: u32 = 0;
        if (try self.state.current_state.loadCapsuleAtSlot(allocator, log_retrieval_requests_array_base_slot)) |data| {
            defer allocator.free(data);
            if (data.len > 0) {
                num_requests = @intCast(data[0].to_int());
            }
        }

        // For minimal implementation, create empty responses for each request
        var length_array = [_]F{F.from_int(num_requests)};
        try self.state.current_state.storeCapsuleAtSlot(allocator, log_retrieval_responses_array_base_slot, length_array[0..]);

        // Store Option::none for each response
        var none_response = [_]F{F.zero};
        var i: u32 = 0;
        while (i < num_requests) : (i += 1) {
            const response_slot = log_retrieval_responses_array_base_slot.add(F.from_int(i + 1));
            try self.state.current_state.storeCapsuleAtSlot(allocator, response_slot, none_response[0..]);
        }
    }

    pub fn validateEnqueuedNotesAndEvents(
        self: *TxeImpl,
        _: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        _: F,
        _: F,
    ) !void {
        // Check authorization.
        if (!contract_address.eql(self.state.current_state.contract_address)) {
            return error.UnauthorizedContractAccess;
        }
    }

    pub fn getRandomField(self: *TxeImpl, _: std.mem.Allocator) !F {
        return F.pseudo_random(self.prng);
    }

    pub fn getIndexedTaggingSecretAsSender(
        self: *TxeImpl,
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

    pub fn getPublicKeysAndPartialAddress(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        address: proto.AztecAddress,
    ) ![]F {
        // First check if it's an account we created
        if (self.state.accounts.get(address)) |complete_address| {
            var result = std.ArrayList(F).init(allocator);

            // Get all public key fields using toFields
            const key_fields = complete_address.public_keys.toFields();
            try result.appendSlice(&key_fields);

            // Add partial address
            try result.append(complete_address.partial_address.value);

            return result.toOwnedSlice();
        }

        // Look up the contract instance to get its public keys
        const instance = self.state.contract_instance_cache.get(address) orelse {
            // If not found anywhere, return default public keys with a deterministic partial address
            var result = std.ArrayList(F).init(allocator);
            const default_keys = proto.PublicKeys.default();

            // Get all public key fields using toFields
            const key_fields = default_keys.toFields();
            try result.appendSlice(&key_fields);

            // Add partial address
            try result.append(address.value.mul(F.from_int(0x42)));

            return result.toOwnedSlice();
        };

        // For contracts, return their stored public keys
        var result = std.ArrayList(F).init(allocator);

        // Get all public key fields using toFields
        const key_fields = instance.public_keys.toFields();
        try result.appendSlice(&key_fields);

        // Add partial address
        const partial_address = proto.PartialAddress.compute(
            instance.current_contract_class_id,
            instance.salt,
            instance.initialization_hash,
            instance.deployer,
        ).value;
        try result.append(partial_address);

        return result.toOwnedSlice();
    }

    pub fn simulateUtilityFunction(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        target_contract_address: proto.AztecAddress,
        function_selector: FunctionSelector,
        args_hash: F,
    ) !F {
        // Create child state for the utility function (static call)
        const child_state = try self.state.current_state.createChild(self.allocator, target_contract_address, function_selector, true);
        child_state.side_effect_counter = self.state.current_state.side_effect_counter;

        // Save current state and switch to child
        const saved_current = self.state.current_state;
        self.state.current_state = child_state;

        // Retrieve the function to execute from the target contract's ABI.
        const contract_instance = self.state.contract_instance_cache.get(target_contract_address) orelse {
            return error.ContractInstanceNotFound;
        };

        const function = try contract_instance.abi.getFunctionBySelector(function_selector);

        // Set the contract ABI reference for debugging
        child_state.contract_abi = &contract_instance.abi;
        std.debug.print("simulateUtilityFunction called with target: {x}, selector: {x}, name: {s}, args_hash: {x}\n", .{
            target_contract_address,
            function_selector,
            function.name,
            args_hash,
        });

        const calldata = self.state.current_state.getFromExecutionCache(args_hash) orelse {
            std.debug.print("No args found for hash {x}\n", .{args_hash});
            return error.ArgsNotFound;
        };

        const program = try cvm.deserialize(allocator, try function.getBytecode(allocator));

        // Execute utility function in nested circuit vm.
        var circuit_vm = try cvm.CircuitVm(Dispatcher).init(allocator, &program, calldata, self.fc_handler);
        std.debug.print("simulateUtilityFunction: Entering nested cvm with contract_address {x}\n", .{self.state.current_state.contract_address});
        circuit_vm.executeVm(0, .{ .debug_ctx = null }) catch |err| {
            // If this was a trap, capture the error context in the child state
            if (err == error.Trapped and circuit_vm.brillig_error_context != null) {
                child_state.execution_error = circuit_vm.brillig_error_context;
            }
            return err;
        };
        std.debug.print("simulateUtilityFunction: Exited nested cvm\n", .{});

        const return_values = program.functions[0].return_values;
        // Assert program return value witness indices are contiguous.
        for (return_values, 0..) |return_value, i| {
            if (return_value != return_values[0] + i) {
                return error.InvalidWitnessIndex;
            }
        }

        // Note use of long lived allocator as we will cache the result.
        const return_witness = try circuit_vm.witnesses.getWitnessesRange(self.allocator, return_values[0], return_values[0] + return_values.len);
        std.debug.print("simulateUtilityFunction: Retrieved return witness: {x}\n", .{return_witness});
        const return_hash = poseidon.hash_with_generator(allocator, return_witness, @intFromEnum(constants.GeneratorIndex.function_args));

        // Store in the parent state's execution cache, not the child's
        try saved_current.execution_cache.put(return_hash, return_witness);

        std.debug.print("simulateUtilityFunction: Returning hash {x} for function {s} at address {x}\n", .{
            return_hash,
            function.name,
            target_contract_address,
        });

        // Success path: cleanup (utility functions are always static)
        child_state.deinit();
        self.allocator.destroy(child_state);

        // Restore parent state only on success
        self.state.current_state = saved_current;

        return return_hash;
    }

    // Specific type for getNotes return value that includes metadata
    const RetrievedNoteWithMetadata = struct {
        contract_address: proto.AztecAddress,
        note_nonce: F,
        nonzero_note_hash_counter: u256,
        note: proto.Note,
    };

    pub fn getNotes(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        storage_slot: F,
        num_selects: u32,
        select_by_indexes: []const u32,
        select_by_offsets: []const u32,
        select_by_lengths: []const u32,
        select_values: []const F,
        select_comparators: []const u8,
        sort_by_indexes: []const u32,
        sort_by_offsets: []const u32,
        sort_by_lengths: []const u32,
        sort_order: []const u8,
        limit: u32,
        offset: u32,
        status: u8,
        max_notes: u32,
        packed_retrieved_note_length: u32,
    ) !BoundedVec(RetrievedNoteWithMetadata) {
        _ = status; // Not used in this minimal implementation

        // Get pending notes from cache (already filtered for nullifiers)
        const pending_notes = try self.state.current_state.getNotes(
            allocator,
            self.state.current_state.contract_address,
            storage_slot,
        );
        defer allocator.free(pending_notes);
        std.debug.print("getNotes: Found {} notes for contract {x} at slot {x}\n", .{
            pending_notes.len,
            self.state.current_state.contract_address,
            storage_slot,
        });

        // Build select criteria
        const actual_num_selects = @min(num_selects, select_by_indexes.len);
        var selects = try allocator.alloc(note_cache.SelectCriteria, actual_num_selects);

        for (0..actual_num_selects) |i| {
            selects[i] = .{
                .selector = .{
                    .index = select_by_indexes[i],
                    .offset = select_by_offsets[i],
                    .length = select_by_lengths[i],
                },
                .value = select_values[i],
                .comparator = @enumFromInt(select_comparators[i]),
            };
        }

        // Apply selection filters
        var selected_notes = try note_cache.selectNotes(allocator, pending_notes, selects);
        defer selected_notes.deinit();

        // Build sort criteria
        var sorts = try allocator.alloc(note_cache.SortCriteria, sort_by_indexes.len);

        for (0..sorts.len) |i| {
            sorts[i] = .{
                .selector = .{
                    .index = sort_by_indexes[i],
                    .offset = sort_by_offsets[i],
                    .length = sort_by_lengths[i],
                },
                .order = @enumFromInt(sort_order[i]),
            };
        }

        // Apply sorting
        note_cache.sortNotes(selected_notes.items, sorts);

        // Apply offset and limit
        const start_idx = @min(offset, selected_notes.items.len);
        const end_idx = if (limit > 0) @min(start_idx + limit, selected_notes.items.len) else selected_notes.items.len;

        // Convert NoteData to RetrievedNoteWithMetadata
        const result = try allocator.alloc(RetrievedNoteWithMetadata, end_idx - start_idx);
        for (selected_notes.items[start_idx..end_idx], 0..) |note_data, i| {
            result[i] = .{
                .contract_address = note_data.contract_address,
                .note_nonce = note_data.note_nonce,
                .nonzero_note_hash_counter = 1, // All notes from getNotes are transient
                .note = note_data.note,
            };
        }

        std.debug.print("getNotes: Returning {} notes for contract {x} at slot {x}\n", .{
            result.len,
            self.state.current_state.contract_address,
            storage_slot,
        });

        return BoundedVec(RetrievedNoteWithMetadata){
            .items = result,
            .allocator = allocator,
            .max_size = max_notes,
            .element_size = packed_retrieved_note_length,
        };
    }

    pub fn notifyCreatedNote(
        self: *TxeImpl,
        _: std.mem.Allocator,
        storage_slot: F,
        note_type_id: u32,
        note_items: []const F,
        note_hash: F,
        counter: u32,
    ) !void {
        _ = note_type_id; // Not used in this implementation

        const note_data = proto.NoteData{
            .note = proto.Note.init(note_items),
            .contract_address = self.state.current_state.contract_address,
            .storage_slot = storage_slot,
            .note_nonce = F.from_int(counter), // Using counter as nonce for simplicity
            .note_hash = note_hash,
            .siloed_nullifier = F.zero, // Will be computed when note is nullified
        };

        try self.state.current_state.note_cache.addNote(note_data);
        std.debug.print("notifyCreatedNote: note_cache.addNote completed\n", .{});

        std.debug.print("notifyCreatedNote: Added note with hash {x} at slot {x}, counter {}, contract_address {x}\n", .{
            note_hash,
            storage_slot,
            counter,
            self.state.current_state.contract_address,
        });
    }

    pub fn notifyCreatedNullifier(
        self: *TxeImpl,
        _: std.mem.Allocator,
        inner_nullifier: F,
    ) !void {
        // Silo the nullifier to the current contract
        const siloed_nullifier = poseidon.hash(&[_]F{
            self.state.current_state.contract_address.value,
            inner_nullifier,
        });

        // Add the nullifier to the current state
        try self.state.current_state.nullifiers.append(siloed_nullifier);

        std.debug.print("notifyCreatedNullifier: Added nullifier {x} (siloed: {x}) for contract {x}\n", .{
            inner_nullifier,
            siloed_nullifier,
            self.state.current_state.contract_address,
        });
    }

    pub fn advanceBlocksBy(
        self: *TxeImpl,
        _: std.mem.Allocator,
        blocks: F,
    ) !void {
        const n_blocks = @as(u32, @intCast(blocks.to_int()));
        std.debug.print("advanceBlocksBy: time traveling {} blocks\n", .{n_blocks});

        var i: u32 = 0;
        while (i < n_blocks) : (i += 1) {
            // Advance block number
            self.state.block_number += 1;

            // Also advance timestamp by one slot duration
            self.state.timestamp += TxeState.AZTEC_SLOT_DURATION;

            std.debug.print("advanceBlocksBy: advanced to block {} at timestamp {}\n", .{
                self.state.block_number,
                self.state.timestamp,
            });
        }
    }

    pub fn incrementAppTaggingSecretIndexAsSender(
        _: *TxeImpl,
        _: std.mem.Allocator,
        _: proto.AztecAddress,
        _: proto.AztecAddress,
    ) !void {
        // This function increments the tagging secret index for a sender
        // For our minimal implementation, we'll just log and continue
        std.debug.print("incrementAppTaggingSecretIndexAsSender: called (no-op in minimal implementation)\n", .{});
    }

    pub fn privateCallNewFlow(
        self: *TxeImpl,
        allocator: std.mem.Allocator,
        from: proto.AztecAddress,
        target_contract_address: proto.AztecAddress,
        function_selector: FunctionSelector,
        args_len: u32,
        args: []F,
        args_hash: F,
        is_static_call: bool,
    ) ![3]F {
        _ = from; // The msg_sender is managed by the TXE context
        _ = args_len; // We have the actual args slice

        // TODO: Step 1 - Get function artifact
        // - Implement contractDataProvider.getFunctionArtifact(targetContractAddress, functionSelector)
        // - This should look up the contract ABI and find the specific function
        // - Throw error if artifact is undefined

        // TODO: Step 2 - Create proper contexts
        // - Create CallContext with (from, targetContractAddress, functionSelector, isStaticCall)
        // - Create GasLimits with DEFAULT_GAS_LIMIT and MAX_L2_GAS_PER_TX_PUBLIC_PORTION
        // - Create teardownGasLimits with DEFAULT_TEARDOWN_GAS_LIMIT
        // - Create GasSettings from gas limits and empty gas fees
        // - Create TxContext with CHAIN_ID, ROLLUP_VERSION, and gasSettings

        // TODO: Step 3 - Get block header
        // - Implement getBlockHeader() to get the current block's header
        // - This should include the full block state for the historical header

        // TODO: Step 4 - Create execution note cache
        // - Create ExecutionNoteCache with getTxRequestHash()
        // - This is different from the simple note cache we have now

        // TODO: Step 5 - Create PrivateExecutionOracle
        // - Create full private execution context with:
        //   - argsHash, txContext, callContext, blockHeader
        //   - Empty auth witness arrays
        //   - HashedValuesCache
        //   - ExecutionNoteCache
        //   - Oracle interface (self)
        //   - Simulator
        //   - Initial counters (0, 1)

        // Store the args in the execution cache for the called function to retrieve
        try self.storeInExecutionCache(allocator, F.from_int(args.len), args, args_hash);

        // TODO: Step 6 - Execute private function with full simulator
        // - Replace callPrivateFunction with executePrivateFunction that returns PrivateExecutionResult
        // - This should handle all the complex execution logic
        // - Wrap in try/catch to handle simulation errors properly

        // TODO: Step 7 - Process execution results
        // - Call noteCache.finish() to get usedTxRequestHashForNonces
        // - Calculate firstNullifierHint (Fr.ZERO if usedTxRequestHashForNonces, else first nullifier)
        // - Collect nested public call requests from execution result
        // - Load calldata for each public call request from execution cache
        // - Create PrivateExecutionResult with all the data

        // Use existing callPrivateFunction implementation (temporary)
        const result = try self.callPrivateFunction(
            allocator,
            target_contract_address,
            function_selector,
            args_hash,
            self.state.current_state.side_effect_counter,
            is_static_call,
        );

        const end_side_effect_counter = result[0];
        const returns_hash = result[1];

        // TODO: Step 8 - Handle return values
        // - If executionResult has returnValues:
        //   - Compute hash of return values using computeVarArgsHash
        //   - Store return values in execution cache with the hash

        // TODO: Step 9 - Generate simulated proving result
        // - Calculate nonceGenerator (firstNullifier or getTxRequestHash if no nullifiers)
        // - Call generateSimulatedProvingResult(result, nonceGenerator, contractDataProvider)
        // - Extract publicInputs from the result

        // TODO: Step 10 - Create global variables
        // - Create makeGlobalVariables() with current block number, timestamp, and empty gas fees

        // TODO: Step 11 - Set up public execution infrastructure
        // - Create PublicContractsDB with TXEPublicContractDataSource
        // - Create GuardedMerkleTreeOperations wrapping baseFork
        // - Create PublicTxSimulator with merkle trees, contracts DB, and globals
        // - Create PublicProcessor with all the components

        // TODO: Step 12 - Create transaction
        // - Create Tx with publicInputs, empty proof, empty logs, and publicFunctionCalldata

        // TODO: Step 13 - Handle static call checkpointing
        // - If isStaticCall, create ForkCheckpoint before processing

        // TODO: Step 14 - Process public functions
        // - Call processor.process([tx]) to execute public functions
        // - Check for failed transactions and throw error if any failed

        // TODO: Step 15 - For static calls, revert and return early
        // - If isStaticCall:
        //   - Revert the checkpoint
        //   - Return early with endSideEffectCounter, returnsHash, and txRequestHash

        // TODO: Step 16 - Create L2 block and update state (non-static calls only)
        // - Create TxEffect from processed transaction results
        // - Copy noteHashes, nullifiers, logs, and publicDataWrites
        // - Set txHash to Fr(blockNumber)
        // - Create Body with txEffect
        // - Create L2Block with snapshot, header, and body

        // TODO: Step 17 - Update merkle trees
        // - Append L1_TO_L2 messages (zeros) to the message tree
        // - Get updated state reference from fork
        // - Get archive tree info
        // - Create BlockHeader with all the data
        // - Update archive with the new block header

        // TODO: Step 18 - Update state machine
        // - Call stateMachine.handleL2Block(l2Block) to update state

        // TODO: Step 19 - Get proper transaction hash
        // - Call getTxRequestHash() for the actual transaction hash
        // - This should be more complex than our simple hash

        // Generate a tx hash - for minimal implementation, use a simple hash of the function call parameters
        const tx_hash = poseidon.hash(&[_]F{
            target_contract_address.value,
            F.from_int(function_selector),
            args_hash,
            F.from_int(self.state.block_number),
        });

        // TODO: Step 20 - Advance state (non-static calls only)
        // - Increment block number
        // - Advance timestamp by AZTEC_SLOT_DURATION

        return [3]F{ end_side_effect_counter, returns_hash, tx_hash };
    }
};
