const std = @import("std");
const Fr = @import("fr.zig").Fr;
const Fq = @import("fq.zig").Fq;
const ProjectivePoint = @import("../group/package.zig").ProjectivePoint;

const G1Params = struct {
    pub const fq = Fq;
    pub const fr = Fr;
    pub const one_x = Fq.one;
    pub const one_y = Fq{ .limbs = .{ 0x11b2dff1448c41d8, 0x23d3446f21c77dc3, 0xaa7b8cf435dfafbb, 0x14b34cf69dc25d68 } };
    pub const b = Fq{ .limbs = .{ 0xdd7056026000005a, 0x223fa97acb319311, 0xcc388229877910c0, 0x34394632b724eaa } };
};

const G1Element = ProjectivePoint(G1Params);

test "group exponentiation consistency" {
    const a = Fr.random();
    const b = Fr.random();
    const c = a.mul(b);

    const input = G1Element.one;
    const result = input.mul(a).mul(b);

    const expected = input.mul(c);

    try std.testing.expect(result.eql(expected));
}
