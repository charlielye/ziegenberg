const std = @import("std");
const field_arith = @import("field_arith.zig");
const get_msb = @import("../bitop/get_msb.zig").get_msb;

// Generic field element.
// The montgomery form is not exposed externally, unless you read the limbs directly.
pub fn Field(comptime Params: type) type {
    return struct {
        const Fe = Field(Params);
        pub const params = Params;
        pub const one = Fe.from_int(1);
        pub const zero = Fe.from_int(0);
        limbs: [4]u64,

        pub fn from_limbs(limbs: [4]u64) Fe {
            return Fe{ .limbs = field_arith.to_montgomery_form(Params, limbs) };
        }

        pub fn to_limbs(self: Fe) [4]u64 {
            return field_arith.from_montgomery_form(Params, self.limbs);
        }

        pub fn from_int(v: u256) Fe {
            return Fe.from_limbs(field_arith.to_limbs(v));
        }

        pub fn to_int(self: Fe) u256 {
            const a = self.to_limbs();
            return @as(u256, a[0]) + (@as(u256, a[1]) << 64) + (@as(u256, a[2]) << 128) + (@as(u256, a[3]) << 192);
        }

        pub fn random() Fe {
            const data = std.crypto.random.int(u512);
            return Fe.from_int(@truncate(data));
        }

        pub fn add(self: Fe, other: Fe) Fe {
            return Fe{ .limbs = field_arith.add(Params, self.limbs, other.limbs) };
        }

        pub fn sub(self: Fe, other: Fe) Fe {
            return Fe{ .limbs = field_arith.sub_coarse(Params, self.limbs, other.limbs) };
        }

        pub fn mul(self: Fe, other: Fe) Fe {
            return Fe{ .limbs = field_arith.montgomery_mul(Params, self.limbs, other.limbs) };
        }

        pub fn sqr(self: Fe) Fe {
            return Fe{ .limbs = field_arith.montgomery_square(Params, self.limbs) };
        }

        pub fn neg(self: Fe) Fe {
            const p = Fe{ .limbs = .{
                Params.twice_modulus[0],
                Params.twice_modulus[1],
                Params.twice_modulus[2],
                Params.twice_modulus[3],
            } };
            return p.sub(self).reduce();
        }

        pub fn invert(self: Fe) Fe {
            if (self.is_zero()) {
                unreachable;
            }
            return self.pow(Params.modulus_minus_two_u256);
        }

        pub fn reduce(self: Fe) Fe {
            return Fe{ .limbs = field_arith.reduce(Params, self.limbs) };
        }

        fn get_bit(self: Fe, bit_index: u64) bool {
            std.debug.assert(bit_index < 256);
            const idx = bit_index >> 6;
            const shift: u6 = @truncate(bit_index & 63);
            return (self.limbs[idx] >> shift) & 1 == 1;
        }

        pub fn pow(self: Fe, exponent: u256) Fe {
            if (exponent == 0) {
                return Fe.one;
            } else if (self.is_zero()) {
                return self;
            }

            var accumulator = self;
            const to_mul = self;
            const maximum_set_bit = 255 - @clz(exponent);
            // field_arith.debugPrintArray(exponent.limbs);
            // std.debug.print("exponent {x}\n", .{exponent});
            // std.debug.print("msb {}\n", .{maximum_set_bit});

            for (0..maximum_set_bit) |j| {
                const i = maximum_set_bit - j - 1;
                accumulator = sqr(accumulator);
                if ((exponent >> @truncate(i)) & 1 == 1) {
                    accumulator = accumulator.mul(to_mul);
                }
            }

            return accumulator;
        }

        pub fn eql(self: Fe, other: Fe) bool {
            const a = field_arith.reduce(Params, self.limbs);
            const b = field_arith.reduce(Params, other.limbs);
            return std.mem.eql(u64, &a, &b);
        }

        pub fn is_zero(self: Fe) bool {
            return self.eql(Fe.zero);
        }

        pub fn format(
            self: Fe,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("0x{x:0>64}", .{self.to_int()});
        }

        pub fn print(self: Fe) void {
            std.debug.print("0x{x:0>64}\n", .{self.to_int()});
        }
    };
}