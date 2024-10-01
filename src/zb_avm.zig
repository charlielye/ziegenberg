const std = @import("std");
const deserializeOpcodes = @import("./avm/io.zig").deserialize_opcodes;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const stdin = std.io.getStdIn();
    const bytecode = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    const opcodes = try deserializeOpcodes(allocator, bytecode);

    for (opcodes, 0..) |opcode, i| {
        std.debug.print("{:0>4}: {any}\n", .{ i, opcode });
    }
}
