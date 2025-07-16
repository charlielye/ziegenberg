const F = @import("../bn254/fr.zig").Fr;
const AztecAddress = @import("aztec_address.zig").AztecAddress;

pub const Note = struct {
    items: []const F,

    pub fn init(items: []const F) Note {
        return .{ .items = items };
    }
};

pub const NoteData = struct {
    note: Note,
    contract_address: AztecAddress,
    storage_slot: F,
    note_nonce: F,
    note_hash: F,
    siloed_nullifier: F,

    // pub fn toForeignCallParam(self: NoteData, allocator: std.mem.Allocator) !ForeignCallParam {
    //     var fields = std.ArrayList(ForeignCallParam).init(allocator);

    //     // Add note items
    //     for (self.note.items) |item| {
    //         try fields.append(.{ .Single = item.to_int() });
    //     }

    //     // Add other fields
    //     try fields.append(.{ .Single = self.contract_address.value.to_int() });
    //     try fields.append(.{ .Single = self.storage_slot.to_int() });
    //     try fields.append(.{ .Single = self.note_nonce.to_int() });
    //     try fields.append(.{ .Single = self.note_hash.to_int() });
    //     try fields.append(.{ .Single = self.siloed_nullifier.to_int() });

    //     return .{ .Array = try fields.toOwnedSlice() };
    // }
};
