const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    for (builtin.test_functions) |t| {
        try stdout.print("{s}\n", .{t.name});
    }
}
