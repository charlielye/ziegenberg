const std = @import("std");
const hash = @import("./hash.zig");
const merkle_tree = @import("./merkle_tree.zig");
const indexed_merkle_tree = @import("./indexed_merkle_tree.zig");

// Export types that are used externally
pub const MerkleTreeMem = merkle_tree.MerkleTreeMem;
pub const poseidon2 = hash.poseidon2;
pub const Hash = hash.Hash;

test {
    std.testing.refAllDecls(@This());
    _ = hash;
    _ = merkle_tree;
    _ = indexed_merkle_tree;
}