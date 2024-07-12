const std = @import("std");
const field_arith = @import("field_arith.zig");
const get_msb = @import("get_msb.zig").get_msb;

// Generic field element.
// The montgomery form is not exposed externally, unless you read the limbs directly.
pub fn Field(comptime Params: type) type {
    return struct {
        // TODO have params here and make generic field.
        pub const modulus = Params.modulus;
        pub const twice_modulus = Params.twice_modulus;
        pub const one = Field(Params).from_int(1);
        pub const zero = Field(Params).from_int(0);
        limbs: [4]u64,

        pub fn from_limbs(limbs: [4]u64) Field(Params) {
            return Field(Params){ .limbs = field_arith.to_montgomery_form(Params, limbs) };
        }

        // pub fn from_montgomery_limbs(limbs: [4]u64) Field(Params) {
        //     return Field(Params){ .limbs = limbs };
        // }

        pub fn to_limbs(self: Field(Params)) [4]u64 {
            return field_arith.from_montgomery_form(Params, self.limbs);
        }

        pub fn from_int(v: u256) Field(Params) {
            return Field(Params).from_limbs(field_arith.to_limbs(v));
        }

        pub fn to_int(self: Field(Params)) u256 {
            const a = self.to_limbs();
            return @as(u256, a[0]) + (@as(u256, a[1]) << 64) + (@as(u256, a[2]) << 128) + (@as(u256, a[3]) << 192);
        }

        pub fn random() Field(Params) {
            const data = std.crypto.random.int(u512);
            return Field(Params).from_int(@truncate(data));
        }

        pub fn add(self: Field(Params), other: Field(Params)) Field(Params) {
            return Field(Params){ .limbs = field_arith.add(Params, self.limbs, other.limbs) };
        }

        pub fn sub(self: Field(Params), other: Field(Params)) Field(Params) {
            return Field(Params){ .limbs = field_arith.sub_coarse(Params, self.limbs, other.limbs) };
        }

        pub fn mul(self: Field(Params), other: Field(Params)) Field(Params) {
            return Field(Params){ .limbs = field_arith.montgomery_mul(Params, self.limbs, other.limbs) };
        }

        pub fn sqr(self: Field(Params)) Field(Params) {
            return Field(Params){ .limbs = field_arith.montgomery_square(Params, self.limbs) };
        }

        pub fn neg(self: Field(Params)) Field(Params) {
            const p = Field(Params){ .limbs = .{ Field(Params).twice_modulus[0], Field(Params).twice_modulus[1], Field(Params).twice_modulus[2], Field(Params).twice_modulus[3] } };
            return p.sub(self).reduce();
        }

        fn get_bit(self: Field(Params), bit_index: u64) bool {
            std.debug.assert(bit_index < 256);
            const idx = bit_index >> 6;
            const shift: u6 = @truncate(bit_index & 63);
            return (self.limbs[idx] >> shift) & 1 == 1;
        }

        pub fn pow(self: Field(Params), exponent: u256) Field(Params) {
            if (exponent == 0) {
                return Field(Params).one;
            } else if (self.is_zero()) {
                return self;
            }

            var accumulator = self;
            const to_mul = self;
            const maximum_set_bit = 255 - @clz(exponent);
            // field_arith.debugPrintArray(exponent.limbs);
            // std.debug.print("{}\n", .{exponent});
            // std.debug.print("{}\n", .{maximum_set_bit});

            for (0..maximum_set_bit) |i| {
                accumulator = sqr(accumulator);
                if ((exponent >> @truncate(i)) & 1 == 1) {
                    accumulator = accumulator.mul(to_mul);
                }
            }

            return accumulator;
        }

        pub fn eql(self: Field(Params), other: Field(Params)) bool {
            const a = field_arith.reduce(Params, self.limbs);
            const b = field_arith.reduce(Params, other.limbs);
            return std.mem.eql(u64, &a, &b);
        }

        pub fn is_zero(self: Field(Params)) bool {
            return self.eql(Field(Params).zero);
        }

        fn print(self: Field(Params)) void {
            std.debug.print("0x{x:0>64}\n", .{self.to_int()});
        }
    };
}
