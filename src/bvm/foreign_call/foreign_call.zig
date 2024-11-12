/// Noir's ForeignCall opcode is highly generic.
/// It allows for the arbitrary calling of an external function with arbitrary data.
/// This is reflected in complexity of the opcode, which has complex type information carried through.
/// We are only interested in supporting Aztec.
/// We explicitly only handle Aztec calls, and leverage comptime to simplify foreign call processing.
const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const io = @import("../io.zig");
const F = @import("../../bn254/fr.zig").Fr;
const fieldOps = @import("../../blackbox/field.zig");
const handlePrint = @import("./print.zig").handlePrint;

pub const ForeignCallParam = union(enum) {
    Single: u256,
    Array: []u256,
};

pub fn handleForeignCall(allocator: std.mem.Allocator, mem: *Memory, fc: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // std.debug.print("{}\n", .{fc});
    const params = try arena.allocator().alloc(ForeignCallParam, fc.inputs.len);
    for (fc.inputs, fc.input_value_types, params) |*input, *t, *p| {
        p.* = try getMemoryValues(arena.allocator(), mem, input, t);
    }

    // std.debug.print("\n\n{any}\n\n", .{params});
    if (std.mem.eql(u8, "print", fc.function)) {
        try handlePrint(arena.allocator(), mem, params);
    } else {
        std.debug.print("Unimplemented: {s}\n", .{fc.function});
        return error.Unimplemented;
    }
}

// TODO: Get rid of this high bit encoding in favour of tracking tags, and unify with avm.
fn norm(f: u256) u256 {
    var r align(32) = f;
    fieldOps.bn254_fr_normalize(@ptrCast(&r));
    return r;
}

fn getMemoryValues(
    allocator: std.mem.Allocator,
    mem: *Memory,
    input: *io.ValueOrArray,
    t: *io.HeapValueType,
) !ForeignCallParam {
    switch (t.*) {
        .Simple => return ForeignCallParam{ .Single = norm(mem.getSlot(input.MemoryAddress)) },
        .Array => |arr| {
            const start: usize = @intCast(mem.getSlot(input.HeapArray.pointer));
            var results = std.ArrayList(u256).init(allocator);
            try readSliceOfValuesFromMemory(mem, start, arr.size, arr.value_types, &results);
            return ForeignCallParam{ .Array = try results.toOwnedSlice() };
        },
        .Vector => |vec| {
            const start: usize = @intCast(mem.getSlot(input.HeapVector.pointer));
            const size: usize = @intCast(mem.getSlot(input.HeapVector.size));
            var results = std.ArrayList(u256).init(allocator);
            try readSliceOfValuesFromMemory(mem, start, size, vec.value_types, &results);
            return ForeignCallParam{ .Array = try results.toOwnedSlice() };
        },
    }
}

fn readSliceOfValuesFromMemory(
    mem: *Memory,
    start: usize,
    size: usize,
    types: []io.HeapValueType,
    results: *std.ArrayList(u256),
) !void {
    for (0..size) |i| {
        const value_type = types[i % types.len];
        switch (value_type) {
            .Simple => try results.append(norm(mem.getSlotAtIndex(start + i))),
            .Array => |arr| {
                const arr_addr: usize = @intCast(mem.getSlotAtIndex(start + i));
                try readSliceOfValuesFromMemory(mem, arr_addr + 1, arr.size, arr.value_types, results);
            },
            .Vector => |vec| {
                const vec_addr: usize = @intCast(mem.getSlotAtIndex(start + i));
                const vec_size_addr: usize = @intCast(mem.getSlotAtIndex(vec_addr + i + 1));
                const items_start: usize = @intCast(mem.getSlotAtIndex(vec_addr + 2));
                const vec_size: usize = @intCast(mem.getSlotAtIndex(vec_size_addr));
                try readSliceOfValuesFromMemory(mem, items_start, vec_size, vec.value_types, results);
            },
        }
    }
}
