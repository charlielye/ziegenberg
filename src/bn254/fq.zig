const std = @import("std");
const field_arith = @import("field_arith.zig");

const FqParams = struct {
    const modulus_u256 = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3C208C16D87CFD47;
    const not_modulus_u256: u256 = @bitCast(@as(i256, -modulus_u256));
    const twice_modulus_u256 = modulus_u256 + modulus_u256;
    const twice_not_modulus_u256 = @addWithOverflow(not_modulus_u256, not_modulus_u256)[0];

    pub const modulus = field_arith.to_limbs(modulus_u256);
    pub const not_modulus = field_arith.to_limbs(not_modulus_u256);
    pub const twice_not_modulus = field_arith.to_limbs(twice_not_modulus_u256);
    pub const r_squared = field_arith.to_limbs(0x06D89F71CAB8351F47AB1EFF0A417FF6B5E71911D44501FBF32CFC5B538AFA89);
    pub const r_inv = 0x87d20782e4866389;

    const one = field_arith.to_montgomery_form(.{ 1, 0, 0, 0 });
};

const Fq = struct {
    const one = Fq.to_montgomery_form(.{ 1, 0, 0, 0 });
    limbs: [4]u64,

    pub fn from_int(v: u256) Fq {
        return Fq.to_montgomery_form(field_arith.to_limbs(v));
    }

    pub fn to_int(self: Fq) u256 {
        const a = field_arith.from_montgomery_form(FqParams, self.limbs);
        return @as(u256, a[0]) + (@as(u256, a[1]) << 64) + (@as(u256, a[2]) << 128) + (@as(u256, a[3]) << 192);
    }

    pub fn random() Fq {
        const data = std.crypto.random.int(u512);
        return Fq.from_int(@truncate(data));
    }

    pub fn to_montgomery_form(data: [4]u64) Fq {
        return Fq{ .limbs = field_arith.to_montgomery_form(FqParams, data) };
    }

    pub fn from_montgomery_form(self: Fq) [4]u64 {
        return field_arith.from_montgomery_form(FqParams, self.limbs);
    }

    pub fn add(self: Fq, other: Fq) Fq {
        return Fq{ .limbs = field_arith.add(FqParams, self.limbs, other.limbs) };
    }

    pub fn mul(self: Fq, other: Fq) Fq {
        return Fq{ .limbs = field_arith.montgomery_mul(FqParams, self.limbs, other.limbs) };
    }

    pub fn sqr(self: Fq) Fq {
        return Fq{ .limbs = field_arith.montgomery_square(FqParams, self.limbs) };
    }
};

test "random" {
    const r = Fq.random();
    try std.testing.expect(r.to_int() > 0);
}

test "add" {
    const a = Fq.from_int(FqParams.modulus_u256 - 1);
    const r = a.add(Fq.one);
    try std.testing.expectEqual(0, r.to_int());
}

test "mul" {
    const a = Fq.from_int(0x3a81735d5aec0c36b86c81105dae2d12517b72250caa7b3a9b879029c49e60e);
    const b = Fq.from_int(0x72ae28836807df3a0a89f4a8af01df15dea4788a3b936a6744fc10aec23e56a);
    const e = Fq.from_int(0x1b2e4dac41400621cbf3f7b023a852b4ca9520d84c684efa6c0a789c0028fd09);
    const r = a.mul(b);
    try std.testing.expectEqual(e, r);
}

test "mul short" {
    const a = Fq.from_int(0xa);
    const b = Fq.from_int(0xb);
    const e = Fq.from_int(0xa * 0xb);
    const r = a.mul(b);
    try std.testing.expectEqual(e, r);
}

test "sqr" {
    const a = Fq.from_int(0x3a81735d5aec0c36b86c81105dae2d12517b72250caa7b3a9b879029c49e60e);
    const e = Fq.from_int(0xb1a0b04044d75f53716b0a6f253e6344d1140f756ed41941081a42fdaa7e23);
    const r = Fq.sqr(a);
    try std.testing.expectEqual(e, r);
}
