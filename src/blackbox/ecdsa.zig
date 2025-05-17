const std = @import("std");

// Use this when you already have a hashed message and just want to pass it through undigested.
const PassThroughHasher = struct {
    hash: [32]u8 = undefined,
    pub const digest_length: usize = 32;
    pub const block_length: usize = 32;

    pub fn init(_: struct {}) PassThroughHasher {
        return PassThroughHasher{};
    }

    pub fn update(self: *PassThroughHasher, data: []const u8) void {
        std.debug.assert(data.len == PassThroughHasher.digest_length);
        std.mem.copyForwards(u8, &self.hash, data);
    }

    pub fn final(self: *PassThroughHasher, out: *[32]u8) void {
        std.mem.copyForwards(u8, out, &self.hash);
    }
};

pub fn verify_signature(comptime curve: anytype, hashed_message: [*]const u256, pub_key_x: [*]const u256, pub_key_y: [*]const u256, sig: [*]const u256, result: *u256) void {
    // We're dealing with an already hashed message, use a PassThroughHash to avoid re-hashing.
    const ecdsa = std.crypto.sign.ecdsa.Ecdsa(curve, PassThroughHasher);

    var hm_arr: [32]u8 = undefined;
    for (0..32) |i| {
        hm_arr[i] = @truncate(hashed_message[i]);
    }

    // Create pub key.
    var pk_arr: [65]u8 = undefined;
    pk_arr[0] = 0x4;
    for (0..32) |i| {
        pk_arr[i + 1] = @truncate(pub_key_x[i]);
        pk_arr[i + 33] = @truncate(pub_key_y[i]);
    }

    // Create signature.
    var r: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    for (0..32) |i| {
        r[i] = @truncate(sig[i]);
        s[i] = @truncate(sig[i + 32]);
    }
    const signature = ecdsa.Signature{ .r = r, .s = s };

    // std.debug.print("{x}\n", .{hm_arr});
    // std.debug.print("{x}\n", .{pk_arr});
    // std.debug.print("{x}\n", .{signature.r});
    // std.debug.print("{x}\n", .{signature.s});

    const public_key = ecdsa.PublicKey.fromSec1(&pk_arr) catch unreachable;

    // std.debug.print("{x}\n", .{public_key.p.x.limbs});
    // std.debug.print("{x}\n", .{public_key.p.y.limbs});

    signature.verify(&hm_arr, public_key) catch {
        result.* = 0;
        return;
    };

    result.* = 1;
}
