const std = @import("std");
const Bn254Fq = @import("bn254/fq.zig").Fq;
const Bn254Fr = @import("bn254/fr.zig").Fr;
usingnamespace @import("bn254/fq.zig");
usingnamespace @import("bn254/g1.zig");
usingnamespace @import("grumpkin/g1.zig");
usingnamespace @import("srs/package.zig");
usingnamespace @import("msm/naive.zig");
const testing = std.testing;
const rdtsc = @import("timer/rdtsc.zig").rdtsc;
const field_arith = @import("field/field_arith.zig");

usingnamespace @import("blackbox/blackbox.zig");
const encode_fr = @import("blackbox/encode_fr.zig").encode_fr;
const decode_fr = @import("blackbox/encode_fr.zig").decode_fr;

export fn print_u256(input: [*]u256, num: usize) void {
    for (0..num) |i| {
        var v = input[i];
        if (v >> 255 == 1) {
            // std.debug.print("deconverting {}\n", .{v});
            v &= ~(@as(u256, 1) << 255);
        }
        const fr = Bn254Fr{ .limbs = @bitCast(v) };
        fr.print();
    }
}

export fn bn254_fq_add(lhs: *[4]u64, rhs: *[4]u64, result: *[4]u64) void {
    result.* = Bn254Fq.from_limbs(lhs.*).add(Bn254Fq.from_limbs(rhs.*)).to_limbs();
}

export fn bn254_fq_mul(lhs: *[4]u64, rhs: *[4]u64, result: *[4]u64) void {
    result.* = Bn254Fq.from_limbs(lhs.*).mul(Bn254Fq.from_limbs(rhs.*)).to_limbs();
}

export fn bn254_fq_eql(lhs: *[4]u64, rhs: *[4]u64) bool {
    return Bn254Fq.from_limbs(lhs.*).eql(Bn254Fq.from_limbs(rhs.*));
}

// export fn bn254_fr_add(lhs: *[4]u64, rhs: *[4]u64, result: *[4]u64) void {
//     result.* = Bn254Fr.from_limbs(lhs.*).add(Bn254Fr.from_limbs(rhs.*)).to_limbs();
// }

// export fn bn254_fr_mul(lhs: *[4]u64, rhs: *[4]u64, result: *[4]u64) void {
//     result.* = Bn254Fr.from_limbs(lhs.*).mul(Bn254Fr.from_limbs(rhs.*)).to_limbs();
// }

export fn bn254_fr_normalize(lhs: *Bn254Fr) void {
    if (lhs.limbs[3] >> 63 == 1) {
        lhs.limbs[3] &= ~@as(u64, (1 << 63));
        lhs.from_montgomery();
    }
}

export fn bn254_fr_mul(lhs: *Bn254Fr, rhs: *Bn254Fr, result: *Bn254Fr) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.mul(r);
    encode_fr(result);
}

export fn bn254_fr_div(lhs: *Bn254Fr, rhs: *Bn254Fr, result: *Bn254Fr) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.div(r);
    encode_fr(result);
}

export fn bn254_fr_add(lhs: *Bn254Fr, rhs: *Bn254Fr, result: *Bn254Fr) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.add(r);
    encode_fr(result);
}

export fn bn254_fr_sub(lhs: *Bn254Fr, rhs: *Bn254Fr, result: *Bn254Fr) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.sub(r);
    encode_fr(result);
}

export fn bn254_fr_eq(lhs: *Bn254Fr, rhs: *Bn254Fr, result: *bool) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.eql(r);
}

export fn bn254_fr_lt(lhs: *Bn254Fr, rhs: *Bn254Fr, result: *bool) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.lt(r);
}

export fn bn254_fr_leq(lhs: *Bn254Fr, rhs: *Bn254Fr, result: *bool) void {
    const l = decode_fr(lhs);
    const r = decode_fr(rhs);
    result.* = l.leq(r);
}

test {
    @import("std").testing.refAllDecls(@This());
}
