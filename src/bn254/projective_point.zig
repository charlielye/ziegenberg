const std = @import("std");
const Fr = @import("fr.zig").Fr;
const group_arith = @import("group_arith.zig");

pub fn ProjectivePoint(comptime Fq: type, comptime GroupParams: type) type {
    return struct {
        const PP = ProjectivePoint(Fq, GroupParams);

        // Point at infinity is encoded as { x = fq_modulus, y = 0, z = 0 }
        pub const infinity = PP.from_xyz(Fq{ .limbs = Fq.params.modulus }, Fq.zero, Fq.zero);
        pub const one = PP.from_xyz(GroupParams.one_x, GroupParams.one_y, Fq.one);
        x: Fq,
        y: Fq,
        z: Fq,

        pub fn from_xyz(x: Fq, y: Fq, z: Fq) PP {
            return PP{ .x = x, .y = y, .z = z };
        }

        pub fn random() PP {
            const scalar = Fr.random();
            return PP.from_xyz(GroupParams.one_x, GroupParams.one_y, Fq.one).mul(scalar);
        }

        pub fn is_infinity(self: PP) bool {
            return self.x.eql(infinity.x);
        }

        pub fn add(self: PP, other: PP) PP {
            return group_arith.add(PP, self, other);
        }

        pub fn dbl(self: PP) PP {
            return group_arith.dbl(PP, self);
        }

        // Slow. Need version with endomorphism.
        pub fn mul(self: PP, scalar: Fr) PP {
            if (scalar.is_zero()) {
                return PP.infinity;
            }
            const scalar_u256 = scalar.to_int();
            var accumulator = self;
            const maximum_set_bit = 255 - @clz(scalar_u256);

            for (0..maximum_set_bit) |j| {
                const i = maximum_set_bit - j - 1;
                accumulator = accumulator.dbl();
                if ((scalar_u256 >> @truncate(i)) & 1 == 1) {
                    accumulator = accumulator.add(self);
                }
            }

            return accumulator;
        }

        pub fn eql(self: PP, other: PP) bool {
            // return self.x.eql(other.x) and self.y.eql(other.y) and self.z.eql(other.z);
            // If one of points is not on curve, we have no business comparing them.
            if ((!self.on_curve()) or (!other.on_curve())) {
                return false;
            }
            const self_infinity = self.is_infinity();
            const other_infinity = other.is_infinity();
            const both_infinity = self_infinity and other_infinity;
            // If just one is infinity, then they are obviously not equal.
            if ((!both_infinity) and (self_infinity or other_infinity)) {
                return false;
            }
            const lhs_zz = self.z.sqr();
            const lhs_zzz = lhs_zz.mul(self.z);
            const rhs_zz = other.z.sqr();
            const rhs_zzz = rhs_zz.mul(other.z);

            const lhs_x = self.x.mul(rhs_zz);
            const lhs_y = self.y.mul(rhs_zzz);

            const rhs_x = other.x.mul(lhs_zz);
            const rhs_y = other.y.mul(lhs_zzz);

            return both_infinity or ((lhs_x.eql(rhs_x)) and (lhs_y.eql(rhs_y)));
        }

        pub fn neg(self: PP) PP {
            return PP{ .x = self.x, .y = self.y.neg(), .z = self.z };
        }

        pub fn format(
            self: PP,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("{{\n x: {any}\n y: {any}\n z: {any}\n}}", .{ self.x, self.y, self.z });
        }

        pub fn print(self: PP) !void {
            const str = try std.fmt.allocPrint(
                std.testing.allocator,
                "{s}",
                .{self},
            );
            defer std.testing.allocator.free(str);
            std.debug.print("{s}\n", .{str});
        }

        pub fn on_curve(self: PP) bool {
            if (self.is_infinity()) {
                return true;
            }
            // We specify the point at inifinity not by (0 \lambda 0), so z should not be 0
            if (self.z.is_zero()) {
                return false;
            }
            const zz = self.z.sqr();
            const zzzz = zz.sqr();
            const bz_6 = zzzz.mul(zz).mul(GroupParams.b);
            // if constexpr (T::has_a) {
            //     bz_6 += (x * T::a) * zzzz;
            // }
            const xxx = self.x.sqr().mul(self.x).add(bz_6);
            const yy = self.y.sqr();
            return xxx.eql(yy);
        }

        pub fn normalize(self: PP) PP {
            if (self.is_infinity()) {
                return self;
            }
            const z_inv = self.z.invert();
            const zz_inv = z_inv.sqr();
            const zzz_inv = zz_inv.mul(z_inv);
            return PP.from_xyz(self.x.mul(zz_inv), self.y.mul(zzz_inv), Fq.one);
        }
    };
}
