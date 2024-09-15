const std = @import("std");
const deserializeOpcodes = @import("io.zig").deserializeOpcodes;
const BrilligOpcode = @import("io.zig").BrilligOpcode;

pub fn execute(file_path: []u8) !void {
    var allocator = std.heap.page_allocator;

    var serialized_data: []u8 = undefined;
    if (std.mem.eql(u8, file_path, "-")) {
        const stdin = std.io.getStdIn();
        serialized_data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    } else {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        serialized_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    }
    defer allocator.free(serialized_data);

    // Temp hack to locate start of brillig.
    // Assume first opcode is always the same.
    const find = @byteSwap(@as(u256, 0x0800000002000000000000000100000004000000400000000000000030303030));
    var start: usize = 0;
    for (0..serialized_data.len) |i| {
        if (@as(*align(1) u256, @ptrCast(&serialized_data[i])).* == find) {
            // Jump back 8 bytes to include the opcode count.
            start = i - 8;
            break;
        }
    }

    if (start == 0) {
        std.debug.print("Failed to find first opcode.\n", .{});
        return;
    }

    const opcodes = deserializeOpcodes(serialized_data[start..]) catch {
        std.debug.print("Deserialization failed.\n", .{});
        return;
    };

    for (opcodes) |elem| {
        std.debug.print("{any}\n", .{elem});
    }

    var brillig_vm = try BrilligVm.init(allocator);
    brillig_vm.execute_vm(opcodes);
    defer brillig_vm.deinit(allocator);
}

const BrilligVm = struct {
    const mem_size = 1024 * 1024 * 8;
    memory: []u256,

    pub fn init(allocator: std.mem.Allocator) !BrilligVm {
        return BrilligVm{
            .memory = try allocator.alloc(u256, mem_size),
        };
    }

    pub fn deinit(self: *BrilligVm, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
    }

    pub fn execute_vm(_: *BrilligVm, _: []BrilligOpcode) void {}
};
