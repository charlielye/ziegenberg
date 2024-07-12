const std = @import("std");
const field_arith = @import("field_arith.zig");
const get_msb = @import("get_msb.zig").get_msb;
const Field = @import("field.zig").Field;

const FqParams = struct {
    const modulus_u256: u256 = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3C208C16D87CFD47;
    const twice_modulus_u256: u256 = modulus_u256 + modulus_u256;
    const not_modulus_u256: u256 = @bitCast(-@as(i256, modulus_u256));
    const twice_not_modulus_u256: u256 = @bitCast(-@as(i256, twice_modulus_u256));

    pub const modulus = field_arith.to_limbs(modulus_u256);
    pub const twice_modulus = field_arith.to_limbs(twice_modulus_u256);
    pub const not_modulus = field_arith.to_limbs(not_modulus_u256);
    pub const twice_not_modulus = field_arith.to_limbs(twice_not_modulus_u256);
    pub const r_squared = field_arith.to_limbs(0x06D89F71CAB8351F47AB1EFF0A417FF6B5E71911D44501FBF32CFC5B538AFA89);
    pub const r_inv = 0x87d20782e4866389;

    const one = field_arith.to_montgomery_form(.{ 1, 0, 0, 0 });
};

// Fq field element.
// The montgomery form is not exposed externally, unless you read the limbs directly.
// pub const Fq = struct {
//     // TODO have params here and make generic field.
//     pub const modulus = FqParams.modulus;
//     pub const twice_modulus = FqParams.twice_modulus;
//     pub const one = Fq.from_int(1);
//     pub const zero = Fq.from_int(0);
//     limbs: [4]u64,

//     pub fn from_limbs(limbs: [4]u64) Fq {
//         return Fq{ .limbs = field_arith.to_montgomery_form(FqParams, limbs) };
//     }

//     // pub fn from_montgomery_limbs(limbs: [4]u64) Fq {
//     //     return Fq{ .limbs = limbs };
//     // }

//     pub fn to_limbs(self: Fq) [4]u64 {
//         return field_arith.from_montgomery_form(FqParams, self.limbs);
//     }

//     pub fn from_int(v: u256) Fq {
//         return Fq.from_limbs(field_arith.to_limbs(v));
//     }

//     pub fn to_int(self: Fq) u256 {
//         const a = self.to_limbs();
//         return @as(u256, a[0]) + (@as(u256, a[1]) << 64) + (@as(u256, a[2]) << 128) + (@as(u256, a[3]) << 192);
//     }

//     pub fn random() Fq {
//         const data = std.crypto.random.int(u512);
//         return Fq.from_int(@truncate(data));
//     }

//     pub fn add(self: Fq, other: Fq) Fq {
//         return Fq{ .limbs = field_arith.add(FqParams, self.limbs, other.limbs) };
//     }

//     pub fn sub(self: Fq, other: Fq) Fq {
//         return Fq{ .limbs = field_arith.sub_coarse(FqParams, self.limbs, other.limbs) };
//     }

//     pub fn mul(self: Fq, other: Fq) Fq {
//         return Fq{ .limbs = field_arith.montgomery_mul(FqParams, self.limbs, other.limbs) };
//     }

//     pub fn sqr(self: Fq) Fq {
//         return Fq{ .limbs = field_arith.montgomery_square(FqParams, self.limbs) };
//     }

//     pub fn neg(self: Fq) Fq {
//         const p = Fq{ .limbs = .{ Fq.twice_modulus[0], Fq.twice_modulus[1], Fq.twice_modulus[2], Fq.twice_modulus[3] } };
//         return p.sub(self).reduce();
//     }

//     fn get_bit(self: Fq, bit_index: u64) bool {
//         std.debug.assert(bit_index < 256);
//         const idx = bit_index >> 6;
//         const shift: u6 = @truncate(bit_index & 63);
//         return (self.limbs[idx] >> shift) & 1 == 1;
//     }

//     fn pow(self: Fq, exponent: u256) Fq {
//         if (exponent == 0) {
//             return Fq.one;
//         } else if (self.is_zero()) {
//             return self;
//         }

//         var accumulator = self;
//         const to_mul = self;
//         const maximum_set_bit = 255 - @clz(exponent);
//         // field_arith.debugPrintArray(exponent.limbs);
//         // std.debug.print("{}\n", .{exponent});
//         // std.debug.print("{}\n", .{maximum_set_bit});

//         for (0..maximum_set_bit) |i| {
//             accumulator = sqr(accumulator);
//             if ((exponent >> @truncate(i)) & 1 == 1) {
//                 accumulator = accumulator.mul(to_mul);
//             }
//         }

//         return accumulator;
//     }

//     pub fn eql(self: Fq, other: Fq) bool {
//         const a = field_arith.reduce(FqParams, self.limbs);
//         const b = field_arith.reduce(FqParams, other.limbs);
//         return std.mem.eql(u64, &a, &b);
//     }

//     pub fn is_zero(self: Fq) bool {
//         return self.eql(Fq.zero);
//     }

//     fn print(self: Fq) void {
//         std.debug.print("0x{x:0>64}\n", .{self.to_int()});
//     }
// };

pub const Fq = Field(FqParams);

test "random" {
    const r = Fq.random();
    try std.testing.expect(r.to_int() > 0);
}

test "add" {
    const a = Fq.from_int(0x0d510253a2ce62ccdc833531508914b8e50616a7a9d419d7d2e20e82f73d3e8);
    const b = Fq.from_int(0x08701f9d971fbc9605b671f6dc7b2090b03ef3f9ff9274e2829438b071fd14e);
    const e = Fq.from_int(0x15c121f139ee1f62e239a7282d04354995450aa1a9668eba55764733693a536);
    const r = a.add(b);
    try std.testing.expectEqual(e, r);
}

test "add wrap" {
    const a = Fq.from_int(FqParams.modulus_u256 - 1);
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
