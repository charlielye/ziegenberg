const std = @import("std");
const common = @import("./common.zig");

const Field = common.Field;

pub const Fe = Field(.{
    .fiat = @import("bn254_64.zig"),
    .field_order = 21888242871839275222246405745257275088696311157297823662689037894645226208583,
    .field_bits = 254,
    .saturated_bits = 256,
    .encoded_length = 32,
});

test "zero" {
    const a = try Fe.fromInt(0);
    try std.testing.expect(a.equivalent(Fe.zero));
    try std.testing.expect(a.isZero());
}

test "one" {
    const a = try Fe.fromInt(1);
    try std.testing.expectEqual(Fe.one, a);
}

test "equality" {
    const a = Fe.fromInt(123);
    const b = Fe.fromInt(123);
    try std.testing.expectEqual(a, b);
}

test "equivalent" {
    const a = try Fe.fromInt(123);
    const b = try Fe.fromInt(123);
    try std.testing.expect(a.equivalent(b));
}

test "toInt" {
    const a = try Fe.fromInt(123);
    const b = Fe.toInt(a);
    try std.testing.expectEqual(b, 123);
}

test "toBytes / fromBytes little endian" {
    const a = try Fe.fromInt(123);
    const b = Fe.toBytes(a, .little);
    const c = Fe.fromBytes(b, .little);
    try std.testing.expectEqual(b, [_]u8{ 123, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(a, c);
}

test "toBytes / fromBytes big endian" {
    const a = try Fe.fromInt(123);
    const b = Fe.toBytes(a, .big);
    const c = Fe.fromBytes(b, .big);
    try std.testing.expectEqual(b, [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 123 });
    try std.testing.expectEqual(a, c);
}

test "add" {
    const a = try Fe.fromInt(21888242871839275222246405745257275088696311157297823662689037894645226208582);
    std.debug.print("\n{}\n", .{a.toInt()});
    const b = a.add(Fe.one);
    std.debug.print("\n{}\n", .{b.toInt()});
    try std.testing.expectEqual(Fe.zero, b);
}
