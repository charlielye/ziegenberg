const std = @import("std");
const F = @import("../../bn254/fr.zig").Fr;
const proto = @import("../../protocol/package.zig");

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
pub const NoteCache = struct {
    // Maps contract_address -> storage_slot -> notes
    notes: std.AutoHashMap(proto.AztecAddress, std.AutoHashMap(F, std.ArrayList(proto.NoteData))),
    // Maps contract_address -> nullifiers
    nullifiers: std.AutoHashMap(proto.AztecAddress, std.AutoHashMap(F, void)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NoteCache {
        return .{
            .notes = std.AutoHashMap(proto.AztecAddress, std.AutoHashMap(F, std.ArrayList(proto.NoteData))).init(allocator),
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

    pub fn addNote(self: *NoteCache, note_data: proto.NoteData) !void {
        const contract_entry = try self.notes.getOrPut(note_data.contract_address);
        if (!contract_entry.found_existing) {
            contract_entry.value_ptr.* = std.AutoHashMap(F, std.ArrayList(proto.NoteData)).init(self.allocator);
        }

        const storage_entry = try contract_entry.value_ptr.getOrPut(note_data.storage_slot);
        if (!storage_entry.found_existing) {
            storage_entry.value_ptr.* = std.ArrayList(proto.NoteData).init(self.allocator);
        }

        try storage_entry.value_ptr.append(note_data);
    }

    pub fn getNotes(self: *NoteCache, contract_address: proto.AztecAddress, storage_slot: F) []const proto.NoteData {
        const contract_map = self.notes.get(contract_address) orelse return &[_]proto.NoteData{};
        const note_list = contract_map.get(storage_slot) orelse return &[_]proto.NoteData{};
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

pub const SelectCriteria = struct {
    selector: PropertySelector,
    value: F,
    comparator: Comparator,
};

pub const SortCriteria = struct {
    selector: PropertySelector,
    order: SortOrder,
};

pub fn selectNotes(allocator: std.mem.Allocator, notes: []const proto.NoteData, selects: []const SelectCriteria) !std.ArrayList(proto.NoteData) {
    var result = std.ArrayList(proto.NoteData).init(allocator);

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

pub fn sortNotes(notes: []proto.NoteData, sorts: []const SortCriteria) void {
    std.mem.sort(proto.NoteData, notes, sorts, struct {
        fn lessThan(context: []const SortCriteria, a: proto.NoteData, b: proto.NoteData) bool {
            const order = sortNotesRecursive(a.note.items, b.note.items, context, 0);
            return order == .lt;
        }
    }.lessThan);
}
