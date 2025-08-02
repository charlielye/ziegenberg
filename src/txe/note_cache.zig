const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const proto = @import("../protocol/package.zig");
const poseidon = @import("../poseidon2/poseidon2.zig");

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

pub const NoteData = struct {
    // The contract address scope of this note.
    contract_address: proto.AztecAddress,
    // The storage slot of this note.
    // Storage slots may have more than one note that sum to a value.
    storage_slot: F,
    // The side effect counter when the note was created.
    side_effect_counter: u32,
    // The fields that make up the note_hash.
    // Determined by the app smart contract.
    note_fields: []F,
    // The note hash, as defined in noir code.
    // aztec.nr provides opinionated implementations (e.g. poseidon hash the note_fields).
    note_hash: F,
    // Will be either the tx hash, or the first nullifier.
    // Non-revertible notes can compute this on enterRevertiblePhase().
    // Revertible notes can compute this on finalize().
    // The nonce is used to ensure that two notes with the same values are unique.
    note_nonce: F = F.zero,
    // Hash of [note hash, contract_address].
    // Notes must be scoped to their contract address.
    // Computed when the note is added.
    siloed_note_hash: F = F.zero,
    // Hash of [nonce, siloed_note_hash].
    // Hashing the siloed hash with the nonce ensures uniqueness even with same values.
    // TODO: I think it's more intuitive to nonce-then-silo, than silo-then-nonce?
    unique_note_hash: F = F.zero,
    // The note nullifier, as defined in noir code.
    // aztec.nr provides opinionated nullifer computation implementations.
    // Not known until the contract nullifies the note_hash.
    // May not actually be emitted in the nullifier list, if it's nullifying something we can squash away.
    nullifier: F = F.zero,
    // Hash of [nullifier, contract address].
    // Nullifiers must be scoped to their contract address.
    siloed_nullifier: F = F.zero,
};

/// Notes and nullifiers that exist within a tx scope.
/// Presents a set of notes that have not been nullified within this tx scope.
/// TODO: Move private logs here? Rename this StorageCache? Or SideEffectCache?
pub const NoteCache = struct {
    allocator: std.mem.Allocator,
    // Notes that have not been nullified during this scope.
    notes: std.ArrayList(NoteData),
    // All nullifiers emitted during this scope.
    nullifiers: std.ArrayList(F),
    // The side effect counter increments for every note added/nullified.
    // Each note tracks the counter it was created at.
    side_effect_counter: u32 = 0,
    // Once we switch to the revertible phase, we track the side effect counter.
    min_revertible_side_effect_counter: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) NoteCache {
        return .{
            .allocator = allocator,
            .notes = std.ArrayList(NoteData).init(allocator),
            .nullifiers = std.ArrayList(F).init(allocator),
        };
    }

    pub fn deinit(self: *NoteCache) void {
        self.notes.deinit();
        self.nullifiers.deinit();
    }

    /// Takes a copy of the note data and stores it.
    pub fn addNote(self: *NoteCache, note_data: NoteData) void {
        var note_to_add = note_data;
        // Duplicate fields into our own allocator.
        note_to_add.note_fields = self.allocator.dupe(F, note_to_add.note_fields) catch unreachable;
        // Compute siloed note hash.
        note_to_add.siloed_note_hash = poseidon.hash_array_with_generator(
            [_]F{ note_data.contract_address.value, note_data.note_hash },
            proto.constants.GeneratorIndex.siloed_note_hash,
        );
        self.notes.append(note_to_add) catch unreachable;
        self.side_effect_counter += 1;
    }

    pub fn nullifyNote(self: *NoteCache, contract_address: proto.AztecAddress, nullifier: F, note_hash: F) void {
        const siloed_nullifier = poseidon.hash_array_with_generator(
            [_]F{ contract_address.value, nullifier },
            proto.constants.GeneratorIndex.outer_nullifier,
        );

        // No note hash given, just emit the siloed nullifier.
        if (note_hash.is_zero()) {
            self.nullifiers.append(siloed_nullifier) catch unreachable;
            return;
        }

        for (self.notes.items) |*note| {
            // Skip notes not in this contract.
            if (!note.contract_address.eql(contract_address)) continue;

            if (note.note_hash.eql(note_hash)) {
                // Assign the nullifier to it to mark it as nullified.
                note.nullifier = nullifier;

                // If we're in the revertible phase, but nullifying a non-revertible note, we emit the nullifier.
                if (self.min_revertible_side_effect_counter) |min_revertible_side_effect_counter| {
                    if (note.side_effect_counter < min_revertible_side_effect_counter) {
                        self.nullifiers.append(note.siloed_nullifier) catch unreachable;
                    }
                }
                break;
            }
        }

        self.side_effect_counter += 1;
    }

    pub fn enterRevertiblePhase(self: *NoteCache) void {
        self.min_revertible_side_effect_counter = self.side_effect_counter;
    }

    /// Compute all the note nonces and resulting unique hashes.
    pub fn finalize(self: *NoteCache, tx_hash: F) void {
        const nonce_generator = if (self.nullifiers.items.len > 0) self.nullifiers[0] else tx_hash;
        for (self.notes.items, 0..) |*note, i| {
            note.note_nonce = poseidon.hash_array_with_generator(
                F{ nonce_generator, F.from_int(i) },
                proto.constants.GeneratorIndex.note_hash_nonce,
            );
            note.unique_note_hash = poseidon.hash_array_with_generator(
                F{ note.note_nonce, note.siloed_note_hash },
                proto.constants.GeneratorIndex.unique_note_hash,
            );
        }
    }

    pub fn getNotes(
        self: *const NoteCache,
        allocator: std.mem.Allocator,
        contract_address: proto.AztecAddress,
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
    ) ![]NoteData {
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
        var selected_notes = try selectNotes(allocator, contract_address, storage_slot, self.notes.items, selects);
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

        return selected_notes.toOwnedSlice();
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

pub const SelectCriteria = struct {
    selector: PropertySelector,
    value: F,
    comparator: Comparator,
};

pub const SortCriteria = struct {
    selector: PropertySelector,
    order: SortOrder,
};

fn selectNotes(
    allocator: std.mem.Allocator,
    contract_address: proto.AztecAddress,
    storage_slot: F,
    notes: []const NoteData,
    selects: []const SelectCriteria,
) !std.ArrayList(NoteData) {
    var result = std.ArrayList(NoteData).init(allocator);

    for (notes) |note_data| {
        // Skip notes not for the given contract and storage slot.
        if (!(note_data.contract_address.eql(contract_address) and note_data.storage_slot.eql(storage_slot))) continue;

        var matches = true;
        for (selects) |select| {
            const note_value = selectPropertyFromPackedNoteContent(note_data.note_fields, select.selector) catch {
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
            const order = sortNotesRecursive(a.note_fields, b.note_fields, context, 0);
            return order == .lt;
        }
    }.lessThan);
}
