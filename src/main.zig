const std = @import("std");
const execute = @import("root.zig").execute;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file_path> [calldata_path]\n", .{args[0]});
        return;
    }

    const file_path = args[1];
    const calldata_path = if (args.len == 3) args[2] else null;
    try execute(file_path, calldata_path);
}
