const std = @import("std");

pub fn get_msb(limbs: [4]u64) u8 {
    var msb: u64 = 0;

    msb += @intFromBool(limbs[3] != 0 and msb == 0) * @as(u64, (@subWithOverflow(63, @clz(limbs[3]))[0] + @as(u64, 192)));
    msb += @intFromBool(limbs[2] != 0 and msb == 0) * @as(u64, (@subWithOverflow(63, @clz(limbs[2]))[0] + @as(u64, 128)));
    msb += @intFromBool(limbs[1] != 0 and msb == 0) * @as(u64, (@subWithOverflow(63, @clz(limbs[1]))[0] + @as(u64, 64)));
    msb += @intFromBool(limbs[0] != 0 and msb == 0) * @as(u64, (@subWithOverflow(63, @clz(limbs[0]))[0]));

    return @truncate(msb);
}

test "msb 0" {
    try std.testing.expectEqual(0, get_msb(.{ 1, 0, 0, 0 }));
}

test "msb 63" {
    try std.testing.expectEqual(63, get_msb(.{ 1 << 63, 0, 0, 0 }));
}

test "msb 64" {
    try std.testing.expectEqual(64, get_msb(.{ 0, 1, 0, 0 }));
}

test "msb 255" {
    try std.testing.expectEqual(255, get_msb(.{ 2, 0, 0, 1 << 63 }));
}
