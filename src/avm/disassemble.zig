const std = @import("std");
const load = @import("./io.zig").load;

pub fn disassemble(file_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const opcodes = try load(allocator, file_path);

    for (opcodes, 0..) |opcode, i| {
        std.debug.print("{:0>4}: {any}\n", .{ i, opcode });
    }
}
