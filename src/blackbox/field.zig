const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const encode_fr = @import("./encode_fr.zig").encode_fr;
const decode_fr = @import("./encode_fr.zig").decode_fr;

export fn print_u256(input: [*]u256, num: usize) void {
    for (0..num) |i| {
        var v = input[i];
        if (v >> 255 == 1) {
            // std.debug.print("deconverting {}\n", .{v});
            v &= ~(@as(u256, 1) << 255);
        }
        const fr = Fr{ .limbs = @bitCast(v) };
        fr.print();
    }
}

pub export fn bn254_fr_normalize(lhs: *Fr) void {
    if (lhs.limbs[3] >> 63 == 1) {
        lhs.limbs[3] &= ~@as(u64, (1 << 63));
        lhs.from_montgomery();
    }
}

pub export fn bn254_fr_mul(lhs: *Fr, rhs: *Fr, result: *Fr) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.mul(r);
    encode_fr(result);
}

pub export fn bn254_fr_div(lhs: *Fr, rhs: *Fr, result: *Fr) bool {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    if (r.is_zero()) {
        return false;
    }
    result.* = l.div(r);
    encode_fr(result);
    return true;
}

pub export fn bn254_fr_add(lhs: *Fr, rhs: *Fr, result: *Fr) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.add(r);
    encode_fr(result);
}

pub export fn bn254_fr_sub(lhs: *Fr, rhs: *Fr, result: *Fr) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.sub(r);
    encode_fr(result);
}

pub export fn bn254_fr_eq(lhs: *Fr, rhs: *Fr, result: *u256) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = @intFromBool(l.eql(r));
}

pub export fn bn254_fr_lt(lhs: *Fr, rhs: *Fr, result: *u256) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = @intFromBool(l.lt(r));
}

pub export fn bn254_fr_leq(lhs: *Fr, rhs: *Fr, result: *u256) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = @intFromBool(l.leq(r));
}
