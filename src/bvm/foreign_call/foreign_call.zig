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
    Array: []ForeignCallParam,
};

pub fn handleForeignCall(allocator: std.mem.Allocator, mem: *Memory, fc: *const io.ForeignCall) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const params = try extractParams(arena.allocator(), mem, fc);

    if (std.mem.eql(u8, "print", fc.function)) {
        try handlePrint(arena.allocator(), mem, params);
    } else if (std.mem.eql(u8, "noOp", fc.function)) {
        std.debug.print("noop\n", .{});
    } else {
        std.debug.print("Unimplemented foreign call: {s}\n", .{fc.function});
        return error.Unimplemented;
    }
}

// TODO: Get rid of this high bit encoding in favour of tracking tags, and unify with avm.
fn norm(f: u256) u256 {
    var r align(32) = f;
    fieldOps.bn254_fr_normalize(@ptrCast(&r));
    return r;
}

fn convertSlice(comptime T: type, allocator: std.mem.Allocator, in: []ForeignCallParam) []T {
    const out = allocator.alloc(T, in.len) catch unreachable;
    for (in, out) |c, *o| o.* = if (T == F) F.from_int(c.Single) else @intCast(c.Single);
    return out;
}

pub fn marshalInput(
    input: anytype,
    allocator: std.mem.Allocator,
    param: ForeignCallParam,
) !void {
    const info = @typeInfo(@TypeOf(input.*));
    switch (info) {
        .@"struct" => |s| {
            if (@TypeOf(input.*) == F) {
                std.debug.assert(param == .Single);
                input.* = F.from_int(param.Single);
            } else {
                inline for (s.fields) |field| {
                    std.debug.assert(param == .Array);
                    marshalInput(field.type, allocator, param.Array);
                }
            }
        },
        .int => input.* = @intCast(param.Single),
        .bool => input.* = param.Single == 1,
        .pointer => |p| {
            std.debug.assert(p.size == .slice);
            std.debug.assert(param == .Array);
            input.* = convertSlice(p.child, allocator, param.Array);
        },
        else => unreachable,
    }
}

pub fn marshalOutput(
    output: anytype,
    mem: *Memory,
    destinations: []io.ValueOrArray,
) usize {
    const info = @typeInfo(@TypeOf(output.*));
    switch (info) {
        .@"struct" => |s| {
            var i: usize = 0;
            inline for (s.fields) |field| {
                if (field.type == F) {
                    mem.setSlot(destinations[i].MemoryAddress, @field(output, field.name).to_int());
                    i += 1;
                } else {
                    i += marshalOutput(&@field(output, field.name), mem, destinations[i..]);
                }
            }
            return i;
        },
        .array => |arr_info| {
            std.debug.assert(destinations[0] == .HeapArray);
            const arr = destinations[0].HeapArray;
            const dst_idx: usize = @intCast(mem.getSlot(arr.pointer));
            // TODO: This will break if the array element is anything other than a field or int.
            for (0..arr.size) |i| mem.setSlotAtIndex(dst_idx + i, if (arr_info.child == F) output[i].to_int() else output[i]);
            return 1;
        },
        .int => {
            mem.setSlot(destinations[0].MemoryAddress, output.*);
            return 1;
        },
        .bool => {
            mem.setSlot(destinations[0].MemoryAddress, if (output.*) 1 else 0);
            return 1;
        },
        .void => return 0,
        else => unreachable,
    }
}

/// If the structure is only known at runtime (i.e. described in the ForeignCall), use this.
/// The return value will have the shape as described by the input value types.
pub fn extractParams(allocator: std.mem.Allocator, mem: *Memory, fc: *const io.ForeignCall) ![]ForeignCallParam {
    const params = try allocator.alloc(ForeignCallParam, fc.inputs.len);
    for (fc.inputs, fc.input_value_types, params) |*input, *t, *p| {
        p.* = try getMemoryValues(allocator, mem, input, t);
    }
    return params;
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
            return try readSliceOfValuesFromMemory(allocator, mem, start, arr.size, arr.value_types);
        },
        .Vector => |vec| {
            const start: usize = @intCast(mem.getSlot(input.HeapVector.pointer));
            const size: usize = @intCast(mem.getSlot(input.HeapVector.size));
            return try readSliceOfValuesFromMemory(allocator, mem, start, size, vec.value_types);
        },
    }
}

fn readSliceOfValuesFromMemory(
    allocator: std.mem.Allocator,
    mem: *Memory,
    start: usize,
    size: usize,
    types: []io.HeapValueType,
    // results: *std.ArrayList(ForeignCallParam),
) !ForeignCallParam {
    var result = try std.ArrayList(ForeignCallParam).initCapacity(allocator, size);
    for (0..size) |i| {
        const value_type = types[i % types.len];
        switch (value_type) {
            // .Simple => try results.append(norm(mem.getSlotAtIndex(start + i))),
            .Simple => try result.append(ForeignCallParam{ .Single = norm(mem.getSlotAtIndex(start + i)) }),
            .Array => |arr| {
                const arr_addr: usize = @intCast(mem.getSlotAtIndex(start + i));
                const r = try readSliceOfValuesFromMemory(allocator, mem, arr_addr + 1, arr.size, arr.value_types);
                try result.append(r);
            },
            .Vector => |vec| {
                const vec_addr: usize = @intCast(mem.getSlotAtIndex(start + i));
                const vec_size_addr: usize = @intCast(mem.getSlotAtIndex(vec_addr + i + 1));
                const items_start: usize = @intCast(mem.getSlotAtIndex(vec_addr + 2));
                const vec_size: usize = @intCast(mem.getSlotAtIndex(vec_size_addr));
                const r = try readSliceOfValuesFromMemory(allocator, mem, items_start, vec_size, vec.value_types);
                try result.append(r);
            },
        }
    }
    return ForeignCallParam{ .Array = try result.toOwnedSlice() };
}
