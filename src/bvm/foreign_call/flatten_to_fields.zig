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

/// Recursively flattens any struct into an ArrayList of field elements.
/// Handles F, integers, booleans, fixed-size arrays, and nested structs.
pub fn flattenToFields(comptime T: type, value: T, list: *std.ArrayList(F)) !void {
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
                try flattenToFields(field.type, field_value, list);
            }
        },
        .array => |array_info| {
            // For arrays, flatten each element
            for (value) |item| {
                try flattenToFields(array_info.child, item, list);
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
                try flattenToFields(optional_info.child, v, list);
            } else {
                try list.append(F.zero);
            }
        },
        .@"enum" => {
            // Convert enum to its integer value
            try list.append(F.from_int(@intFromEnum(value)));
        },
        else => {
            @compileError("Unsupported type for flattenToFields: " ++ @typeName(T));
        },
    }
}

test "flattenToFields basic types" {
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

    try flattenToFields(TestStruct, test_value, &list);

    try std.testing.expectEqual(@as(usize, 6), list.items.len);
    try std.testing.expect(list.items[0].eql(F.from_int(42)));
    try std.testing.expect(list.items[1].eql(F.from_int(123)));
    try std.testing.expect(list.items[2].eql(F.from_int(1))); // true
    try std.testing.expect(list.items[3].eql(F.from_int(1)));
    try std.testing.expect(list.items[4].eql(F.from_int(2)));
    try std.testing.expect(list.items[5].eql(F.from_int(3)));
}

test "flattenToFields nested structs" {
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

    try flattenToFields(Outer, test_value, &list);

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expect(list.items[0].eql(F.from_int(99)));
    try std.testing.expect(list.items[1].eql(F.from_int(0))); // false
    try std.testing.expect(list.items[2].eql(F.from_int(456)));
}

test "flattenToFields with AztecAddress" {
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

    try flattenToFields(TestStruct, test_value, &list);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(list.items[0].eql(F.from_int(0x1234)));
    try std.testing.expect(list.items[1].eql(F.from_int(789)));
}

test "flattenToFields with custom toField type" {
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

    try flattenToFields(TestStruct, test_value, &list);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(list.items[0].eql(F.from_int(200))); // 100 * 2
    try std.testing.expect(list.items[1].eql(F.from_int(50)));
}
