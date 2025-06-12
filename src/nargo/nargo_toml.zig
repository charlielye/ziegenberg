const std = @import("std");
const toml = @import("toml");

pub const Package = struct {
    name: []const u8,
    version: ?[]const u8,
    compiler_version: ?[]const u8,
    type: []const u8,
};

pub const NargoToml = struct {
    package: Package,
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !NargoToml {
    var parser = toml.Parser(NargoToml).init(allocator);
    defer parser.deinit();

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size + 1);
    _ = try file.readAll(buf[0..stat.size]);
    buf[stat.size] = '\n';
    defer allocator.free(buf);

    const result = try parser.parseString(buf);
    return result.value;
}

test "parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prover_toml = try load(arena.allocator(), "./aztec-packages/noir/noir-repo/test_programs/execution_success/1_mul/Nargo.toml");

    try std.testing.expectEqualDeep("1_mul", prover_toml.package.name);
    try std.testing.expectEqualDeep("0.1.0", prover_toml.package.version);
    try std.testing.expectEqualDeep("bin", prover_toml.package.type);
}
