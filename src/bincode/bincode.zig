const std = @import("std");

pub const Meta = struct {
    field: []const u8,
    src_type: type,
};

pub fn deserializeAlloc(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .Void => {},
        .Bool => try deserializeBool(stream),
        .Float => try deserializeFloat(stream, T),
        .Int => try deserializeInt(stream, T),
        .Optional => |info| try deserializeOptionalAlloc(stream, allocator, info.child),
        .Pointer => |info| try deserializePointerAlloc(stream, info, allocator),
        .Array => |info| try deserializeArrayAlloc(stream, info, allocator),
        .Struct => |info| try deserializeStructAlloc(stream, info, allocator, T),
        .Enum => try deserializeEnum(stream, T),
        .Union => |info| try deserializeUnionAlloc(stream, info, allocator, T),
        else => unsupportedType(T),
    };
}

pub fn deserialize(stream: anytype, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .Void => {},
        .Bool => try deserializeBool(stream),
        .Float => try deserializeFloat(stream, T),
        .Int => try deserializeInt(stream, T),
        .Optional => |info| try deserializeOptional(stream, info.child),
        .Array => |info| try deserializeArray(stream, info),
        .Struct => |info| try deserializeStruct(stream, info, T),
        .Enum => try deserializeEnum(stream, T),
        .Union => |info| try deserializeUnion(stream, info, T),
        else => unsupportedType(T),
    };
}

pub fn deserializeBuffer(comptime T: type, source: *[]const u8) T {
    return switch (@typeInfo(T)) {
        .Void => {},
        .Bool => deserializeBufferBool(source),
        .Float => deserializeBufferFloat(T, source),
        .Int => deserializeBufferInt(T, source),
        .Optional => |info| deserializeBufferOptional(info.child, source),
        .Pointer => |info| deserializeBufferPointer(info, source),
        .Array => |info| deserializeBufferArray(info, source),
        .Struct => |info| deserializeBufferStruct(T, info, source),
        .Enum => deserializeBufferEnum(T, source),
        .Union => |info| deserializeBufferUnion(T, info, source),
        else => unsupportedType(T),
    };
}

pub fn serialize(stream: anytype, value: anytype) @TypeOf(stream).Error!void {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .Void => {},
        .Bool => try serializeBool(stream, value),
        .Float => try serializeFloat(stream, T, value),
        .Int => try serializeInt(stream, T, value),
        .Optional => |info| try serializeOptional(stream, info.child, value),
        .Pointer => |info| try serializePointer(stream, info, T, value),
        .Array => |info| try serializeArray(stream, info, T, value),
        .Struct => |info| try serializeStruct(stream, info, T, value),
        .Enum => try serializeEnum(stream, T, value),
        .Union => |info| try serializeUnion(stream, info, T, value),
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

fn deserializeBufferInt(comptime T: type, source_ptr: *[]const u8) T {
    const bytesRequired = @sizeOf(T);
    const source = source_ptr.*;
    if (bytesRequired <= source.len) {
        var tmp: [bytesRequired]u8 = undefined;
        std.mem.copy(u8, &tmp, source[0..bytesRequired]);
        source_ptr.* = source[bytesRequired..];
        return std.mem.readInt(T, &tmp, std.builtin.Endian.little);
    } else {
        invalidProtocol("Buffer ran out of bytes too soon.");
    }
}

fn deserializeBufferBool(source: *[]const u8) bool {
    return switch (deserializeBufferInt(u8, source)) {
        0 => return false,
        1 => return true,
        else => invalidProtocol("Boolean values should be encoded as a single byte with value 0 or 1 only."),
    };
}

fn deserializeBufferOptional(comptime T: type, source: *[]const u8) ?T {
    if (deserializeBufferBool(source)) {
        return deserializeBuffer(T, source);
    } else {
        return null;
    }
}

fn deserializeBufferFloat(comptime T: type, source: *[]const u8) T {
    switch (T) {
        f32 => return @bitCast(deserializeBufferInt(u32, source)),
        f64 => return @bitCast(deserializeBufferInt(u64, source)),
        else => unsupportedType(T),
    }
}

fn deserializeBufferEnum(comptime T: type, source: *[]const u8) T {
    const raw_tag = deserializeBufferInt(u32, source);
    return @enumFromInt(raw_tag);
}

fn deserializeBufferStruct(comptime T: type, comptime info: std.builtin.Type.Struct, source: *[]const u8) T {
    var value: T = undefined;
    inline for (info.fields) |field| {
        @field(value, field.name) = deserializeBuffer(field.type, source);
    }
    return value;
}

fn deserializeBufferUnion(comptime T: type, comptime info: std.builtin.Type.Union, source: *[]const u8) T {
    if (info.tag_type) |Tag| {
        const raw_tag = deserializeBufferInt(u32, source);
        const tag: Tag = @enumFromInt(raw_tag);

        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = deserializeBuffer(field.type, source);
                return @unionInit(T, field.name, inner);
            }
        }
        unreachable;
    } else {
        unsupportedType(T);
    }
}

fn deserializeBufferArray(comptime info: std.builtin.Type.Array, source_ptr: *[]const u8) [info.len]info.child {
    const T = @Type(.{ .Array = info });
    if (info.sentinel != null) unsupportedType(T);
    var value: T = undefined;
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
            value[idx] = deserializeBuffer(info.child, source_ptr);
        }
    }
    return value;
}

fn deserializeBufferPointer(comptime info: std.builtin.Type.Pointer, source_ptr: *[]const u8) []const info.child {
    const T = @Type(.{ .Pointer = info });
    if (info.sentinel != null) unsupportedType(T);
    switch (info.size) {
        .One => unsupportedType(T),
        .Slice => {
            const len: usize = @intCast(deserializeBufferInt(u64, source_ptr));
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

fn deserializeBool(stream: anytype) !bool {
    switch (try stream.readInt(u8, std.builtin.Endian.little)) {
        0 => return false,
        1 => return true,
        else => invalidProtocol("Boolean values should be encoded as a single byte with value 0 or 1 only."),
    }
}

fn deserializeFloat(stream: anytype, comptime T: type) !T {
    switch (T) {
        f32 => return @bitCast(try stream.readInt(u32, std.builtin.Endian.little)),
        f64 => return @bitCast(try stream.readInt(u64, std.builtin.Endian.little)),
        else => unsupportedType(T),
    }
}

fn deserializeInt(stream: anytype, comptime T: type) !T {
    switch (T) {
        i8 => return try stream.readInt(i8, std.builtin.Endian.little),
        i16 => return try stream.readInt(i16, std.builtin.Endian.little),
        i32 => return try stream.readInt(i32, std.builtin.Endian.little),
        i64 => return try stream.readInt(i64, std.builtin.Endian.little),
        i128 => return try stream.readInt(i128, std.builtin.Endian.little),
        i256 => return try stream.readInt(i256, std.builtin.Endian.little),
        u8 => return try stream.readInt(u8, std.builtin.Endian.little),
        u16 => return try stream.readInt(u16, std.builtin.Endian.little),
        u32 => return try stream.readInt(u32, std.builtin.Endian.little),
        u64 => return try stream.readInt(u64, std.builtin.Endian.little),
        u128 => return try stream.readInt(u128, std.builtin.Endian.little),
        u256 => return try stream.readInt(u256, std.builtin.Endian.little),
        else => unsupportedType(T),
    }
}

fn deserializeOptionalAlloc(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !?T {
    switch (try stream.readInt(u8, std.builtin.Endian.little)) {
        // None
        0 => return null,
        // Some
        1 => return try deserializeAlloc(stream, allocator, T),
        else => invalidProtocol("Optional is encoded as a single 0 valued byte for null, or a single 1 valued byte followed by the encoding of the contained value."),
    }
}

fn deserializeOptional(stream: anytype, comptime T: type) !?T {
    switch (try stream.readInt(u8, std.builtin.Endian.little)) {
        // None
        0 => return null,
        // Some
        1 => return try deserialize(stream, T),
        else => invalidProtocol("Optional is encoded as a single 0 valued byte for null, or a single 1 valued byte followed by the encoding of the contained value."),
    }
}

fn deserializePointerAlloc(stream: anytype, comptime info: std.builtin.Type.Pointer, allocator: std.mem.Allocator) ![]info.child {
    const T = @Type(.{ .Pointer = info });
    if (info.sentinel != null) unsupportedType(T);
    switch (info.size) {
        .One => unsupportedType(T),
        .Slice => {
            const len: usize = @intCast(try stream.readInt(u64, std.builtin.Endian.little));
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
                    memory[idx] = try deserializeAlloc(stream, allocator, info.child);
                }
            }
            return memory;
        },
        .C => unsupportedType(T),
        .Many => unsupportedType(T),
    }
}

fn deserializeArrayAlloc(stream: anytype, comptime info: std.builtin.Type.Array, allocator: std.mem.Allocator) ![info.len]info.child {
    const T = @Type(.{ .Array = info });
    if (info.sentinel != null) unsupportedType(T);
    var value: T = undefined;
    if (info.child == u8) {
        const amount = try stream.readAll(value[0..]);
        if (amount != info.len) {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = try deserializeAlloc(stream, allocator, info.child);
        }
    }
    return value;
}

fn deserializeArray(stream: anytype, comptime info: std.builtin.Type.Array) ![info.len]info.child {
    const T = @Type(.{ .Array = info });
    if (info.sentinel != null) unsupportedType(T);
    var value: T = undefined;
    if (info.child == u8) {
        const amount = try stream.readAll(value[0..]);
        if (amount != info.len) {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = try deserialize(stream, info.child);
        }
    }
    return value;
}

const DeserializeError = error{
    EndOfStream,
    OutOfMemory,
    LargeAlloc,
    IntToEnumError,
    InvalidEnumTag,
    ParseIntError,
};

fn deserializeStructAlloc(stream: anytype, comptime info: std.builtin.Type.Struct, allocator: std.mem.Allocator, comptime T: type) DeserializeError!T {
    var value: T = undefined;
    outer: inline for (info.fields) |field| {
        if (@hasDecl(T, "meta")) {
            inline for (T.meta) |meta_field| {
                // @compileLog(std.mem.eql(u8, meta_field.field, field.name));
                if (comptime std.mem.eql(u8, meta_field.field, field.name)) {
                    // @compileLog(field.name, " ", meta_field.field);
                    const intermediate = try deserializeAlloc(stream, allocator, meta_field.src_type);
                    @field(value, field.name) = std.fmt.parseInt(u256, intermediate, 16) catch return DeserializeError.ParseIntError;
                    // std.debug.print("{s}\n", .{intermediate});
                    // @field(value, field.name) = field.type.deserialize(intermediate) catch return DeserializeError.CustomDeserializeError;
                    // std.debug.print("{any}\n", .{@field(value, field.name)});
                    // const field_value = @field(value, field.name);
                    // @field(value, field.name) = try @TypeOf(field_value).deserialize(intermediate) catch DeserializeError.CustomDeserializeError;
                    continue :outer;
                }
            }
        }
        @field(value, field.name) = try deserializeAlloc(stream, allocator, field.type);
    }
    return value;
}

fn deserializeStruct(stream: anytype, comptime info: std.builtin.Type.Struct, comptime T: type) !T {
    var value: T = undefined;
    outer: inline for (info.fields) |field| {
        if (@hasDecl(T, "meta")) {
            inline for (T.meta) |meta_field| {
                if (comptime std.mem.eql(u8, meta_field.field, field.name)) {
                    const intermediate = try deserialize(stream, meta_field.src_type);
                    @field(value, field.name) = std.fmt.parseInt(u256, intermediate, 16) catch return DeserializeError.ParseIntError;
                    // @field(value, field.name) = try field.type.deserializer(intermediate);
                    // const field_value = @field(value, field.name);
                    // @field(value, field.name) = try @TypeOf(field_value).deserialize(intermediate);
                    continue :outer;
                }
            }
        }
        @field(value, field.name) = try deserialize(stream, field.type);
    }
    return value;
}

fn deserializeEnum(stream: anytype, comptime T: type) !T {
    const raw_tag = try deserializeInt(stream, u32);
    return @enumFromInt(raw_tag);
}

fn deserializeUnionAlloc(stream: anytype, comptime info: std.builtin.Type.Union, allocator: std.mem.Allocator, comptime T: type) !T {
    if (info.tag_type) |Tag| {
        const raw_tag = try deserializeAlloc(stream, allocator, u32);
        const tag: Tag = try std.meta.intToEnum(info.tag_type.?, raw_tag);

        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = try deserializeAlloc(stream, allocator, field.type);
                const r = @unionInit(T, field.name, inner);
                // std.debug.print("{}\n", .{r});
                return r;
            }
        }
        unreachable;
    } else {
        unsupportedType(T);
    }
}

fn deserializeUnion(stream: anytype, comptime info: std.builtin.Type.Union, comptime T: type) !T {
    if (info.tag_type) |Tag| {
        const raw_tag = try deserialize(stream, u32);
        const tag: Tag = @enumFromInt(raw_tag);

        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = try deserialize(stream, field.type);
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
    if (info.sentinel != null) unsupportedType(T);
    switch (info.size) {
        .One => unsupportedType(T),
        .Slice => {
            try stream.writeInt(u64, value.len, std.builtin.Endian.little);
            if (info.child == u8) {
                try stream.writeAll(value);
            } else {
                for (value) |item| {
                    try serialize(stream, item);
                }
            }
        },
        .C => unsupportedType(T),
        .Many => unsupportedType(T),
    }
}

pub fn serializeArray(stream: anytype, comptime info: std.builtin.Type.Array, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.sentinel != null) unsupportedType(T);
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
                    const result = try std.fmt.bufPrint(&buffer, "{x:0>64}", .{@field(value, field.name)});
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

//             if (@typeInfo(T) == .Struct and @hasDecl(T, "validate")) {
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

//             if (@typeInfo(T) == .Struct and @hasDecl(T, "validate")) {
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

//             if (@typeInfo(T) == .Struct and @hasDecl(T, "validate")) {
//                 try T.validate(value, copy);
//             } else {
//                 try std.testing.expectEqual(value, copy);
//             }

//             // NOTE: expectEqual does not do structural equality for slices.
//         }
//     };

//     const testTypeAlloc = TestTypeAlloc{
//         .u = .{ .y = 5 },
//         .e = .One,
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
//         .e = .One,
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
