const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    for (builtin.test_functions) |t| {
        if (std.mem.containsAtLeast(u8, t.name, 1, ".SKIP_")) {
            continue;
        }
        try stdout.print("{s}\n", .{t.name});
    }
}
