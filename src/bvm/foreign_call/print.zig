const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const ForeignCallParam = @import("./foreign_call.zig").ForeignCallParam;

fn every(comptime T: type, input: []const T, comptime f: fn (T) bool) bool {
    for (input) |e| if (!f(e)) return false;
    return true;
}

fn printable(c: ForeignCallParam) bool {
    return c == .Single and c.Single <= std.math.maxInt(u8) and std.ascii.isPrint(@intCast(c.Single));
}

fn convertSlice(comptime T: type, allocator: std.mem.Allocator, in: []ForeignCallParam) []T {
    const out = allocator.alloc(T, in.len) catch unreachable;
    for (in, out) |c, *o| o.* = @intCast(c.Single);
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
                if (every(ForeignCallParam, arr, printable)) {
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
