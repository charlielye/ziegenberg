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
const ForeignCallParam = @import("./param.zig").ForeignCallParam;

pub fn handleForeignCall(
    allocator: std.mem.Allocator,
    mem: *Memory,
    fc: *const io.ForeignCall,
    params: []ForeignCallParam,
) !void {
    if (std.mem.eql(u8, "print", fc.function)) {
        try handlePrint(allocator, mem, params);
    } else if (std.mem.eql(u8, "noOp", fc.function)) {
        std.debug.print("noop\n", .{});
    } else {
        // We allow silently ignoring foreign calls that return no values.
        if (fc.destination_value_types.len > 0) {
            std.debug.print("Unimplemented foreign call: {s}\n", .{fc.function});
            return error.Unimplemented;
        } else {
            std.debug.print("Ignoring unimplemented foreign call (void return): {s}\n", .{fc.function});
        }
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

// Given any input type, reflect on its type and marshal the ForeignCallParam into the input value.
pub fn marshalInput(
    input: anytype,
    allocator: std.mem.Allocator,
    param: ForeignCallParam,
) !void {
    const input_type = @TypeOf(input.*);
    const type_info = @typeInfo(input_type);

    // Check if type has fromForeignCallParam method
    if (type_info == .@"struct" and @hasDecl(input_type, "fromForeignCallParam")) {
        input.* = try input_type.fromForeignCallParam(param);
        return;
    }

    switch (input_type) {
        F => {
            std.debug.assert(param == .Single);
            input.* = F.from_int(param.Single);
            return;
        },
        // ForeignCallParam => {
        //     input.* = param;
        //     return;
        // },
        else => {},
    }

    const info = @typeInfo(input_type);
    switch (info) {
        .@"struct" => |s| {
            std.debug.assert(param == .Array);
            inline for (s.fields, 0..) |field, i| {
                const field_ptr = &@field(input, field.name);
                try marshalInput(field_ptr, allocator, param.Array[i]);
            }
        },
        .int => input.* = @intCast(param.Single),
        .bool => input.* = param.Single == 1,
        .optional => |opt| {
            // Optionals are represented as [bool, value] in ForeignCallParam
            std.debug.assert(param == .Array);
            std.debug.assert(param.Array.len == 2);
            const is_some = param.Array[0].Single == 1;
            if (is_some) {
                // Create the optional value
                var value: opt.child = undefined;
                try marshalInput(&value, allocator, param.Array[1]);
                input.* = value;
            } else {
                input.* = null;
            }
        },
        // Slices
        .pointer => |p| {
            std.debug.assert(p.size == .slice);
            std.debug.assert(param == .Array);
            input.* = if (p.child == ForeignCallParam) param.Array else convertSlice(p.child, allocator, param.Array);
        },
        else => unreachable,
    }
}

fn hasNestedArrays(types: []const io.HeapValueType) bool {
    for (types) |t| {
        switch (t) {
            .Array, .Vector => return true,
            .Simple => {},
        }
    }
    return false;
}

fn writeSliceOfValuesToMemory(
    mem: *Memory,
    destination: usize,
    values: []const u256,
    values_idx: *usize,
    value_type: *const io.HeapValueType,
) void {
    switch (value_type.*) {
        .Simple => {
            mem.setSlotAtIndex(destination, values[values_idx.*]);
            values_idx.* += 1;
        },
        .Array => |arr| {
            var current_pointer = destination;
            for (0..arr.size) |i| {
                const elem_type = &arr.value_types[i % arr.value_types.len];
                switch (elem_type.*) {
                    .Simple => {
                        mem.setSlotAtIndex(current_pointer, values[values_idx.*]);
                        values_idx.* += 1;
                        current_pointer += 1;
                    },
                    .Array, .Vector => {
                        // Read pointer from memory and skip reference count
                        const nested_ptr: usize = @intCast(mem.getSlotAtIndex(current_pointer));
                        const nested_dest = nested_ptr + 1; // Skip reference count
                        writeSliceOfValuesToMemory(mem, nested_dest, values, values_idx, elem_type);
                        current_pointer += 1;
                    },
                }
            }
        },
        .Vector => {
            std.debug.panic("Vectors in nested types not yet supported", .{});
        },
    }
}

pub fn marshalForeignCallParam(
    output: []ForeignCallParam,
    mem: *Memory,
    destination: []const io.ValueOrArray,
    destination_value_types: []const io.HeapValueType,
) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    for (output, destination, destination_value_types) |fcp, voa, value_type| {
        // std.debug.print("Marshal output fcp: {any}\n", .{fcp});
        // std.debug.print("Marshal destination: {any}\n", .{voa});
        switch (fcp) {
            .Single => mem.setSlot(voa.MemoryAddress, fcp.Single),
            .Array => {
                switch (voa) {
                    .HeapArray => {
                        const arr = voa.HeapArray;
                        const dst_idx: usize = @intCast(mem.getSlot(arr.pointer));

                        // Check if we need to reconstruct nested structure
                        if (value_type == .Array) {
                            const arr_type = value_type.Array;
                            if (hasNestedArrays(arr_type.value_types)) {
                                // Need to reconstruct from flattened array
                                const flattened = fcp.flatten(arena.allocator()) catch unreachable;
                                var values_idx: usize = 0;
                                writeSliceOfValuesToMemory(mem, dst_idx, flattened, &values_idx, &value_type);
                            } else {
                                // Simple array - but may still have nested structure in the ForeignCallParam
                                // Need to flatten it first
                                const flattened = fcp.flatten(arena.allocator()) catch unreachable;
                                for (0..flattened.len) |i| {
                                    mem.setSlotAtIndex(dst_idx + i, flattened[i]);
                                }
                            }
                        } else {
                            // No type info, need to flatten in case of nested structure
                            const flattened = fcp.flatten(arena.allocator()) catch unreachable;
                            for (0..flattened.len) |i| {
                                mem.setSlotAtIndex(dst_idx + i, flattened[i]);
                            }
                        }
                    },
                    .HeapVector => {
                        const vec = voa.HeapVector;
                        const dst_idx: usize = @intCast(mem.getSlot(vec.pointer));
                        mem.setSlot(vec.size, fcp.Array.len);

                        // Similar logic for vectors
                        if (value_type == .Vector) {
                            const vec_type = value_type.Vector;
                            if (hasNestedArrays(vec_type.value_types)) {
                                const flattened = fcp.flatten(arena.allocator()) catch unreachable;
                                var values_idx: usize = 0;
                                writeSliceOfValuesToMemory(mem, dst_idx, flattened, &values_idx, &value_type);
                            } else {
                                const flattened = fcp.flatten(arena.allocator()) catch unreachable;
                                for (0..flattened.len) |i|
                                    mem.setSlotAtIndex(dst_idx + i, flattened[i]);
                            }
                        } else {
                            const flattened = fcp.flatten(arena.allocator()) catch unreachable;
                            for (0..flattened.len) |i|
                                mem.setSlotAtIndex(dst_idx + i, flattened[i]);
                        }
                    },
                    else => unreachable,
                }
            },
        }
    }
}

fn structToForeignCallParams(allocator: std.mem.Allocator, value: anytype) ![]ForeignCallParam {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    var result = std.ArrayList(ForeignCallParam).init(allocator);

    // Check if this is a Field type first
    if (T == F) {
        try result.append(ForeignCallParam{ .Single = value.to_int() });
        return result.toOwnedSlice();
    }

    switch (info) {
        .@"struct" => |s| {
            // Check if this struct has a toForeignCallParams method (returns array of params)
            if (@hasDecl(T, "toForeignCallParams")) {
                const params = value.toForeignCallParams();
                try result.appendSlice(&params);
            } else if (@hasDecl(T, "toForeignCallParam")) {
                // Check if this struct has a toForeignCallParam method (returns single param)
                try result.append(value.toForeignCallParam());
            } else if (@hasDecl(T, "to_int")) {
                // Check if this struct has a to_int method (like Field types)
                try result.append(ForeignCallParam{ .Single = value.to_int() });
            } else {
                inline for (s.fields) |field| {
                    const field_value = @field(value, field.name);
                    const field_params = try structToForeignCallParams(allocator, field_value);
                    try result.appendSlice(field_params);
                }
            }
        },
        .bool => {
            try result.append(ForeignCallParam{ .Single = if (value) 1 else 0 });
        },
        .array => {
            for (value) |elem| {
                const elem_params = try structToForeignCallParams(allocator, elem);
                try result.appendSlice(elem_params);
            }
        },
        .int => {
            try result.append(ForeignCallParam{ .Single = value });
        },
        else => {
            @compileError("Unsupported type in structToForeignCallParams: " ++ @typeName(T));
        },
    }

    return result.toOwnedSlice();
}

pub fn marshalOutput(
    output: anytype,
    mem: *Memory,
    destinations: []const io.ValueOrArray,
    destination_value_types: []const io.HeapValueType,
) void {
    const output_type = @TypeOf(output.*);

    if (output_type == F) {
        // std.debug.assert(destinations.len == 1);
        mem.setSlot(destinations[0].MemoryAddress, output.*.to_int());
        // } else if (output_type == []ForeignCallParam) {
        //     marshalForeignCallParam(output.*, mem, destination, destination_value_type);
    }

    const info = @typeInfo(output_type);
    switch (info) {
        .@"struct" => {
            // Structs need to be flattened into ForeignCallParams for marshaling
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const flattened = structToForeignCallParams(arena.allocator(), output.*) catch unreachable;
            marshalForeignCallParam(flattened, mem, destinations, destination_value_types);
        },
        .array => |arr_info| {
            std.debug.assert(destinations[0] == .HeapArray);
            const arr = destinations[0].HeapArray;
            const dst_idx: usize = @intCast(mem.getSlot(arr.pointer));
            // TODO: This will break if the array element is anything other than a field or int.
            for (0..arr.size) |i|
                mem.setSlotAtIndex(dst_idx + i, if (arr_info.child == F) output[i].to_int() else output[i]);
        },
        .int => {
            mem.setSlot(destinations[0].MemoryAddress, output.*);
        },
        .bool => {
            mem.setSlot(destinations[0].MemoryAddress, if (output.*) 1 else 0);
        },
        .optional => |opt| {
            // Optional values are marshalled as [is_some, value]
            if (output.*) |value| {
                // Has value
                if (destinations[0] == .HeapArray) {
                    const arr = destinations[0].HeapArray;
                    const dst_idx: usize = @intCast(mem.getSlot(arr.pointer));

                    // Set is_some = 1
                    mem.setSlotAtIndex(dst_idx, 1);

                    // Marshal the value based on its type
                    if (opt.child == []F) {
                        // Special handling for []F
                        const slice = value;
                        for (0..slice.len) |i| {
                            mem.setSlotAtIndex(dst_idx + 1 + i, slice[i].to_int());
                        }
                    } else {
                        // For other types, use existing marshaling
                        var temp_value = value;
                        var temp_destinations = [_]io.ValueOrArray{io.ValueOrArray{ .MemoryAddress = destinations[0].HeapArray.pointer + 1 }};
                        marshalOutput(&temp_value, mem, &temp_destinations, destination_value_types);
                    }
                }
            } else {
                // No value - set is_some = 0
                if (destinations[0] == .HeapArray) {
                    const arr = destinations[0].HeapArray;
                    const dst_idx: usize = @intCast(mem.getSlot(arr.pointer));
                    mem.setSlotAtIndex(dst_idx, 0);
                }
            }
        },
        .void => {},
        else => {
            std.debug.print("Unexpected type: {any}\n", .{output_type});
            unreachable;
        },
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
