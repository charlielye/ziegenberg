const std = @import("std");
const Bn254Fr = @import("../bn254/fr.zig").Fr;

pub const DeserializeError = error{
    LargeAlloc,
    ParseIntError,
    InvalidEnumTag,
};

pub const Meta = struct {
    field: []const u8,
    src_type: type,
};

pub fn deserializeAlloc(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !T {
    return deserializeAllocImpl(stream, allocator, T, false, 0);
}

pub fn deserializeAllocDebug(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !T {
    return deserializeAllocImpl(stream, allocator, T, true, 0);
}

pub fn deserialize(stream: anytype, comptime T: type) !T {
    return deserializeImpl(stream, T, false, 0);
}

pub fn deserializeDebug(stream: anytype, comptime T: type) !T {
    return deserializeImpl(stream, T, true, 0);
}

pub fn deserializeBuffer(comptime T: type, source: *[]const u8) T {
    return deserializeBufferImpl(T, source, false);
}

pub fn serialize(stream: anytype, value: anytype) @TypeOf(stream).Error!void {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => try serializeBool(stream, value),
        .float => try serializeFloat(stream, T, value),
        .int => try serializeInt(stream, T, value),
        .optional => |info| try serializeOptional(stream, info.child, value),
        .pointer => |info| try serializePointer(stream, info, T, value),
        .array => |info| try serializeArray(stream, info, T, value),
        .@"struct" => |info| try serializeStruct(stream, info, T, value),
        .@"enum" => try serializeEnum(stream, T, value),
        .@"union" => |info| try serializeUnion(stream, info, T, value),
        else => unsupportedType(T),
    };
}

pub fn deserializeSliceIterator(comptime T: type, source: []const u8) DeserializeSliceIterator(T) {
    return DeserializeSliceIterator(T){
        .source = source,
    };
}

pub fn DeserializeSliceIterator(comptime T: type) type {
    return struct {
        source: []const u8,

        pub fn next(self: *@This()) ?T {
            if (self.source.len > 0) {
                return deserializeBuffer(T, &self.source);
            } else {
                return null;
            }
        }
    };
}

fn printIndent(level: usize) void {
    var i: usize = 0;
    while (i < level * 2) : (i += 1) {
        std.debug.print(" ", .{});
    }
}

fn deserializeBufferImpl(comptime T: type, source: *[]const u8, debug: bool) T {
    if (debug) std.debug.print("[deserializeBuffer] Type: {s}\n", .{@typeName(T)});
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => deserializeBufferBool(source, debug),
        .float => deserializeBufferFloat(T, source, debug),
        .int => deserializeBufferInt(T, source, debug),
        .optional => |info| deserializeBufferOptional(info.child, source, debug),
        .pointer => |info| deserializeBufferPointer(info, source, debug),
        .array => |info| deserializeBufferArray(info, source, debug),
        .@"struct" => |info| deserializeBufferStruct(T, info, source, debug),
        .@"enum" => deserializeBufferEnum(T, source, debug),
        .@"union" => |info| deserializeBufferUnion(T, info, source, debug),
        else => unsupportedType(T),
    };
}

fn deserializeAllocImpl(stream: anytype, allocator: std.mem.Allocator, comptime T: type, debug: bool, level: usize) !T {
    if (debug) {
        printIndent(level);
        std.debug.print("[deserializeAlloc] Type: {s}\n", .{@typeName(T)});
    }
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => try deserializeBool(stream, debug, level + 1),
        .float => try deserializeFloat(stream, T, debug, level + 1),
        .int => try deserializeInt(stream, T, debug, level + 1),
        .optional => |info| try deserializeOptionalAlloc(stream, allocator, info.child, debug, level + 1),
        .pointer => |info| try deserializePointerAlloc(stream, info, allocator, debug, level + 1),
        .array => |info| try deserializeArrayAlloc(stream, info, allocator, debug, level + 1),
        .@"struct" => |info| try deserializeStructAlloc(stream, info, allocator, T, debug, level + 1),
        .@"enum" => try deserializeEnum(stream, T, debug, level + 1),
        .@"union" => |info| try deserializeUnionAlloc(stream, info, allocator, T, debug, level + 1),
        else => unsupportedType(T),
    };
}

fn deserializeImpl(stream: anytype, comptime T: type, debug: bool, level: usize) !T {
    if (debug) {
        printIndent(level);
        std.debug.print("[deserialize] Type: {s}\n", .{@typeName(T)});
    }
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => try deserializeBool(stream, debug, level + 1),
        .float => try deserializeFloat(stream, T, debug, level + 1),
        .int => try deserializeInt(stream, T, debug, level + 1),
        .optional => |info| try deserializeOptional(stream, info.child, debug, level + 1),
        .array => |info| try deserializeArray(stream, info, debug, level + 1),
        .@"struct" => |info| try deserializeStruct(stream, info, T, debug, level + 1),
        .@"enum" => try deserializeEnum(stream, T, debug, level + 1),
        .@"union" => |info| try deserializeUnion(stream, info, T, debug, level + 1),
        else => unsupportedType(T),
    };
}

fn deserializeBufferInt(comptime T: type, source_ptr: *[]const u8, debug: bool) T {
    const bytesRequired = @sizeOf(T);
    const source = source_ptr.*;
    if (bytesRequired <= source.len) {
        var tmp: [bytesRequired]u8 = undefined;
        std.mem.copyForwards(u8, &tmp, source[0..bytesRequired]);
        source_ptr.* = source[bytesRequired..];
        const v = std.mem.readInt(T, &tmp, std.builtin.Endian.little);
        if (debug) {
            std.debug.print("[deserializeBufferInt] type: {s}, value: {any}\n", .{ @typeName(T), v });
        }
        return v;
    } else {
        invalidProtocol("Buffer ran out of bytes too soon.");
    }
}

fn deserializeBufferBool(source: *[]const u8, debug: bool) bool {
    const v = deserializeBufferInt(u8, source, debug);
    if (debug) {
        std.debug.print("[deserializeBufferBool] value: {d}\n", .{v});
    }
    return switch (v) {
        0 => return false,
        1 => return true,
        else => invalidProtocol("Boolean values should be encoded as a single byte with value 0 or 1 only."),
    };
}

fn deserializeBufferOptional(comptime T: type, source: *[]const u8, debug: bool) ?T {
    if (deserializeBufferBool(source, debug)) {
        if (debug) std.debug.print("[deserializeBufferOptional] present\n", .{});
        return deserializeBuffer(T, source, debug);
    } else {
        if (debug) std.debug.print("[deserializeBufferOptional] null\n", .{});
        return null;
    }
}

fn deserializeBufferFloat(comptime T: type, source: *[]const u8, debug: bool) T {
    switch (T) {
        f32 => {
            const v: T = @bitCast(deserializeBufferInt(u32, source, debug));
            if (debug) std.debug.print("[deserializeBufferFloat] f32 value: {d}\n", .{v});
            return v;
        },
        f64 => {
            const v: T = @bitCast(deserializeBufferInt(u64, source, debug));
            if (debug) std.debug.print("[deserializeBufferFloat] f64 value: {d}\n", .{v});
            return v;
        },
        else => unsupportedType(T),
    }
}

fn deserializeBufferEnum(comptime T: type, source: *[]const u8, debug: bool) T {
    const raw_tag = deserializeBufferInt(u32, source, debug);
    if (debug) std.debug.print("[deserializeBufferEnum] raw_tag: {d}\n", .{raw_tag});
    return @enumFromInt(raw_tag);
}

fn deserializeBufferStruct(comptime T: type, comptime info: std.builtin.Type.Struct, source: *[]const u8, debug: bool) T {
    var value: T = undefined;
    inline for (info.fields) |field| {
        if (debug) std.debug.print("[deserializeBufferStruct] field: {s}\n", .{field.name});
        @field(value, field.name) = deserializeBufferImpl(field.type, source, debug);
    }
    return value;
}

fn deserializeBufferUnion(comptime T: type, comptime info: std.builtin.Type.Union, source: *[]const u8, debug: bool) T {
    if (info.tag_type) |Tag| {
        const raw_tag = deserializeBufferInt(u32, source, debug);
        const tag: Tag = @enumFromInt(raw_tag);
        if (debug) std.debug.print("[deserializeBufferUnion] tag: {d}\n", .{raw_tag});
        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = deserializeBuffer(field.type, source, debug);
                return @unionInit(T, field.name, inner);
            }
        }
        unreachable;
    } else {
        unsupportedType(T);
    }
}

fn deserializeBufferArray(comptime info: std.builtin.Type.array, source_ptr: *[]const u8, debug: bool) [info.len]info.child {
    const T = @Type(.{ .array = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    var value: T = undefined;
    if (debug) std.debug.print("[deserializeBufferArray] len: {d}\n", .{info.len});
    if (info.child == u8) {
        const source = source_ptr.*;
        if (info.len <= source.len) {
            std.mem.copy(u8, &value, source[0..info.len]);
            source_ptr.* = source[info.len..];
        } else {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = deserializeBuffer(info.child, source_ptr, debug);
        }
    }
    return value;
}

fn deserializeBufferPointer(comptime info: std.builtin.Type.Pointer, source_ptr: *[]const u8, debug: bool) []const info.child {
    const T = @Type(.{ .pointer = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    switch (info.size) {
        .one => unsupportedType(T),
        .slice => {
            const len: usize = @intCast(deserializeBufferInt(u64, source_ptr, debug));
            if (debug) std.debug.print("[deserializeBufferPointer] slice len: {d}\n", .{len});
            if (info.child == u8) {
                const source = source_ptr.*;
                if (len <= source.len) {
                    source_ptr.* = source[len..];
                    return source[0..len];
                } else {
                    invalidProtocol("The stream end was found before all required bytes were read.");
                }
            } else {
                // we can't support a variable slice of types where the stream format
                // differs from in-memory format without allocating.
                unsupportedType(T);
            }
        },
        .C => unsupportedType(T),
        .Many => unsupportedType(T),
    }
}

fn deserializeBool(stream: anytype, debug: bool, level: usize) !bool {
    const v = try stream.readInt(u8, std.builtin.Endian.little);
    if (debug) {
        printIndent(level);
        std.debug.print("[deserializeBool] value: {d}\n", .{v});
    }
    switch (v) {
        0 => return false,
        1 => return true,
        else => invalidProtocol("Boolean values should be encoded as a single byte with value 0 or 1 only."),
    }
}

fn deserializeFloat(stream: anytype, comptime T: type, debug: bool, level: usize) !T {
    if (T == f32) {
        const v = try stream.readInt(u32, std.builtin.Endian.little);
        if (debug) {
            printIndent(level);
            std.debug.print("[deserializeFloat] f32 bits: {d}\n", .{v});
        }
        return @bitCast(v);
    } else if (T == f64) {
        const v = try stream.readInt(u64, std.builtin.Endian.little);
        if (debug) {
            printIndent(level);
            std.debug.print("[deserializeFloat] f64 bits: {d}\n", .{v});
        }
        return @bitCast(v);
    } else {
        unsupportedType(T);
    }
}

fn deserializeInt(stream: anytype, comptime T: type, debug: bool, level: usize) !T {
    const v = switch (T) {
        i8 => try stream.readInt(i8, std.builtin.Endian.little),
        i16 => try stream.readInt(i16, std.builtin.Endian.little),
        i32 => try stream.readInt(i32, std.builtin.Endian.little),
        i64 => try stream.readInt(i64, std.builtin.Endian.little),
        i128 => try stream.readInt(i128, std.builtin.Endian.little),
        i256 => try stream.readInt(i256, std.builtin.Endian.little),
        u8 => try stream.readInt(u8, std.builtin.Endian.little),
        u16 => try stream.readInt(u16, std.builtin.Endian.little),
        u32 => try stream.readInt(u32, std.builtin.Endian.little),
        u64 => try stream.readInt(u64, std.builtin.Endian.little),
        u128 => try stream.readInt(u128, std.builtin.Endian.little),
        u256 => try stream.readInt(u256, std.builtin.Endian.little),
        else => unsupportedType(T),
    };
    if (debug) {
        printIndent(level);
        std.debug.print("[deserializeInt] type: {s}, value: {any}\n", .{ @typeName(T), v });
    }
    return v;
}

fn deserializeOptionalAlloc(stream: anytype, allocator: std.mem.Allocator, comptime T: type, debug: bool, level: usize) !?T {
    switch (try stream.readInt(u8, std.builtin.Endian.little)) {
        0 => return null,
        1 => return try deserializeAllocImpl(stream, allocator, T, debug, level + 1),
        else => invalidProtocol("Optional is encoded as a single 0 valued byte for null, or a single 1 valued byte followed by the encoding of the contained value."),
    }
}

fn deserializeOptional(stream: anytype, comptime T: type, debug: bool, level: usize) !?T {
    switch (try stream.readInt(u8, std.builtin.Endian.little)) {
        0 => return null,
        1 => return try deserializeImpl(stream, T, debug, level + 1),
        else => invalidProtocol("Optional is encoded as a single 0 valued byte for null, or a single 1 valued byte followed by the encoding of the contained value."),
    }
}

fn deserializePointerAlloc(stream: anytype, comptime info: std.builtin.Type.Pointer, allocator: std.mem.Allocator, debug: bool, level: usize) ![]info.child {
    const T = @Type(.{ .pointer = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    switch (info.size) {
        .one => unsupportedType(T),
        .slice => {
            const len: usize = @intCast(try stream.readInt(u64, std.builtin.Endian.little));
            if (debug) {
                printIndent(level);
                std.debug.print("[deserializePointerAlloc] slice len: {d}\n", .{len});
            }
            if (len > 1024 * 1024) {
                return DeserializeError.LargeAlloc;
            }
            var memory = try allocator.alloc(info.child, len);
            if (info.child == u8) {
                const amount = try stream.readAll(memory);
                if (amount != len) {
                    invalidProtocol("The stream end was found before all required bytes were read.");
                }
            } else {
                for (0..len) |idx| {
                    memory[idx] = try deserializeAllocImpl(stream, allocator, info.child, debug, level + 1);
                }
            }
            return memory;
        },
        .c => unsupportedType(T),
        .many => unsupportedType(T),
    }
}

fn deserializeArrayAlloc(stream: anytype, comptime info: std.builtin.Type.Array, allocator: std.mem.Allocator, debug: bool, level: usize) ![info.len]info.child {
    const T = @Type(.{ .array = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    var value: T = undefined;
    if (debug) {
        printIndent(level);
        std.debug.print("[deserializeArrayAlloc] len: {d}\n", .{info.len});
    }
    if (info.child == u8) {
        const amount = try stream.readAll(value[0..]);
        if (amount != info.len) {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = try deserializeAllocImpl(stream, allocator, info.child, debug, level + 1);
        }
    }
    return value;
}

fn deserializeArray(stream: anytype, comptime info: std.builtin.Type.array, debug: bool, level: usize) ![info.len]info.child {
    const T = @Type(.{ .array = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    var value: T = undefined;
    if (debug) {
        printIndent(level);
        std.debug.print("[deserializeArray] len: {d}\n", .{info.len});
    }
    if (info.child == u8) {
        const amount = try stream.readAll(value[0..]);
        if (amount != info.len) {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = try deserializeImpl(stream, info.child, debug, level + 1);
        }
    }
    return value;
}

fn deserializeStructAlloc(stream: anytype, comptime info: std.builtin.Type.Struct, allocator: std.mem.Allocator, comptime T: type, debug: bool, level: usize) anyerror!T {
    var value: T = undefined;
    outer: inline for (info.fields) |field| {
        if (debug) {
            printIndent(level);
            std.debug.print("[deserializeStructAlloc] field: {s}\n", .{field.name});
        }
        if (@hasDecl(T, "meta")) {
            inline for (T.meta) |meta_field| {
                if (comptime std.mem.eql(u8, meta_field.field, field.name)) {
                    const intermediate = try deserializeAllocImpl(stream, allocator, meta_field.src_type, debug, level + 1);
                    @field(value, field.name) = switch (field.type) {
                        u256 => std.fmt.parseInt(u256, intermediate, 16) catch return DeserializeError.ParseIntError,
                        Bn254Fr => Bn254Fr.from_int(std.fmt.parseInt(u256, intermediate, 16) catch return DeserializeError.ParseIntError),
                        else => unreachable,
                    };
                    continue :outer;
                }
            }
        }
        @field(value, field.name) = try deserializeAllocImpl(stream, allocator, field.type, debug, level + 1);
    }
    return value;
}

fn deserializeStruct(stream: anytype, comptime info: std.builtin.Type.@"struct", comptime T: type, debug: bool) !T {
    var value: T = undefined;
    outer: inline for (info.fields) |field| {
        if (debug) std.debug.print("[deserializeStruct] field: {s}\n", .{field.name});
        if (@hasDecl(T, "meta")) {
            inline for (T.meta) |meta_field| {
                if (comptime std.mem.eql(u8, meta_field.field, field.name)) {
                    const intermediate = try deserializeImpl(stream, meta_field.src_type, debug, 1);
                    @field(value, field.name) = switch (field.type) {
                        u256 => std.fmt.parseInt(u256, intermediate, 16) catch return DeserializeError.ParseIntError,
                        Bn254Fr => Bn254Fr.from_int(std.fmt.parseInt(u256, intermediate, 16) catch return DeserializeError.ParseIntError),
                        else => unreachable,
                    };
                    continue :outer;
                }
            }
        }
        @field(value, field.name) = try deserializeImpl(stream, field.type, debug, 1);
    }
    return value;
}

fn deserializeEnum(stream: anytype, comptime T: type, debug: bool, level: usize) !T {
    const raw_tag = try deserializeInt(stream, u32, debug, level);
    if (debug) {
        printIndent(level);
        std.debug.print("[deserializeEnum] raw_tag: {d}\n", .{raw_tag});
    }
    const tag = std.meta.intToEnum(T, raw_tag) catch {
        std.debug.print("Enum conversion error: could not convert raw tag {d} to enum {s}\n", .{ raw_tag, @typeName(T) });
        return DeserializeError.InvalidEnumTag;
    };
    return tag;
}

fn deserializeUnionAlloc(stream: anytype, comptime info: std.builtin.Type.Union, allocator: std.mem.Allocator, comptime T: type, debug: bool, level: usize) !T {
    if (info.tag_type) |Tag| {
        const raw_tag = try deserializeAllocImpl(stream, allocator, u32, debug, level + 1);
        const tag: Tag = try std.meta.intToEnum(info.tag_type.?, raw_tag);
        if (debug) {
            printIndent(level);
            std.debug.print("[deserializeUnionAlloc] tag: {d}\n", .{raw_tag});
        }
        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = try deserializeAllocImpl(stream, allocator, field.type, debug, level + 1);
                const r = @unionInit(T, field.name, inner);
                return r;
            }
        }
        unreachable;
    } else {
        unsupportedType(T);
    }
}

fn deserializeUnion(stream: anytype, comptime info: std.builtin.Type.Union, comptime T: type, debug: bool, level: usize) !T {
    if (info.tag_type) |Tag| {
        const raw_tag = try deserializeImpl(stream, u32, debug, level + 1);
        const tag: Tag = @enumFromInt(raw_tag);
        if (debug) {
            printIndent(level);
            std.debug.print("[deserializeUnion] tag: {d}\n", .{raw_tag});
        }
        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = try deserializeImpl(stream, field.type, debug, level + 1);
                return @unionInit(T, field.name, inner);
            }
        }
        unreachable;
    } else {
        unsupportedType(T);
    }
}

pub fn serializeBool(stream: anytype, value: bool) @TypeOf(stream).Error!void {
    const code: u8 = if (value) @as(u8, 1) else @as(u8, 0);
    return stream.writeInt(u8, code, std.builtin.Endian.little);
}

pub fn serializeFloat(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    switch (T) {
        f32 => try stream.writeIntLittle(u32, @bitCast(value)),
        f64 => try stream.writeIntLittle(u64, @bitCast(value)),
        else => unsupportedType(T),
    }
}

pub fn serializeInt(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    switch (T) {
        i8 => try stream.writeInt(i8, value, std.builtin.Endian.little),
        i16 => try stream.writeInt(i16, value, std.builtin.Endian.little),
        i32 => try stream.writeInt(i32, value, std.builtin.Endian.little),
        i64 => try stream.writeInt(i64, value, std.builtin.Endian.little),
        i128 => try stream.writeInt(i128, value, std.builtin.Endian.little),
        i256 => try stream.writeInt(i256, value, std.builtin.Endian.little),
        u8 => try stream.writeInt(u8, value, std.builtin.Endian.little),
        u16 => try stream.writeInt(u16, value, std.builtin.Endian.little),
        u32 => try stream.writeInt(u32, value, std.builtin.Endian.little),
        u64 => try stream.writeInt(u64, value, std.builtin.Endian.little),
        u128 => try stream.writeInt(u128, value, std.builtin.Endian.little),
        u256 => try stream.writeInt(u256, value, std.builtin.Endian.little),
        else => unsupportedType(T),
    }
}

pub fn serializeOptional(stream: anytype, comptime T: type, value: ?T) @TypeOf(stream).Error!void {
    if (value) |actual| {
        try stream.writeIntLittle(u8, 1);
        try serialize(stream, actual);
    } else {
        // None
        try stream.writeIntLittle(u8, 0);
    }
}

pub fn serializePointer(stream: anytype, comptime info: std.builtin.Type.Pointer, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.sentinel_ptr != null) unsupportedType(T);
    switch (info.size) {
        .one => unsupportedType(T),
        .slice => {
            try stream.writeInt(u64, value.len, std.builtin.Endian.little);
            if (info.child == u8) {
                try stream.writeAll(value);
            } else {
                for (value) |item| {
                    try serialize(stream, item);
                }
            }
        },
        .c => unsupportedType(T),
        .many => unsupportedType(T),
    }
}

pub fn serializeArray(stream: anytype, comptime info: std.builtin.Type.array, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.sentinel_ptr != null) unsupportedType(T);
    if (info.child == u8) {
        try stream.writeAll(value);
    } else {
        for (value) |item| {
            try serialize(stream, item);
        }
    }
}

pub fn serializeStruct(stream: anytype, comptime info: std.builtin.Type.Struct, comptime T: type, value: T) @TypeOf(stream).Error!void {
    outer: inline for (info.fields) |field| {
        if (@hasDecl(T, "meta")) {
            inline for (T.meta) |meta_field| {
                if (comptime std.mem.eql(u8, meta_field.field, field.name)) {
                    var buffer: [64]u8 = undefined;
                    const result = std.fmt.bufPrint(&buffer, "{x:0>64}", .{@field(value, field.name)}) catch unreachable;
                    try serialize(stream, result);
                    continue :outer;
                }
            }
        }
        try serialize(stream, @field(value, field.name));
    }
}

pub fn serializeEnum(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    const tag: u32 = @intFromEnum(value);
    try serialize(stream, tag);
}

pub fn serializeUnion(stream: anytype, comptime info: std.builtin.Type.Union, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.tag_type) |UnionTagType| {
        const tag: u32 = @intFromEnum(value);
        try serialize(stream, tag);
        inline for (info.fields) |field| {
            if (value == @field(UnionTagType, field.name)) {
                try serialize(stream, @field(value, field.name));
            }
        }
    } else {
        unsupportedType(T);
    }
}

fn unsupportedType(comptime T: type) noreturn {
    @compileError("Unsupported type " ++ @typeName(T));
}

fn invalidProtocol(comptime message: []const u8) noreturn {
    @panic("Invalid protocol detected: " ++ message);
}

// test "round trip" {
//     const expectEqualStrings = std.testing.expectEqualStrings;
//     const expectEqual = std.testing.expectEqual;

//     const examples = @import("rust/examples.zig");

//     const TestUnion = union(enum) {
//         x: i32,
//         y: u32,
//     };
//     const TestEnum = enum {
//         One,
//         Two,
//     };
//     const TestTypeAlloc = struct {
//         u: TestUnion,
//         e: TestEnum,
//         s: []const u8,
//         point: [2]f64,
//         o: ?u8,

//         pub fn validate(self: @This(), other: @This()) !void {
//             try expectEqual(self.u, other.u);
//             try expectEqualStrings(self.s, other.s);
//             try expectEqual(self.point, other.point);
//             try expectEqual(self.o, other.o);
//         }
//     };

//     const TestType = struct {
//         u: TestUnion,
//         e: TestEnum,
//         point: [2]f64,
//         o: ?u8,

//         pub fn validate(self: @This(), other: @This()) !void {
//             try expectEqual(self.u, other.u);
//             try expectEqual(self.point, other.point);
//             try expectEqual(self.o, other.o);
//         }
//     };

//     const Integration = struct {
//         fn validateAlloc(comptime T: type, value: T, expected: []const u8) !void {
//             var buffer: [8192]u8 = undefined;

//             // serialize value and make sure it matches exactly the bytes
//             // from the rust implementation.
//             var output_stream = std.io.fixedBufferStream(buffer[0..]);
//             try serialize(output_stream.writer(), value);
//             try std.testing.expectEqualSlices(u8, expected, output_stream.getWritten());

//             // deserialize the bytes and make sure resulting object is exactly
//             // what we started with.
//             var input_stream = std.io.fixedBufferStream(expected);
//             var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//             defer arena.deinit();
//             const copy = try deserializeAlloc(input_stream.reader(), arena.allocator(), T);

//             if (@typeInfo(T) == .@"struct" and @hasDecl(T, "validate")) {
//                 try T.validate(value, copy);
//             } else {
//                 try std.testing.expectEqual(value, copy);
//             }

//             // NOTE: expectEqual does not do structural equality for slices.
//         }
//         fn validate(comptime T: type, value: T, expected: []const u8) !void {
//             var buffer: [8192]u8 = undefined;

//             // serialize value and make sure it matches exactly the bytes
//             // from the rust implementation.
//             var output_stream = std.io.fixedBufferStream(buffer[0..]);
//             try serialize(output_stream.writer(), value);
//             try std.testing.expectEqualSlices(u8, expected, output_stream.getWritten());

//             // deserialize the bytes and make sure resulting object is exactly
//             // what we started with.
//             var input_stream = std.io.fixedBufferStream(expected);
//             const copy = try deserialize(input_stream.reader(), T);

//             if (@typeInfo(T) == .@"struct" and @hasDecl(T, "validate")) {
//                 try T.validate(value, copy);
//             } else {
//                 try std.testing.expectEqual(value, copy);
//             }

//             // NOTE: expectEqual does not do structural equality for slices.
//         }

//         fn validateBuffer(comptime T: type, value: T, expected: []const u8) !void {
//             var buffer: [8192]u8 = undefined;

//             // serialize value and make sure it matches exactly the bytes
//             // from the rust implementation.
//             var output_stream = std.io.fixedBufferStream(buffer[0..]);
//             try serialize(output_stream.writer(), value);
//             try std.testing.expectEqualSlices(u8, expected, output_stream.getWritten());

//             // deserialize the bytes and make sure resulting object is exactly
//             // what we started with.
//             var input_stream: []const u8 = expected;
//             const copy = deserializeBuffer(T, &input_stream);
//             try expectEqual(@as(usize, 0), input_stream.len);

//             if (@typeInfo(T) == .@"struct" and @hasDecl(T, "validate")) {
//                 try T.validate(value, copy);
//             } else {
//                 try std.testing.expectEqual(value, copy);
//             }

//             // NOTE: expectEqual does not do structural equality for slices.
//         }
//     };

//     const testTypeAlloc = TestTypeAlloc{
//         .u = .{ .y = 5 },
//         .e = .one,
//         .s = "abcdefgh",
//         .point = .{ 1.1, 2.2 },
//         .o = 255,
//     };

//     try Integration.validateAlloc(TestTypeAlloc, testTypeAlloc, examples.test_type_alloc);
//     try Integration.validateAlloc(TestUnion, .{ .x = 6 }, examples.test_union);
//     try Integration.validateAlloc(TestEnum, .Two, examples.test_enum);
//     try Integration.validateAlloc(?u8, null, examples.none);
//     try Integration.validateAlloc(i8, 100, examples.int_i8);
//     try Integration.validateAlloc(u8, 101, examples.int_u8);
//     try Integration.validateAlloc(i16, 102, examples.int_i16);
//     try Integration.validateAlloc(u16, 103, examples.int_u16);
//     try Integration.validateAlloc(i32, 104, examples.int_i32);
//     try Integration.validateAlloc(u32, 105, examples.int_u32);
//     try Integration.validateAlloc(i64, 106, examples.int_i64);
//     try Integration.validateAlloc(u64, 107, examples.int_u64);
//     try Integration.validateAlloc(i128, 108, examples.int_i128);
//     try Integration.validateAlloc(u128, 109, examples.int_u128);
//     try Integration.validateAlloc(f32, 5.5, examples.int_f32);
//     try Integration.validateAlloc(f64, 6.6, examples.int_f64);
//     try Integration.validateAlloc(bool, false, examples.bool_false);
//     try Integration.validateAlloc(bool, true, examples.bool_true);

//     const testType = TestType{
//         .u = .{ .y = 5 },
//         .e = .one,
//         .point = .{ 1.1, 2.2 },
//         .o = 255,
//     };

//     try Integration.validate(TestType, testType, examples.test_type);
//     try Integration.validate(TestUnion, .{ .x = 6 }, examples.test_union);
//     try Integration.validate(TestEnum, .Two, examples.test_enum);
//     try Integration.validate(?u8, null, examples.none);
//     try Integration.validate(i8, 100, examples.int_i8);
//     try Integration.validate(u8, 101, examples.int_u8);
//     try Integration.validate(i16, 102, examples.int_i16);
//     try Integration.validate(u16, 103, examples.int_u16);
//     try Integration.validate(i32, 104, examples.int_i32);
//     try Integration.validate(u32, 105, examples.int_u32);
//     try Integration.validate(i64, 106, examples.int_i64);
//     try Integration.validate(u64, 107, examples.int_u64);
//     try Integration.validate(i128, 108, examples.int_i128);
//     try Integration.validate(u128, 109, examples.int_u128);
//     try Integration.validate(f32, 5.5, examples.int_f32);
//     try Integration.validate(f64, 6.6, examples.int_f64);
//     try Integration.validate(bool, false, examples.bool_false);
//     try Integration.validate(bool, true, examples.bool_true);

//     try Integration.validateBuffer(TestTypeAlloc, testTypeAlloc, examples.test_type_alloc);
//     try Integration.validateBuffer(TestType, testType, examples.test_type);
//     try Integration.validateBuffer(TestUnion, .{ .x = 6 }, examples.test_union);
//     try Integration.validateBuffer(TestEnum, .Two, examples.test_enum);
//     try Integration.validateBuffer(?u8, null, examples.none);
//     try Integration.validateBuffer(i8, 100, examples.int_i8);
//     try Integration.validateBuffer(u8, 101, examples.int_u8);
//     try Integration.validateBuffer(i16, 102, examples.int_i16);
//     try Integration.validateBuffer(u16, 103, examples.int_u16);
//     try Integration.validateBuffer(i32, 104, examples.int_i32);
//     try Integration.validateBuffer(u32, 105, examples.int_u32);
//     try Integration.validateBuffer(i64, 106, examples.int_i64);
//     try Integration.validateBuffer(u64, 107, examples.int_u64);
//     try Integration.validateBuffer(i128, 108, examples.int_i128);
//     try Integration.validateBuffer(u128, 109, examples.int_u128);
//     try Integration.validateBuffer(f32, 5.5, examples.int_f32);
//     try Integration.validateBuffer(f64, 6.6, examples.int_f64);
//     try Integration.validateBuffer(bool, false, examples.bool_false);
//     try Integration.validateBuffer(bool, true, examples.bool_true);

//     var iterator = deserializeSliceIterator(TestTypeAlloc, examples.test_type_alloc);
//     var first = iterator.next().?;
//     try first.validate(testTypeAlloc);
//     try expectEqual(@as(?TestTypeAlloc, null), iterator.next());
// }

// test "example" {
//     const bincode = @This(); //@import("bincode-zig");

//     const Shared = struct {
//         name: []const u8,
//         age: u32,
//     };

//     const example = Shared{ .name = "Cat", .age = 5 };

//     // Serialize Shared to buffer
//     var buffer: [8192]u8 = undefined;
//     var output_stream = std.io.fixedBufferStream(buffer[0..]);
//     try bincode.serialize(output_stream.writer(), example);

//     // Use an arena to gather allocations from deserializer to make
//     // them easy to clean up together. Allocations are required for
//     // slices.
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();

//     // Read what we wrote
//     var input_stream = std.io.fixedBufferStream(output_stream.getWritten());
//     const copy = try bincode.deserializeAlloc(
//         input_stream.reader(),
//         arena.allocator(),
//         Shared,
//     );

//     // Make sure it is the same
//     try std.testing.expectEqualStrings("Cat", copy.name);
//     try std.testing.expectEqual(@as(u32, 5), copy.age);
// }
