const std = @import("std");
const load = @import("io.zig").load;

pub fn disassemble(file_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const program = try load(allocator, file_path);
    // std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    const stdout = std.io.getStdOut().writer();
    for (program.functions) |function| {
        for (function.opcodes, 0..) |opcode, i| {
            try stdout.print("{:0>4}: ", .{i});
            try std.fmt.formatType(opcode, "", .{}, stdout, 10);
            try stdout.print("\n", .{});
        }
    }
}
