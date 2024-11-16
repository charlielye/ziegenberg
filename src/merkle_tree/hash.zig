const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const poseidon2Hash = @import("../poseidon2/poseidon2.zig").hash;

pub const HASH_SIZE = 32;
pub const Hash = Fr;

/// Our basic hash compression function. We use poseidon2.
pub inline fn compressTask(lhs: *const Hash, rhs: *const Hash, dst: *Hash) void {
    dst.* = poseidon2Hash(&[_]Fr{ lhs.*, rhs.* });
}
