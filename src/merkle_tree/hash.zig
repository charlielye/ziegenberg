const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const poseidon2Hash = @import("../poseidon2/poseidon2.zig").hash;

pub const HASH_SIZE = 32;
pub const Hash = Fr;
pub const HashFunc = fn (lhs: *const Hash, rhs: *const Hash, dst: *Hash) callconv(.Inline) void;

pub inline fn poseidon2(lhs: *const Hash, rhs: *const Hash, dst: *Hash) void {
    dst.* = poseidon2Hash(&[_]Fr{ lhs.*, rhs.* });
}

pub inline fn sha256fr(lhs: *const Hash, rhs: *const Hash, dst: *Hash) void {
    const hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(lhs);
    hasher.update(rhs);
    const h = hasher.finalResult();
    dst.* = Fr.from_buf(h);
}
