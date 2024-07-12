const std = @import("std");
// const Fq = @import("fq.zig").Fq;
const ProjectivePoint = @import("projective_point.zig").ProjectivePoint;

pub fn add(comptime Fq: type, a: ProjectivePoint(Fq), b: ProjectivePoint(Fq)) ProjectivePoint(Fq) {
    const p1_zero = a.is_infinity();
    const p2_zero = b.is_infinity();

    if (p1_zero or p2_zero) {
        return if (p1_zero and !p2_zero) b else a;
    }

    var Z1Z1 = a.z.sqr();
    // std.debug.print("Z1Z1: {x:0>64}\n", .{Z1Z1.to_int()});
    const Z2Z2 = b.z.sqr();
    // std.debug.print("Z2Z2: {x:0>64}\n", .{Z2Z2.to_int()});
    var S2 = Z1Z1.mul(a.z);
    // std.debug.print("S2: {x:0>64}\n", .{S2.to_int()});
    var U2 = Z1Z1.mul(b.x);
    // std.debug.print("U2: {x:0>64}\n", .{U2.to_int()});
    S2 = S2.mul(b.y);
    // std.debug.print("S2: {x:0>64}\n", .{S2.to_int()});
    var U1 = Z2Z2.mul(a.x);
    // std.debug.print("U1: {x:0>64}\n", .{U1.to_int()});
    var S1 = Z2Z2.mul(b.z);
    // std.debug.print("S1: {x:0>64}\n", .{S1.to_int()});
    // std.debug.print("y: {x:0>64}\n", .{a.y.to_int()});
    S1 = S1.mul(a.y);
    // std.debug.print("S1: {x:0>64}\n", .{S1.to_int()});

    var F = S2.sub(S1);
    const H = U2.sub(U1);

    if (H.is_zero()) {
        if (F.is_zero()) {
            return dbl(Fq, a);
        }
        // modulus represents point at infinity.
        return ProjectivePoint(Fq).infinity;
    }

    F = F.add(F);

    var I = H.add(H);
    I = I.sqr();

    var J = H.mul(I);

    U1 = U1.mul(I);

    U2 = U1.add(U1);
    U2 = U2.add(J);

    var x = F.sqr();
    x = x.sub(U2);

    J = J.mul(S1);
    J = J.add(J);

    var y = U1.sub(x);
    y = y.mul(F);
    y = y.sub(J);

    var z = a.z.add(b.z);

    Z1Z1 = Z1Z1.add(Z2Z2);

    z = z.sqr();
    z = z.sub(Z1Z1);
    z = z.mul(H);

    return ProjectivePoint(Fq){ .x = x, .y = y, .z = z };
}

pub fn dbl(comptime Fq: type, a: ProjectivePoint(Fq)) ProjectivePoint(Fq) {
    if (a.is_infinity()) {
        return a;
    }

    // T0 = x*x
    var T0 = a.x.sqr();

    // T1 = y*y
    var T1 = a.y.sqr();

    // T2 = T2*T1 = y*y*y*y
    var T2 = T1.sqr();

    // T1 = T1 + x = x + y*y
    T1 = T1.add(a.x);

    // T1 = T1 * T1
    T1 = T1.sqr();

    // T3 = T0 + T2 = xx + y*y*y*y
    var T3 = T0.add(T2);

    // T1 = T1 - T3 = x*x + y*y*y*y + 2*x*x*y*y*y*y - x*x - y*y*y*y = 2*x*x*y*y*y*y = 2*S
    T1 = T1.sub(T3);

    // T1 = 2T1 = 4*S
    T1 = T1.add(T1);

    // T3 = 3T0
    T3 = T0.add(T0);
    T3 = T3.add(T0);
    // if constexpr (T::has_a) {
    //     T3 += (T::a * z.sqr().sqr());
    // }

    // std.debug.print("T0 {x:0>16}\n", .{T0.to_int()});
    // std.debug.print("T1 {x:0>16}\n", .{T1.to_int()});
    // std.debug.print("T2 {x:0>16}\n", .{T2.to_int()});
    // std.debug.print("T3 {x:0>16}\n", .{T3.to_int()});

    // z2 = 2*y*z
    var z = a.z.add(a.z);
    z = z.mul(a.y);

    // T0 = 2T1
    T0 = T1.add(T1);

    // x2 = T3*T3
    var x = T3.sqr();
    // x2 = x2 - 2T1
    x = x.sub(T0);

    // T2 = 8T2
    T2 = T2.add(T2);
    T2 = T2.add(T2);
    T2 = T2.add(T2);

    // y2 = T1 - x2
    var y = T1.sub(x);
    // y2 = y2 * T3 - T2
    y = y.mul(T3);
    y = y.sub(T2);

    return ProjectivePoint(Fq).from_xyz(x, y, z);
}
