const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const ForeignCallParam = @import("./foreign_call.zig").ForeignCallParam;

fn every(comptime T: type, input: []const T, comptime f: fn (T) bool) bool {
    for (input) |e| if (!f(e)) return false;
    return true;
}

fn printable(c: u256) bool {
    return c <= std.math.maxInt(u8) and std.ascii.isPrint(@intCast(c));
}

fn convertSlice(comptime T: type, allocator: std.mem.Allocator, in: []u256) []T {
    const out = allocator.alloc(T, in.len) catch unreachable;
    for (in, out) |c, *o| o.* = @intCast(c);
    return out;
}

/// Brain-dead printing function as I can't be bothered with all the formatting logic.
pub fn handlePrint(allocator: std.mem.Allocator, mem: *Memory, params: []ForeignCallParam) !void {
    var buf = std.ArrayList(u8).init(allocator);
    var writer = buf.writer();
    try writer.print("{{ ", .{});
    const to_print = params[1..params.len];
    for (to_print, 0..) |p, i| {
        switch (p) {
            .Array => |arr| {
                if (every(u256, arr, printable)) {
                    try writer.print("{s}", .{convertSlice(u8, mem.allocator, arr)});
                } else {
                    try writer.print("{any}", .{arr});
                }
            },
            .Single => |v| {
                try writer.print("{}", .{v});
            },
        }
        if (i < to_print.len - 1) try writer.print(", ", .{});
    }
    try writer.print(" }}", .{});
    if (params[0].Single == 1) {
        try writer.print("\n", .{});
    }
    try std.io.getStdErr().writer().print("{s}", .{buf.items});
}
