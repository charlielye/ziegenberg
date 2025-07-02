const std = @import("std");
const toml = @import("toml");

pub const ProverToml = toml.Table;

/// Load the abi from the json file.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !ProverToml {
    var parser = toml.Parser(ProverToml).init(allocator);
    defer parser.deinit();
    const result = try parser.parseFile(path);
    return result.value;
}

test "parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prover_toml = try load(arena.allocator(), "./aztec-packages/noir/noir-repo/test_programs/execution_success/a_1_mul/Prover.toml");

    try std.testing.expectEqualDeep("3", prover_toml.get("x").?.string);
    try std.testing.expectEqualDeep("4", prover_toml.get("y").?.string);
    try std.testing.expectEqualDeep("429981696", prover_toml.get("z").?.string);
}
