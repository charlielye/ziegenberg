const std = @import("std");
const Fq = @import("fq.zig").Fq;
const ProjectivePoint = @import("projective_point.zig").ProjectivePoint;

const G1Params = struct {
    const one_x = Fq.one;
    const one_y = Fq{ .limbs = .{ 0xa6ba871b8b1e1b3a, 0x14f1d651eb8e167b, 0xccdd46def0f28c58, 0x1c14ef83340fbe5e } };
    const a = Fq.zero;
    const b = Fq{ .limbs = .{ 0x7a17caa950ad28d7, 0x1f6ac17ae15521b9, 0x334bea4e696bd284, 0x2a1f6744ce179d8e } };
};

test "add" {
    const a_x = Fq.from_int(0x00f708d16cfe6e14334da8e7539e71c44965cd1c3687f635184b38afc6e2e09a);
    const a_y = Fq.from_int(0x114a1616c164b980bf1645401de26ba1070761d618b513b92a6ff6ffc739b3b6);
    const a_z = Fq.from_int(0x1875e5068ababf2c6bfdc534f6b0000698cf4e1f6c21405310143ade26bbd57a);
    const b_x = Fq.from_int(0x1bd3fb4a59e19b52c6e5ae1f3dad4ec8ac54df622a8d991aafdb8a15c98bf74c);
    const b_y = Fq.from_int(0x187ada6b8693c184cd3526c26ac5bdcbaabd496406ffb8c121b3bb529bec20c0);
    const b_z = Fq.from_int(0x0bdf19ba16fc607ad5279cdbabb05b958a795c8f234145f1ffcd440a228ed652);
    const e_x = Fq.from_int(0x2f09b712adf6f18feb7c437de4bbd748d15388d1fea9f3d318764da36aa4cd81);
    const e_y = Fq.from_int(0x27e91ba0686e54fed9d6125b82ebeff8e50aa3ce802ea3b550c5f3cab191498c);
    const e_z = Fq.from_int(0x0a8ae44990c8accdfd9e178143224c96f608edef14913c750e4b81ef75fedf95);

    const lhs = ProjectivePoint(Fq).from_xyz(a_x, a_y, a_z);
    const rhs = ProjectivePoint(Fq).from_xyz(b_x, b_y, b_z);
    const expected = ProjectivePoint(Fq).from_xyz(e_x, e_y, e_z);

    const result = lhs.add(rhs);

    try std.testing.expect(expected.eql(result));
}

test "dbl" {
    const a_x = Fq.from_int(0x10938940de3cbeecabc11ce30d02728cd19cc40779f54f638d1703aa518d827f);
    const a_y = Fq.from_int(0x06266b85241aff3fcd84adb348c6300736307a354ad90a25cf1798994f1258b4);
    const a_z = Fq.from_int(0x0c43bde08b03aca2f65cf5150a3a9da1b2f42355982c5bc8e213e18fd2df7044);
    const e_x = Fq.from_int(0x2d00482f63b12c864ac597219cf4746789b185ea20951f3ad5c6473044b2e67c);
    const e_y = Fq.from_int(0x062f206bef795a05aa7b9893cc370d39906a877a717351614e7e6c06a87e4314);
    const e_z = Fq.from_int(0x18a299c1f683bdca3fff575136879112929104dffdfabd228813bdca7b0b115a);

    const lhs = ProjectivePoint(Fq).from_xyz(a_x, a_y, a_z);
    const expected = ProjectivePoint(Fq).from_xyz(e_x, e_y, e_z);

    const result = lhs.dbl().dbl().dbl();

    try std.testing.expect(expected.eql(result));
}

test "add infinity exception" {
    // const a =
}
