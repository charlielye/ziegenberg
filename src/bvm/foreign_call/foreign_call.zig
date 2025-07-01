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

// Represents a single parameter in a foreign call.
// Can be a single value, or an array of values.
// When an array, it can represent plain array, or structured data types.
pub const ForeignCallParam = union(enum) {
    Single: u256,
    Array: []ForeignCallParam,

    pub fn eql(a: ForeignCallParam, b: ForeignCallParam) bool {
        if (a == .Single and b == .Single) {
            return a.Single == b.Single;
        } else if (a == .Array and b == .Array) {
            if (a.Array.len != b.Array.len) return false;
            for (a.Array, b.Array) |ae, be| {
                if (!ForeignCallParam.eql(ae, be)) return false;
            }
            return true;
        } else {
            return false;
        }
    }

    pub fn sliceEql(a: []ForeignCallParam, b: []ForeignCallParam) bool {
        if (a.len != b.len) return false;
        for (a, b) |ae, be| {
            if (!ForeignCallParam.eql(ae, be)) return false;
        }
        return true;
    }

    pub fn deepCopy(self: ForeignCallParam, allocator: std.mem.Allocator) !ForeignCallParam {
        switch (self) {
            .Single => return ForeignCallParam{ .Single = self.Single },
            .Array => {
                const len = self.Array.len;
                var new_array = try allocator.alloc(ForeignCallParam, len);
                for (self.Array, 0..) |elem, i| {
                    new_array[i] = try elem.deepCopy(allocator);
                }
                return ForeignCallParam{ .Array = new_array };
            },
        }
    }

    pub fn sliceDeepCopy(slice: []ForeignCallParam, allocator: std.mem.Allocator) ![]ForeignCallParam {
        const len = slice.len;
        var new_slice = try allocator.alloc(ForeignCallParam, len);
        for (slice, 0..) |elem, i| {
            new_slice[i] = try elem.deepCopy(allocator);
        }
        return new_slice;
    }

    pub fn flatten(self: ForeignCallParam, allocator: std.mem.Allocator) ![]u256 {
        const total_size: usize = self.countFlattenedElements();
        const result = try allocator.alloc(u256, total_size);
        var idx: usize = 0;
        self.flattenParam(result, &idx);
        return result;
    }

    fn countFlattenedElements(self: ForeignCallParam) usize {
        switch (self) {
            .Single => return 1,
            .Array => |arr| {
                var count: usize = 0;
                for (arr) |elem| {
                    count += elem.countFlattenedElements();
                }
                return count;
            },
        }
    }

    fn flattenParam(self: ForeignCallParam, out: []u256, idx: *usize) void {
        switch (self) {
            .Single => |val| {
                out[idx.*] = val;
                idx.* += 1;
            },
            .Array => |arr| {
                for (arr) |elem| {
                    flattenParam(elem, out, idx);
                }
            },
        }
    }
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
        if (fc.destination_value_types.len > 0) {
            std.debug.print("Unimplemented foreign call: {s}\n", .{fc.function});
            return error.Unimplemented;
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
            inline for (s.fields) |field| {
                std.debug.assert(param == .Array);
                marshalInput(field.type, allocator, param.Array);
            }
        },
        .int => input.* = @intCast(param.Single),
        .bool => input.* = param.Single == 1,
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
    destination: []io.ValueOrArray,
    destination_value_types: []io.HeapValueType,
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
                                // Simple array - direct write
                                for (0..fcp.Array.len) |i| {
                                    // std.debug.print("writing {} to {}\n", .{ fcp.Array[i].Single, dst_idx + i });
                                    mem.setSlotAtIndex(dst_idx + i, fcp.Array[i].Single);
                                }
                            }
                        } else {
                            // No type info, assume simple array
                            for (0..fcp.Array.len) |i| {
                                // std.debug.print("writing {} to {}\n", .{ fcp.Array[i].Single, dst_idx + i });
                                mem.setSlotAtIndex(dst_idx + i, fcp.Array[i].Single);
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
                                for (0..fcp.Array.len) |i|
                                    mem.setSlotAtIndex(dst_idx + i, fcp.Array[i].Single);
                            }
                        } else {
                            for (0..fcp.Array.len) |i|
                                mem.setSlotAtIndex(dst_idx + i, fcp.Array[i].Single);
                        }
                    },
                    else => unreachable,
                }
            },
        }
    }
}

pub fn marshalOutput(
    output: anytype,
    mem: *Memory,
    destinations: []io.ValueOrArray,
    destination_value_types: []io.HeapValueType,
) usize {
    const output_type = @TypeOf(output.*);

    if (output_type == F) {
        std.debug.assert(destinations.len == 1);
        mem.setSlot(destinations[0].MemoryAddress, output.*.to_int());
        return 1;
    } else if (output_type == []ForeignCallParam) {
        marshalForeignCallParam(output.*, mem, destinations, destination_value_types);
        return 1;
    }

    const info = @typeInfo(output_type);
    switch (info) {
        .@"struct" => |s| {
            var i: usize = 0;
            inline for (s.fields) |field| {
                i += marshalOutput(&@field(output, field.name), mem, destinations[i..], destination_value_types[i..]);
            }
            return i;
        },
        .array => |arr_info| {
            std.debug.assert(destinations[0] == .HeapArray);
            const arr = destinations[0].HeapArray;
            const dst_idx: usize = @intCast(mem.getSlot(arr.pointer));
            // TODO: This will break if the array element is anything other than a field or int.
            for (0..arr.size) |i|
                mem.setSlotAtIndex(dst_idx + i, if (arr_info.child == F) output[i].to_int() else output[i]);
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
