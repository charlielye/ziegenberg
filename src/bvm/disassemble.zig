const std = @import("std");
const load = @import("io.zig").load;
const serialize = @import("../bincode/bincode.zig").serialize;

pub fn disassemble(file_path: ?[]const u8, as_binary: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const opcodes = try load(allocator, file_path);
    // std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    const stdout = std.io.getStdOut().writer();
    if (as_binary) {
        try serialize(stdout, opcodes);
    } else {
        for (opcodes, 0..) |opcode, i| {
            stdout.print("{:0>4}: {any}\n", .{ i, opcode }) catch unreachable;
        }
    }
}
