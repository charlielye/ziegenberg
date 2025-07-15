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
const fieldsToStruct = @import("./struct_field_conversion.zig").fieldsToStruct;
const cvm = @import("../../cvm/package.zig");
const ForeignCallDispatcher = @import("dispatcher.zig").Dispatcher;
const poseidon = @import("../../poseidon2/poseidon2.zig");

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

// Note-related structures
const Note = struct {
    items: []const F,

    pub fn init(items: []const F) Note {
        return .{ .items = items };
    }
};

pub const NoteData = struct {
    note: Note,
    contract_address: proto.AztecAddress,
    storage_slot: F,
    note_nonce: F,
    note_hash: F,
    siloed_nullifier: F,

    pub fn toForeignCallParam(self: NoteData, allocator: std.mem.Allocator) !ForeignCallParam {
        var fields = std.ArrayList(ForeignCallParam).init(allocator);

        // Add note items
        for (self.note.items) |item| {
            try fields.append(.{ .Single = item.to_int() });
        }

        // Add other fields
        try fields.append(.{ .Single = self.contract_address.value.to_int() });
        try fields.append(.{ .Single = self.storage_slot.to_int() });
        try fields.append(.{ .Single = self.note_nonce.to_int() });
        try fields.append(.{ .Single = self.note_hash.to_int() });
        try fields.append(.{ .Single = self.siloed_nullifier.to_int() });

        return .{ .Array = try fields.toOwnedSlice() };
    }
};

const PropertySelector = struct {
    index: u32,
    offset: u32,
    length: u32,
};

const Comparator = enum(u8) {
    EQ = 1,
    NEQ = 2,
    LT = 3,
    LTE = 4,
    GT = 5,
    GTE = 6,
};

const SortOrder = enum(u8) {
    NADA = 0,
    DESC = 1,
    ASC = 2,
};

// Simple in-memory note cache
const NoteCache = struct {
    // Maps contract_address -> storage_slot -> notes
    notes: std.AutoHashMap(proto.AztecAddress, std.AutoHashMap(F, std.ArrayList(NoteData))),
    // Maps contract_address -> nullifiers
    nullifiers: std.AutoHashMap(proto.AztecAddress, std.AutoHashMap(F, void)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NoteCache {
        return .{
            .notes = std.AutoHashMap(proto.AztecAddress, std.AutoHashMap(F, std.ArrayList(NoteData))).init(allocator),
            .nullifiers = std.AutoHashMap(proto.AztecAddress, std.AutoHashMap(F, void)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NoteCache) void {
        var it = self.notes.iterator();
        while (it.next()) |entry| {
            var storage_it = entry.value_ptr.iterator();
            while (storage_it.next()) |storage_entry| {
                storage_entry.value_ptr.deinit();
            }
            entry.value_ptr.deinit();
        }
        self.notes.deinit();

        var null_it = self.nullifiers.iterator();
        while (null_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.nullifiers.deinit();
    }

    pub fn addNote(self: *NoteCache, note_data: NoteData) !void {
        const contract_entry = try self.notes.getOrPut(note_data.contract_address);
        if (!contract_entry.found_existing) {
            contract_entry.value_ptr.* = std.AutoHashMap(F, std.ArrayList(NoteData)).init(self.allocator);
        }

        const storage_entry = try contract_entry.value_ptr.getOrPut(note_data.storage_slot);
        if (!storage_entry.found_existing) {
            storage_entry.value_ptr.* = std.ArrayList(NoteData).init(self.allocator);
        }

        try storage_entry.value_ptr.append(note_data);
    }

    pub fn getNotes(self: *NoteCache, contract_address: proto.AztecAddress, storage_slot: F) []const NoteData {
        const contract_map = self.notes.get(contract_address) orelse return &[_]NoteData{};
        const note_list = contract_map.get(storage_slot) orelse return &[_]NoteData{};
        return note_list.items;
    }

    pub fn addNullifier(self: *NoteCache, contract_address: proto.AztecAddress, nullifier: F) !void {
        const entry = try self.nullifiers.getOrPut(contract_address);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.AutoHashMap(F, void).init(self.allocator);
        }
        try entry.value_ptr.put(nullifier, {});
    }

    pub fn hasNullifier(self: *NoteCache, contract_address: proto.AztecAddress, nullifier: F) bool {
        const nullifier_map = self.nullifiers.get(contract_address) orelse return false;
        return nullifier_map.contains(nullifier);
    }
};

// Helper functions for note selection
fn selectPropertyFromPackedNoteContent(note_data: []const F, selector: PropertySelector) !F {
    if (selector.index >= note_data.len) return error.InvalidSelector;

    // For now, just return the field at the specified index
    // TODO: Implement proper bit-level extraction for packed fields
    return note_data[selector.index];
}

fn compareNoteValue(note_value: F, compare_value: F, comparator: Comparator) bool {
    return switch (comparator) {
        .EQ => note_value.eql(compare_value),
        .NEQ => !note_value.eql(compare_value),
        .LT => note_value.lt(compare_value),
        .LTE => note_value.lt(compare_value) or note_value.eql(compare_value),
        .GT => !note_value.lt(compare_value) and !note_value.eql(compare_value),
        .GTE => !note_value.lt(compare_value),
    };
}

const SelectCriteria = struct {
    selector: PropertySelector,
    value: F,
    comparator: Comparator,
};

const SortCriteria = struct {
    selector: PropertySelector,
    order: SortOrder,
};

fn selectNotes(allocator: std.mem.Allocator, notes: []const NoteData, selects: []const SelectCriteria) !std.ArrayList(NoteData) {
    var result = std.ArrayList(NoteData).init(allocator);

    for (notes) |note_data| {
        var matches = true;
        for (selects) |select| {
            const note_value = selectPropertyFromPackedNoteContent(note_data.note.items, select.selector) catch {
                matches = false;
                break;
            };
            if (!compareNoteValue(note_value, select.value, select.comparator)) {
                matches = false;
                break;
            }
        }
        if (matches) {
            try result.append(note_data);
        }
    }

    return result;
}

fn sortNotesRecursive(a: []const F, b: []const F, sorts: []const SortCriteria, level: usize) std.math.Order {
    if (level >= sorts.len) return .eq;

    const sort = sorts[level];
    if (sort.order == .NADA) return .eq;

    const a_value = selectPropertyFromPackedNoteContent(a, sort.selector) catch return .eq;
    const b_value = selectPropertyFromPackedNoteContent(b, sort.selector) catch return .eq;

    if (a_value.eql(b_value)) {
        return sortNotesRecursive(a, b, sorts, level + 1);
    }

    const is_greater = !a_value.lt(b_value) and !a_value.eql(b_value);
    return switch (sort.order) {
        .DESC => if (is_greater) .lt else .gt,
        .ASC => if (is_greater) .gt else .lt,
        .NADA => .eq,
    };
}

fn sortNotes(notes: []NoteData, sorts: []const SortCriteria) void {
    std.mem.sort(NoteData, notes, sorts, struct {
        fn lessThan(context: []const SortCriteria, a: NoteData, b: NoteData) bool {
            const order = sortNotesRecursive(a.note.items, b.note.items, context, 0);
            return order == .lt;
        }
    }.lessThan);
}

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
    timestamp: u64 = Txe.GENESIS_TIMESTAMP,
    side_effect_counter: u32 = 0,
    contract_address: proto.AztecAddress = proto.AztecAddress.zero,
    msg_sender: proto.AztecAddress,
    function_selector: u32 = 0,
    is_static_call: bool = false,
    nested_call_returndata: []F,
    contracts_artifacts_path: []const u8,
    contract_artifact_cache: std.AutoHashMap(F, ContractAbi),
    contract_instance_cache: std.AutoHashMap(proto.AztecAddress, proto.ContractInstance),
    execution_cache: std.AutoHashMap(F, []F),
    fc_handler: *ForeignCallDispatcher = undefined,
    // Capsule storage: key is "address:slot", value is array of F elements
    capsule_storage: std.StringHashMap([]F),
    //   private contractDataOracle: ContractDataOracle;
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(12345),
    private_logs: std.ArrayList(PrivateLog),
    note_cache: NoteCache,

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
            .execution_cache = std.AutoHashMap(F, []F).init(allocator),
            .capsule_storage = std.StringHashMap([]F).init(allocator),
            .private_logs = std.ArrayList(PrivateLog).init(allocator),
            .note_cache = NoteCache.init(allocator),
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
        self.execution_cache.deinit();
        self.contract_instance_cache.deinit();
        self.contract_artifact_cache.deinit();
        self.note_cache.deinit();
        self.private_logs.deinit();
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
        {
            var iter = self.capsule_storage.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.capsule_storage.clearRetainingCapacity();
        }
        {
            var iter = self.execution_cache.valueIterator();
            while (iter.next()) |value| {
                self.allocator.free(value.*);
            }
            self.execution_cache.clearRetainingCapacity();
        }

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

    pub fn getTimestamp(self: *Txe, _: std.mem.Allocator) !u64 {
        return self.timestamp;
    }

    pub fn getVersion(self: *Txe, _: std.mem.Allocator) !F {
        return self.version;
    }

    pub fn getChainId(self: *Txe, _: std.mem.Allocator) !F {
        return self.chain_id;
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
                .timestamp = timestamp orelse self.timestamp - Txe.AZTEC_SLOT_DURATION,
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
        try self.execution_cache.put(hash, try self.allocator.dupe(F, args));
    }

    pub fn loadFromExecutionCache(
        self: *Txe,
        allocator: std.mem.Allocator,
        args_hash: F,
    ) !?[]F {
        if (self.execution_cache.get(args_hash)) |cached_args| {
            // Return a copy to avoid lifetime issues
            const result = try allocator.alloc(F, cached_args.len);
            @memcpy(result, cached_args);

            std.debug.print("loadFromExecutionCache: Found cached args with hash {x}\n", .{args_hash});
            return result;
        }

        // Special case: hash 0 returns empty array
        if (args_hash.eql(F.zero)) {
            std.debug.print("loadFromExecutionCache: Returning empty array for hash 0\n", .{});
            return try allocator.alloc(F, 0);
        }

        std.debug.print("loadFromExecutionCache: No cached args found with hash {x}\n", .{args_hash});
        return null;
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
        // Save current environment.
        const current_contract_address = self.contract_address;
        const current_msg_sender = self.msg_sender;
        const current_function_selector = self.function_selector;

        // Set up new environment for the call.
        self.msg_sender = self.contract_address;
        self.contract_address = target_contract_address;
        self.function_selector = function_selector;

        // Retrieve the function to execute from the target contract's ABI.
        const contract_instance = self.contract_instance_cache.get(target_contract_address) orelse {
            return error.ContractInstanceNotFound;
        };
        const function = try contract_instance.abi.getFunctionBySelector(function_selector);

        std.debug.print("Executing external function: {s}@{x} (static: {})\n", .{
            function.name,
            target_contract_address,
            is_static_call,
        });

        const args = self.execution_cache.get(args_hash) orelse {
            std.debug.print("No args found for hash {x}\n", .{args_hash});
            return error.ArgsNotFound;
        };

        const private_context_inputs = try self.getPrivateContextInputsInternal(
            self.allocator,
            self.block_number - 1,
            self.timestamp - Txe.AZTEC_SLOT_DURATION,
            side_effect_counter,
            is_static_call,
        );

        // Build calldata from private context inputs and function arguments.
        var calldata = std.ArrayList(F).init(allocator);
        try structToFields(PrivateContextInputs, private_context_inputs, &calldata);
        for (args) |arg| {
            try calldata.append(arg);
        }

        const program = try cvm.deserialize(allocator, try function.getBytecode(allocator));

        // Execute private function in nested circuit vm.
        var circuit_vm = try cvm.CircuitVm.init(allocator, &program, calldata.items, self.fc_handler);
        std.debug.print("callPrivateFunction: Entering nested cvm\n", .{});
        circuit_vm.executeVm(0, false) catch |err| {
            if (err == error.Trapped) {
                // TODO: Get actual artifact path.
                circuit_vm.printBrilligTrapError(function.name, function_selector, "data/contracts/Counter.json");
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
        const private_circuit_public_inputs = try fieldsToStruct(PrivateCircuitPublicInputs, public_inputs_fields);

        const end_side_effect_counter = private_circuit_public_inputs.end_side_effect_counter;
        const returns_hash = private_circuit_public_inputs.returns_hash;

        // Apply side effects.
        self.side_effect_counter = @intCast(end_side_effect_counter.to_int() + 1);

        // Add private logs.
        for (private_circuit_public_inputs.private_logs.items()) |private_log| {
            var log = private_log.log;
            log.fields[0] = poseidon.hash(&[_]F{ target_contract_address.value, log.fields[0] });
            try self.private_logs.append(log);
        }

        // Restore previous environment.
        self.contract_address = current_contract_address;
        self.msg_sender = current_msg_sender;
        self.function_selector = current_function_selector;

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

    pub fn simulateUtilityFunction(
        self: *Txe,
        allocator: std.mem.Allocator,
        target_contract_address: proto.AztecAddress,
        function_selector: FunctionSelector,
        args_hash: F,
    ) !F {
        // Retrieve the function to execute from the target contract's ABI.
        const contract_instance = self.contract_instance_cache.get(target_contract_address) orelse {
            return error.ContractInstanceNotFound;
        };

        const function = try contract_instance.abi.getFunctionBySelector(function_selector);
        std.debug.print("simulateUtilityFunction called with target: {x}, selector: {x}, name: {s}, args_hash: {x}\n", .{
            target_contract_address,
            function_selector,
            function.name,
            args_hash,
        });

        const calldata = self.execution_cache.get(args_hash) orelse {
            std.debug.print("No args found for hash {x}\n", .{args_hash});
            return error.ArgsNotFound;
        };

        const program = try cvm.deserialize(allocator, try function.getBytecode(allocator));

        // Execute utility function in nested circuit vm.
        var circuit_vm = try cvm.CircuitVm.init(allocator, &program, calldata, self.fc_handler);
        std.debug.print("simulateUtilityFunction: Entering nested cvm\n", .{});
        circuit_vm.executeVm(0, false) catch |err| {
            if (err == error.Trapped) {
                // TODO: Get actual artifact path.
                circuit_vm.printBrilligTrapError(function.name, function_selector, "data/contracts/Counter.json");
            }
            return err;
        };
        std.debug.print("simulateUtilityFunction: Exited nested cvm\n", .{});

        return F.zero;
    }

    pub fn getNotes(
        self: *Txe,
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
    ) ![]const NoteData {
        _ = status; // Not used in this minimal implementation
        _ = max_notes;
        _ = packed_retrieved_note_length;

        // Get pending notes from cache
        const pending_notes = self.note_cache.getNotes(self.contract_address, storage_slot);

        // For now, we only return pending notes (no database notes)
        // Filter out nullified notes
        var filtered_notes = std.ArrayList(NoteData).init(allocator);
        defer filtered_notes.deinit();
        for (pending_notes) |note| {
            if (!self.note_cache.hasNullifier(self.contract_address, note.siloed_nullifier)) {
                try filtered_notes.append(note);
            }
        }

        // Build select criteria
        const actual_num_selects = @min(num_selects, select_by_indexes.len);
        var selects = try allocator.alloc(SelectCriteria, actual_num_selects);

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
        var selected_notes = try selectNotes(allocator, filtered_notes.items, selects);
        defer selected_notes.deinit();

        // Build sort criteria
        var sorts = try allocator.alloc(SortCriteria, sort_by_indexes.len);

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
        sortNotes(selected_notes.items, sorts);

        // Apply offset and limit
        const start_idx = @min(offset, selected_notes.items.len);
        const end_idx = if (limit > 0) @min(start_idx + limit, selected_notes.items.len) else selected_notes.items.len;

        const result = try allocator.alloc(NoteData, end_idx - start_idx);
        @memcpy(result, selected_notes.items[start_idx..end_idx]);

        std.debug.print("getNotes: Returning {} notes for contract {} at slot {x}\n", .{
            result.len,
            self.contract_address,
            storage_slot,
        });

        return result;
    }

    pub fn notifyCreatedNote(
        self: *Txe,
        _: std.mem.Allocator,
        storage_slot: F,
        note_type_id: u32,
        note_items: []const F,
        note_hash: F,
        counter: u32,
    ) !void {
        _ = note_type_id; // Not used in this implementation

        const note_data = NoteData{
            .note = Note.init(note_items),
            .contract_address = self.contract_address,
            .storage_slot = storage_slot,
            .note_nonce = F.from_int(counter), // Using counter as nonce for simplicity
            .note_hash = note_hash,
            .siloed_nullifier = F.zero, // Will be computed when note is nullified
        };

        try self.note_cache.addNote(note_data);

        std.debug.print("notifyCreatedNote: Added note with hash {x} at slot {x}, counter {}\n", .{
            note_hash,
            storage_slot,
            counter,
        });
    }
};
