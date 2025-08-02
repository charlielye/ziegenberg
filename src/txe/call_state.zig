const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const proto = @import("../protocol/package.zig");
const nargo = @import("../nargo/package.zig");
const bvm = @import("../bvm/package.zig");
const NoteCache = @import("note_cache.zig").NoteCache;

pub fn KeyCtx(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), key: K) u64 {
            return key.hash();
        }
        pub fn eql(_: @This(), a: K, b: K) bool {
            return a.eql(b);
        }
    };
}

/// Key for capsule storage combining contract address and slot
pub const CapsuleKey = struct {
    address: proto.AztecAddress,
    slot: F,

    pub fn hash(self: CapsuleKey) u64 {
        // Use address hash as seed for slot hash.
        const addr_hash = self.address.hash();
        const slot_int = self.slot.to_int();
        return std.hash.Wyhash.hash(addr_hash, std.mem.asBytes(&slot_int));
    }

    pub fn eql(self: CapsuleKey, other: CapsuleKey) bool {
        return self.address.eql(other.address) and self.slot.eql(other.slot);
    }
};

pub const PrivateLog = struct {
    fields: [18]F = [_]F{F.zero} ** 18,
    emitted_length: u32 = 0,
};

/// We create a new CallState for each function call via createChild().
pub const CallState = struct {
    // The following are immutable for this call frame.
    contract_address: proto.AztecAddress,
    msg_sender: proto.AztecAddress,
    function_selector: u32,
    is_static_call: bool,

    // Protocol side effects.
    side_effect_counter: u32,
    note_cache: *NoteCache,
    public_nullifiers: std.ArrayList(F),
    // storage_writes: std.StringHashMap([]F),
    private_logs: std.ArrayList(PrivateLog),

    // Capsule storage (temporary storage used by contracts).
    capsule_storage: std.HashMap(CapsuleKey, []F, KeyCtx(CapsuleKey), 80),

    // Execution data (args_hash->input args, return_hash->return witnesses).
    execution_cache: std.HashMap(F, []F, KeyCtx(F), 80),
    return_data: []F,

    // Reference to parent for state lookup
    parent: ?*CallState = null,

    // Contract ABI reference for debug info.
    contract_abi: ?*const nargo.ContractAbi = null,

    // Error context if execution failed.
    execution_error: ?bvm.brillig_vm.ErrorContext = null,

    pub fn init(allocator: std.mem.Allocator, note_cache: *NoteCache) CallState {
        return .{
            .contract_address = proto.AztecAddress.zero,
            .msg_sender = proto.AztecAddress.init(F.max),
            .function_selector = 0,
            .is_static_call = false,
            .side_effect_counter = 0,
            .note_cache = note_cache,
            .public_nullifiers = std.ArrayList(F).init(allocator),
            // .storage_writes = std.StringHashMap([]F).init(allocator),
            .private_logs = std.ArrayList(PrivateLog).init(allocator),
            .capsule_storage = std.HashMap(CapsuleKey, []F, KeyCtx(CapsuleKey), 80).init(allocator),
            .execution_cache = std.HashMap(F, []F, KeyCtx(F), 80).init(allocator),
            .return_data = &[_]F{},
        };
    }

    pub fn deinit(self: *CallState) void {
        // Note: note_cache is shared, so we don't deinit it here
        self.public_nullifiers.deinit();

        // Free storage writes
        // var iter = self.storage_writes.iterator();
        // while (iter.next()) |entry| {
        //     self.storage_writes.allocator.free(entry.key_ptr.*);
        //     self.storage_writes.allocator.free(entry.value_ptr.*);
        // }
        // self.storage_writes.deinit();

        // Free capsule storage values.
        var capsule_iter = self.capsule_storage.valueIterator();
        while (capsule_iter.next()) |value| {
            self.capsule_storage.allocator.free(value.*);
        }
        self.capsule_storage.deinit();

        self.private_logs.deinit();

        // Free execution cache values.
        var cache_iter = self.execution_cache.valueIterator();
        while (cache_iter.next()) |value| {
            self.execution_cache.allocator.free(value.*);
        }
        self.execution_cache.deinit();
    }

    /// Create a child state that inherits from this state
    pub fn createChild(
        self: *CallState,
        allocator: std.mem.Allocator,
        target: proto.AztecAddress,
        selector: u32,
        is_static: bool,
    ) !*CallState {
        const child = try allocator.create(CallState);
        child.* = CallState.init(allocator, self.note_cache);

        // Set up child context
        child.contract_address = target;
        child.msg_sender = self.contract_address;
        child.function_selector = selector;
        child.is_static_call = is_static;
        child.side_effect_counter = self.side_effect_counter;
        child.parent = self;

        return child;
    }

    /// Merge child state back into parent
    pub fn mergeChild(self: *CallState, child: *CallState) !void {
        // Always merge:
        // - Side effect counter (take max)
        self.side_effect_counter = @max(self.side_effect_counter, child.side_effect_counter);

        try self.note_cache.notes.appendSlice(child.note_cache.notes.items);

        // - Nullifiers
        try self.public_nullifiers.appendSlice(child.public_nullifiers.items);

        // - Private logs
        try self.private_logs.appendSlice(child.private_logs.items);

        // - Execution cache entries (child takes precedence)
        var iter = child.execution_cache.iterator();
        while (iter.next()) |entry| {
            const value_copy = try self.execution_cache.allocator.dupe(F, entry.value_ptr.*);
            try self.execution_cache.put(entry.key_ptr.*, value_copy);
        }

        // Only merge if not static call:
        if (!child.is_static_call) {
            // Storage writes
            // var storage_iter = child.storage_writes.iterator();
            // while (storage_iter.next()) |entry| {
            //     const key_copy = try self.storage_writes.allocator.dupe(u8, entry.key_ptr.*);
            //     const value_copy = try self.storage_writes.allocator.dupe(F, entry.value_ptr.*);
            //     try self.storage_writes.put(key_copy, value_copy);
            // }

            // Capsule storage
            var capsule_iter = child.capsule_storage.iterator();
            while (capsule_iter.next()) |entry| {
                const value_copy = try self.capsule_storage.allocator.dupe(F, entry.value_ptr.*);
                try self.capsule_storage.put(entry.key_ptr.*, value_copy);
            }
        }

        // Set return data on parent
        self.return_data = child.return_data;
    }

    /// Look up storage, checking parent chain if not found locally
    // pub fn getStorage(self: *const CallState, key: []const u8) ?[]F {
    //     if (self.storage_writes.get(key)) |value| {
    //         return value;
    //     }

    //     // Check parent chain
    //     if (self.parent) |parent| {
    //         return parent.getStorage(key);
    //     }

    //     return null;
    // }

    /// Look up execution cache, checking parent chain if not found locally
    pub fn getFromExecutionCache(self: *const CallState, hash: F) ?[]F {
        if (self.execution_cache.get(hash)) |value| {
            return value;
        }

        // Check parent chain
        if (self.parent) |parent| {
            return parent.getFromExecutionCache(hash);
        }

        return null;
    }

    /// Get notes for a contract address and storage slot, filtered by nullifiers
    // pub fn getNotes(self: *const CallState, allocator: std.mem.Allocator, storage_slot: F) ![]proto.NoteData {
    //     return self.note_cache.getNotes(allocator, self.contract_address, storage_slot);
    // }

    /// Check if a nullifier exists
    pub fn hasNullifier(self: *const CallState, contract_address: proto.AztecAddress, nullifier: F) bool {
        // Check in the nullifiers list
        for (self.public_nullifiers.items) |n| {
            if (n.eql(nullifier)) {
                return true;
            }
        }

        // Also check local note cache
        if (self.note_cache.hasNullifier(contract_address, nullifier)) {
            return true;
        }

        // Check parent chain
        if (self.parent) |parent| {
            return parent.hasNullifier(contract_address, nullifier);
        }

        return false;
    }

    /// Load capsule data for a given slot (uses contract address)
    pub fn loadCapsuleAtSlot(self: *const CallState, allocator: std.mem.Allocator, slot: F) !?[]F {
        const key = CapsuleKey{ .address = self.contract_address, .slot = slot };

        if (self.loadCapsule(key)) |capsule| {
            // Return a copy of the data
            const result = try allocator.alloc(F, capsule.len);
            @memcpy(result, capsule);
            return result;
        }
        return null;
    }

    /// Store capsule data at a given slot (uses contract address)
    pub fn storeCapsuleAtSlot(self: *CallState, _: std.mem.Allocator, slot: F, capsule: []const F) !void {
        const key = CapsuleKey{ .address = self.contract_address, .slot = slot };
        try self.storeCapsule(key, capsule);
    }

    /// Look up capsule storage by key, checking parent chain if not found locally
    fn loadCapsule(self: *const CallState, key: CapsuleKey) ?[]F {
        if (self.capsule_storage.get(key)) |value| {
            return value;
        }

        // Check parent chain
        if (self.parent) |parent| {
            return parent.loadCapsule(key);
        }

        return null;
    }

    /// Store capsule data with a key in the current context
    fn storeCapsule(self: *CallState, key: CapsuleKey, capsule: []const F) !void {
        // If there's existing data, free it
        if (self.capsule_storage.get(key)) |existing| {
            self.capsule_storage.allocator.free(existing);
        }

        // Store new data (key is a value type, no need to copy)
        const capsule_copy = try self.capsule_storage.allocator.alloc(F, capsule.len);
        @memcpy(capsule_copy, capsule);

        try self.capsule_storage.put(key, capsule_copy);
    }
};
