const std = @import("std");
const F = @import("../../bn254/fr.zig").Fr;
const proto = @import("../../protocol/package.zig");

/// Check if a type has a toField method at compile time
fn hasToField(comptime T: type) bool {
    const type_info = @typeInfo(T);
    // Only structs can have methods
    if (type_info != .@"struct") return false;

    // Check if the struct has a toField method
    inline for (type_info.@"struct".decls) |decl| {
        if (std.mem.eql(u8, decl.name, "toField")) {
            // Get the declaration and check if it's a function
            const decl_value = @field(T, decl.name);
            const decl_type = @TypeOf(decl_value);
            const decl_info = @typeInfo(decl_type);
            if (decl_info == .@"fn") {
                // Check if it takes self and returns Fr
                if (decl_info.@"fn".params.len == 1 and
                    decl_info.@"fn".return_type == F)
                {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Check if a type has a fromField method at compile time
fn hasFromField(comptime T: type) bool {
    const type_info = @typeInfo(T);
    // Only structs can have methods
    if (type_info != .@"struct") return false;

    // Check if the struct has a fromField method
    inline for (type_info.@"struct".decls) |decl| {
        if (std.mem.eql(u8, decl.name, "fromField")) {
            // Get the declaration and check if it's a function
            const decl_value = @field(T, decl.name);
            const decl_type = @TypeOf(decl_value);
            const decl_info = @typeInfo(decl_type);
            if (decl_info == .@"fn") {
                // Check if it takes Fr and returns T
                if (decl_info.@"fn".params.len == 1 and
                    decl_info.@"fn".return_type == T)
                {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Recursively flattens any struct into an ArrayList of field elements.
/// Handles F, integers, booleans, fixed-size arrays, and nested structs.
pub fn structToFields(comptime T: type, value: T, list: *std.ArrayList(F)) !void {
    // Handle F type first
    if (T == F) {
        try list.append(value);
        return;
    }

    // Check if type has a toField method
    if (comptime hasToField(T)) {
        try list.append(value.toField());
        return;
    }

    const type_info = @typeInfo(T);

    switch (type_info) {
        .@"struct" => |struct_info| {
            // For each field in the struct, recursively flatten
            inline for (struct_info.fields) |field| {
                const field_value = @field(value, field.name);
                try structToFields(field.type, field_value, list);
            }
        },
        .array => |array_info| {
            // For arrays, flatten each element
            for (value) |item| {
                try structToFields(array_info.child, item, list);
            }
        },
        .bool => {
            // Convert bool to field (0 or 1)
            try list.append(F.from_int(@intFromBool(value)));
        },
        .int => {
            // Convert integer to field
            try list.append(F.from_int(value));
        },
        .comptime_int => {
            // Convert comptime integer to field
            try list.append(F.from_int(value));
        },
        .optional => |optional_info| {
            // For optionals, append 0 if null, 1 + value if not null
            if (value) |v| {
                try list.append(F.one);
                try structToFields(optional_info.child, v, list);
            } else {
                try list.append(F.zero);
            }
        },
        .@"enum" => {
            // Convert enum to its integer value
            try list.append(F.from_int(@intFromEnum(value)));
        },
        .pointer => |ptr_info| {
            // Handle slices
            if (ptr_info.size == .slice) {
                // For slices, we need to store length followed by elements
                try list.append(F.from_int(value.len));
                // Only support []const u8 and []u8 for now
                if (ptr_info.child == u8) {
                    for (value) |byte| {
                        try list.append(F.from_int(byte));
                    }
                } else {
                    @compileError("Unsupported slice type for structToFields: " ++ @typeName(T));
                }
            } else {
                @compileError("Unsupported pointer type for structToFields: " ++ @typeName(T));
            }
        },
        else => {
            @compileError("Unsupported type for structToFields: " ++ @typeName(T));
        },
    }
}

/// Recursively populates a struct from a slice of field elements.
/// Returns the number of fields consumed.
fn fieldsToStructInternal(comptime T: type, fields: []const F, index: *usize) !T {
    // Handle F type first
    if (T == F) {
        if (index.* >= fields.len) return error.InsufficientFields;
        const result = fields[index.*];
        index.* += 1;
        return result;
    }

    // Check if type has a fromField method
    if (comptime hasFromField(T)) {
        if (index.* >= fields.len) return error.InsufficientFields;
        const result = T.fromField(fields[index.*]);
        index.* += 1;
        return result;
    }

    const type_info = @typeInfo(T);

    switch (type_info) {
        .@"struct" => |struct_info| {
            var result: T = undefined;
            // For each field in the struct, recursively populate
            inline for (struct_info.fields) |field| {
                @field(result, field.name) = try fieldsToStructInternal(field.type, fields, index);
            }
            return result;
        },
        .array => |array_info| {
            var result: T = undefined;
            // For arrays, populate each element
            for (&result) |*item| {
                item.* = try fieldsToStructInternal(array_info.child, fields, index);
            }
            return result;
        },
        .bool => {
            // Convert field to bool
            if (index.* >= fields.len) return error.InsufficientFields;
            const value = fields[index.*].to_int();
            index.* += 1;
            return value != 0;
        },
        .int => |int_info| {
            // Convert field to integer
            if (index.* >= fields.len) return error.InsufficientFields;
            const value = fields[index.*].to_int();

            // Debug print - remove once fixed
            // if (int_info.bits == 32) {
            //     std.debug.print("Converting field at index {} with value {} to u{}\n", .{ index.*, value, int_info.bits });
            // }

            index.* += 1;

            // Check if value fits in target type
            const max_value = std.math.maxInt(@Type(.{ .int = .{ .signedness = .unsigned, .bits = int_info.bits } }));
            if (value > max_value) {
                // For now, truncate to fit
                return @truncate(value);
            }

            // Handle signed vs unsigned integers
            if (int_info.signedness == .signed) {
                // For signed integers, we need to handle potential negative values
                // This is a simplified approach - may need refinement for large values
                return @intCast(value);
            } else {
                return @intCast(value);
            }
        },
        .comptime_int => {
            @compileError("Cannot deserialize to comptime_int");
        },
        .optional => |optional_info| {
            // For optionals, check if present (0 = null, 1 = value follows)
            if (index.* >= fields.len) return error.InsufficientFields;
            const is_some = fields[index.*].to_int() != 0;
            index.* += 1;

            if (is_some) {
                return try fieldsToStructInternal(optional_info.child, fields, index);
            } else {
                return null;
            }
        },
        .@"enum" => |enum_info| {
            // Convert field to enum
            if (index.* >= fields.len) return error.InsufficientFields;
            const value = fields[index.*].to_int();
            index.* += 1;

            // Find the enum field with the matching value
            inline for (enum_info.fields) |field| {
                if (field.value == value) {
                    return @enumFromInt(value);
                }
            }
            return error.InvalidEnumValue;
        },
        .pointer => |ptr_info| {
            // Handle slices - note this is limited and the caller must manage memory
            if (ptr_info.size == .slice) {
                // Read the length
                if (index.* >= fields.len) return error.InsufficientFields;
                const len = @as(usize, @intCast(fields[index.*].to_int()));
                index.* += 1;

                // Only support []const u8 and []u8 for now
                // Note: This returns a slice to static empty array for simplicity
                // Real usage would need proper memory management
                if (ptr_info.child == u8) {
                    if (len == 0) {
                        return &[_]u8{};
                    }
                    // Skip the actual data for now as we can't allocate
                    // In real usage, caller would need to handle allocation
                    var i: usize = 0;
                    while (i < len) : (i += 1) {
                        if (index.* >= fields.len) return error.InsufficientFields;
                        index.* += 1;
                    }
                    return &[_]u8{}; // Return empty slice as placeholder
                } else {
                    @compileError("Unsupported slice type for fieldsToStruct: " ++ @typeName(T));
                }
            } else {
                @compileError("Unsupported pointer type for fieldsToStruct: " ++ @typeName(T));
            }
        },
        else => {
            @compileError("Unsupported type for fieldsToStruct: " ++ @typeName(T));
        },
    }
}

// Helper function to make the API cleaner
pub fn fieldsToStruct(comptime T: type, fields: []const F) !T {
    var index: usize = 0;
    const result = try fieldsToStructInternal(T, fields, &index);
    if (index != fields.len) {
        return error.UnusedFields;
    }
    return result;
}

test "structToFields basic types" {
    const TestStruct = struct {
        a: F,
        b: u32,
        c: bool,
        d: [3]u8,
    };

    const test_value = TestStruct{
        .a = F.from_int(42),
        .b = 123,
        .c = true,
        .d = [3]u8{ 1, 2, 3 },
    };

    var list = std.ArrayList(F).init(std.testing.allocator);
    defer list.deinit();

    try structToFields(TestStruct, test_value, &list);

    try std.testing.expectEqual(@as(usize, 6), list.items.len);
    try std.testing.expect(list.items[0].eql(F.from_int(42)));
    try std.testing.expect(list.items[1].eql(F.from_int(123)));
    try std.testing.expect(list.items[2].eql(F.from_int(1))); // true
    try std.testing.expect(list.items[3].eql(F.from_int(1)));
    try std.testing.expect(list.items[4].eql(F.from_int(2)));
    try std.testing.expect(list.items[5].eql(F.from_int(3)));
}

test "structToFields nested structs" {
    const Inner = struct {
        x: F,
        y: bool,
    };

    const Outer = struct {
        inner: Inner,
        z: u16,
    };

    const test_value = Outer{
        .inner = Inner{
            .x = F.from_int(99),
            .y = false,
        },
        .z = 456,
    };

    var list = std.ArrayList(F).init(std.testing.allocator);
    defer list.deinit();

    try structToFields(Outer, test_value, &list);

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expect(list.items[0].eql(F.from_int(99)));
    try std.testing.expect(list.items[1].eql(F.from_int(0))); // false
    try std.testing.expect(list.items[2].eql(F.from_int(456)));
}

test "structToFields with AztecAddress" {
    const TestStruct = struct {
        addr: proto.AztecAddress,
        num: u32,
    };

    const test_value = TestStruct{
        .addr = proto.AztecAddress.init(F.from_int(0x1234)),
        .num = 789,
    };

    var list = std.ArrayList(F).init(std.testing.allocator);
    defer list.deinit();

    try structToFields(TestStruct, test_value, &list);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(list.items[0].eql(F.from_int(0x1234)));
    try std.testing.expect(list.items[1].eql(F.from_int(789)));
}

test "structToFields with custom toField type" {
    // Create a custom type with toField method
    const CustomType = struct {
        value: u64,

        pub fn toField(self: @This()) F {
            return F.from_int(self.value * 2); // Double the value for testing
        }
    };

    const TestStruct = struct {
        custom: CustomType,
        regular: u32,
    };

    const test_value = TestStruct{
        .custom = CustomType{ .value = 100 },
        .regular = 50,
    };

    var list = std.ArrayList(F).init(std.testing.allocator);
    defer list.deinit();

    try structToFields(TestStruct, test_value, &list);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(list.items[0].eql(F.from_int(200))); // 100 * 2
    try std.testing.expect(list.items[1].eql(F.from_int(50)));
}

test "roundtrip basic types" {
    const TestStruct = struct {
        a: F,
        b: u32,
        c: bool,
        d: [3]u8,
    };

    const original = TestStruct{
        .a = F.from_int(42),
        .b = 123,
        .c = true,
        .d = [3]u8{ 1, 2, 3 },
    };

    // Convert to fields
    var list = std.ArrayList(F).init(std.testing.allocator);
    defer list.deinit();
    try structToFields(TestStruct, original, &list);

    // Convert back to struct
    const recovered = try fieldsToStruct(TestStruct, list.items);

    // Verify equality
    try std.testing.expect(recovered.a.eql(original.a));
    try std.testing.expectEqual(original.b, recovered.b);
    try std.testing.expectEqual(original.c, recovered.c);
    try std.testing.expectEqualSlices(u8, &original.d, &recovered.d);
}

test "roundtrip nested structs" {
    const Inner = struct {
        x: F,
        y: bool,
    };

    const Outer = struct {
        inner: Inner,
        z: u16,
    };

    const original = Outer{
        .inner = Inner{
            .x = F.from_int(99),
            .y = false,
        },
        .z = 456,
    };

    // Convert to fields
    var list = std.ArrayList(F).init(std.testing.allocator);
    defer list.deinit();
    try structToFields(Outer, original, &list);

    // Convert back to struct
    const recovered = try fieldsToStruct(Outer, list.items);

    // Verify equality
    try std.testing.expect(recovered.inner.x.eql(original.inner.x));
    try std.testing.expectEqual(original.inner.y, recovered.inner.y);
    try std.testing.expectEqual(original.z, recovered.z);
}

test "roundtrip with optionals" {
    const TestStruct = struct {
        maybe_value: ?u32,
        definitely_value: u32,
        maybe_bool: ?bool,
    };

    // Test with Some values
    {
        const original = TestStruct{
            .maybe_value = 42,
            .definitely_value = 100,
            .maybe_bool = true,
        };

        var list = std.ArrayList(F).init(std.testing.allocator);
        defer list.deinit();
        try structToFields(TestStruct, original, &list);

        const recovered = try fieldsToStruct(TestStruct, list.items);

        try std.testing.expectEqual(original.maybe_value, recovered.maybe_value);
        try std.testing.expectEqual(original.definitely_value, recovered.definitely_value);
        try std.testing.expectEqual(original.maybe_bool, recovered.maybe_bool);
    }

    // Test with None values
    {
        const original = TestStruct{
            .maybe_value = null,
            .definitely_value = 200,
            .maybe_bool = null,
        };

        var list = std.ArrayList(F).init(std.testing.allocator);
        defer list.deinit();
        try structToFields(TestStruct, original, &list);

        const recovered = try fieldsToStruct(TestStruct, list.items);

        try std.testing.expectEqual(original.maybe_value, recovered.maybe_value);
        try std.testing.expectEqual(original.definitely_value, recovered.definitely_value);
        try std.testing.expectEqual(original.maybe_bool, recovered.maybe_bool);
    }
}

test "roundtrip with enums" {
    const TestEnum = enum(u8) {
        first = 0,
        second = 1,
        third = 2,
    };

    const TestStruct = struct {
        e: TestEnum,
        num: u32,
    };

    const original = TestStruct{
        .e = .second,
        .num = 999,
    };

    var list = std.ArrayList(F).init(std.testing.allocator);
    defer list.deinit();
    try structToFields(TestStruct, original, &list);

    const recovered = try fieldsToStruct(TestStruct, list.items);

    try std.testing.expectEqual(original.e, recovered.e);
    try std.testing.expectEqual(original.num, recovered.num);
}

test "roundtrip with AztecAddress" {
    const TestStruct = struct {
        addr: proto.AztecAddress,
        num: u32,
    };

    const original = TestStruct{
        .addr = proto.AztecAddress.init(F.from_int(0x1234567890abcdef)),
        .num = 789,
    };

    var list = std.ArrayList(F).init(std.testing.allocator);
    defer list.deinit();
    try structToFields(TestStruct, original, &list);

    const recovered = try fieldsToStruct(TestStruct, list.items);

    try std.testing.expect(recovered.addr.eql(original.addr));
    try std.testing.expectEqual(original.num, recovered.num);
}

test "error on insufficient fields" {
    const TestStruct = struct {
        a: u32,
        b: u32,
    };

    const fields = [_]F{F.from_int(42)}; // Only one field, but struct needs two

    const result = fieldsToStruct(TestStruct, &fields);
    try std.testing.expectError(error.InsufficientFields, result);
}

test "error on too many fields" {
    const TestStruct = struct {
        a: u32,
    };

    const fields = [_]F{ F.from_int(42), F.from_int(100) }; // Two fields, but struct needs one

    const result = fieldsToStruct(TestStruct, &fields);
    try std.testing.expectError(error.UnusedFields, result);
}
