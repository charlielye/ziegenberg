const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const ForeignCallParam = @import("./param.zig").ForeignCallParam;
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");
const structDispatcher = @import("./struct_dispatcher.zig").structDispatcher;
const proto = @import("../../protocol/package.zig");
const ContractAbi = @import("../../nargo/contract.zig").ContractAbi;
const flattenToFields = @import("./flatten_to_fields.zig").flattenToFields;
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

    pub fn reset(_: *Txe, _: std.mem.Allocator) !void {
        std.debug.print("reset called!\n", .{});
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
        std.debug.print("Executing external function: {x}@{x} (static: {})\n", .{
            function_selector,
            target_contract_address,
            is_static_call,
        });

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
        try flattenToFields(PrivateContextInputs, private_context_inputs, &calldata);
        for (args) |arg| {
            try calldata.append(arg);
        }

        std.debug.print("calldata: {x}\n", .{calldata.items});

        const program = try cvm.deserialize(allocator, try function.getBytecode(allocator));

        var circuit_vm = try cvm.CircuitVm.init(allocator, &program, calldata.items, self.fc_handler);
        std.debug.print("entering vm", .{});
        circuit_vm.executeVm(0, false) catch |err| {
            if (err == error.Trapped) {
                // Print detailed error information
                circuit_vm.printBrilligTrapError(function.name, function_selector, "data/contracts/Counter.json" // TODO: Get actual artifact path
                );
            }
            return err;
        };
        std.debug.print("exiting vm", .{});

        // TODO: Extract public inputs from execution result
        // let publicInputs = extractPrivateCircuitPublicInputs(...);
        const start = function.sizeInFields();
        const public_inputs = try circuit_vm.witnesses.getWitnessesRange(
            allocator,
            start,
            start + proto.constants.PRIVATE_CIRCUIT_PUBLIC_INPUTS_LENGTH,
        );
        std.debug.print("Public inputs: {x}\n", .{public_inputs});

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
        return [2]F{ F.zero, F.zero };
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
        return std.fmt.allocPrint(allocator, "{x}:{x}", .{ contract_address.value.to_int(), slot.to_int() });
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
            return error.UnauthorizedCapsuleAccess;
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

        std.debug.print("storeCapsule: stored {} elements at slot {x} for contract {x}\n", .{
            capsule.len,
            slot,
            contract_address,
        });
    }

    pub fn loadCapsule(
        self: *Txe,
        allocator: std.mem.Allocator,
        contract_address: proto.AztecAddress,
        slot: F,
        _: u32, // response array length.
    ) !?[]F {
        // Check if contract is allowed to access this storage.
        if (!contract_address.eql(self.contract_address)) {
            std.debug.print("Contract {x} is not allowed to access {x}'s storage\n", .{
                contract_address,
                self.contract_address,
            });
            return error.UnauthorizedCapsuleAccess;
        }

        const key = try makeCapsuleKey(allocator, contract_address, slot);
        defer allocator.free(key);

        if (self.capsule_storage.get(key)) |capsule| {
            // Return a copy of the data
            const result = try allocator.alloc(F, capsule.len);
            @memcpy(result, capsule);

            std.debug.print("loadCapsule: loaded {} elements from slot {x} for contract {x}\n", .{
                capsule.len,
                slot,
                contract_address.value.to_int(),
            });

            return result;
        }

        std.debug.print("loadCapsule: no data at slot {x} for contract {x}\n", .{
            slot,
            contract_address,
        });

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
};
