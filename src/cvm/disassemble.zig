const std = @import("std");
const load = @import("io.zig").load;

pub fn disassemble(file_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const program = try load(allocator, file_path);
    // std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    const stdout = std.io.getStdOut().writer();
    for (program.functions, 0..) |function, fi| {
        for (function.opcodes, 0..) |opcode, i| {
            try stdout.print("{:0>2}: {:0>4}: {}\n", .{ fi, i, opcode });
        }
    }
    // std.debug.print("uf: {}\n", .{program.unconstrained_functions.len});
}
