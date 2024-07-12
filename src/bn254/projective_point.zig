// const std = @import("std");
// const Fq = @import("fq.zig").Fq;
const group_arith = @import("group_arith.zig");

pub fn ProjectivePoint(comptime Fq: type) type {
    return struct {
        // Can we just make this all 0xFF?
        pub const infinity = ProjectivePoint(Fq){ .x = Fq{ .limbs = Fq.modulus }, .y = Fq.zero, .z = Fq.zero };
        pub const one = ProjectivePoint(Fq){ .x = Fq.one_x, .y = Fq.one_y, .z = Fq.one };
        x: Fq,
        y: Fq,
        z: Fq,

        pub fn from_xyz(x: Fq, y: Fq, z: Fq) ProjectivePoint(Fq) {
            return ProjectivePoint(Fq){ .x = x, .y = y, .z = z };
        }

        pub fn random() ProjectivePoint(Fq) {
            // Fr scalar = Fr::random_element(engine);
            // return (element{ T::one_x, T::one_y, Fq::one() } * scalar);
        }

        pub fn is_infinity(self: ProjectivePoint(Fq)) bool {
            return self.x.eql(infinity.x);
        }

        pub fn add(self: ProjectivePoint(Fq), other: ProjectivePoint(Fq)) ProjectivePoint(Fq) {
            return group_arith.add(Fq, self, other);
        }

        pub fn dbl(self: ProjectivePoint(Fq)) ProjectivePoint(Fq) {
            return group_arith.dbl(Fq, self);
        }

        pub fn eql(self: ProjectivePoint(Fq), other: ProjectivePoint(Fq)) bool {
            return self.x.eql(other.x) and self.y.eql(other.y) and self.z.eql(other.z);
        }

        pub fn neg(self: ProjectivePoint(Fq)) Fq {
            return ProjectivePoint(Fq){ .x = self.x, .y = self.y.neg(), .z = self.z };
        }
    };
}
