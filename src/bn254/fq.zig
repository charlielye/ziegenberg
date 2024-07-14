const std = @import("std");
const Field = @import("../field/field.zig").Field;
const FieldParams = @import("../field/field_params.zig").FieldParams;

const FqParams = struct {
    pub const modulus: u256 = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3C208C16D87CFD47;
    pub const r_squared = 0x06D89F71CAB8351F47AB1EFF0A417FF6B5E71911D44501FBF32CFC5B538AFA89;
    pub const r_inv = 0x87d20782e4866389;
};

pub const Fq = Field(FieldParams(FqParams));

test "to/from buf" {
    const a = Fq.from_int(FqParams.modulus - 1);
    const b = a.to_buf();
    const e: [32]u8 = .{ 0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29, 0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d, 0x97, 0x81, 0x6a, 0x91, 0x68, 0x71, 0xca, 0x8d, 0x3c, 0x20, 0x8c, 0x16, 0xd8, 0x7c, 0xfd, 0x46 };
    try std.testing.expectEqual(e, b);

    const c = Fq.from_buf(b);
    try std.testing.expect(c.eql(a));
}

test "random" {
    const r = Fq.random();
    try std.testing.expect(r.to_int() > 0);
}

test "pseudo random" {
    const seed: u64 = 12345;
    // try std.posix.getrandom(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);

    const r = Fq.pseudo_random(&prng);
    const e = Fq.from_int(0x2cef8853c20c6dd015caa2fce6db8d693477f953796702a08d948a82def8a568);

    try std.testing.expectEqual(e, r);
}

test "add" {
    const a = Fq.from_int(0x0d510253a2ce62ccdc833531508914b8e50616a7a9d419d7d2e20e82f73d3e8);
    const b = Fq.from_int(0x08701f9d971fbc9605b671f6dc7b2090b03ef3f9ff9274e2829438b071fd14e);
    const e = Fq.from_int(0x15c121f139ee1f62e239a7282d04354995450aa1a9668eba55764733693a536);
    const r = a.add(b);
    try std.testing.expectEqual(e, r);
}

test "add wrap" {
    const a = Fq.from_int(FqParams.modulus - 1);
    const r = a.add(Fq.one);
    try std.testing.expectEqual(0, r.to_int());
}

test "sub" {
    const a = Fq.from_int(0x0cb8fe2108914f5308ef9af6d6ba9a482965d7ae7c6070a5d68d01812313fb7c);
    const b = Fq.from_int(0x1394324205c7a41d75124885b362b8feebc86ef589c530f62cd2a2a37e9bf14a);
    const e = Fq.from_int(0x29891a51e3fb4b5f4c2d9827a4d939a6d51ed34a5b0d0a3ce5daeaf47cf50779);
    const r = a.sub(b);
    try std.testing.expectEqual(e, r);
}

test "mul" {
    const a = Fq.from_int(0x03a81735d5aec0c36b86c81105dae2d12517b72250caa7b3a9b879029c49e60e);
    const b = Fq.from_int(0x072ae28836807df3a0a89f4a8af01df15dea4788a3b936a6744fc10aec23e56a);
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
    const e = Fq.from_int(0x0b1a0b04044d75f53716b0a6f253e6344d1140f756ed41941081a42fdaa7e23);
    const r = Fq.sqr(a);
    try std.testing.expectEqual(e, r);
}

test "sqr mul consistency" {
    const a = Fq.random();
    const b = Fq.random();
    // const a = Fq.from_int(0x3a81735d5aec0c36b86c81105dae2d12517b72250caa7b3a9b879029c49e60e);
    // const b = Fq.from_int(0x72ae28836807df3a0a89f4a8af01df15dea4788a3b936a6744fc10aec23e56a);
    var t1 = a.sub(b);
    var t2 = a.add(b);
    const mul_result = t1.mul(t2);
    t1 = a.sqr();
    t2 = b.sqr();
    const sqr_result = t1.sub(t2);
    try std.testing.expect(mul_result.eql(sqr_result));
}

test "montgomery consistency" {
    const a = Fq.random();
    const b = Fq.random();
    const aR = Fq.from_limbs(a.limbs);
    const aRR = Fq.from_limbs(aR.limbs);
    const bR = Fq.from_limbs(b.limbs);
    const bRR = Fq.from_limbs(bR.limbs);
    const bRRR = Fq.from_limbs(bRR.limbs);

    var result_a = aRR.mul(bRR); // abRRR
    const result_b = aR.mul(bRRR); // abRRR
    try std.testing.expect(result_a.eql(result_b));

    var result_c = aR.mul(bR); // abR
    var result_d = a.mul(b); // abR^-1
    result_a = Fq{ .limbs = result_a.to_limbs() }; // abRR
    result_a = Fq{ .limbs = result_a.to_limbs() }; // abR
    result_a = Fq{ .limbs = result_a.to_limbs() }; // ab
    result_c = Fq{ .limbs = result_c.to_limbs() }; // ab
    result_d = Fq.from_limbs(result_d.limbs); // ab
    try std.testing.expect(result_a.eql(result_c));
    try std.testing.expect(result_a.eql(result_d));
}

test "pow 0^0" {
    const a = Fq.from_int(0);
    try std.testing.expectEqual(1, a.pow(0).to_int());
}

test "pow 10^0" {
    const a = Fq.from_int(10);
    try std.testing.expectEqual(1, a.pow(0).to_int());
}

test "pow 10^1" {
    const a = Fq.from_int(10);
    try std.testing.expectEqual(10, a.pow(1).to_int());
}

test "pow 10^2" {
    const a = Fq.from_int(10);
    try std.testing.expectEqual(100, a.pow(2).to_int());
}

test "pow 10^10" {
    const a = Fq.from_int(10);
    try std.testing.expectEqual(10000000000, a.pow(10).to_int());
}

test "invert" {
    const input = Fq.random();
    const inverse = input.invert();
    const result = input.mul(inverse).reduce().reduce();
    try std.testing.expectEqual(Fq.one, result);
}
