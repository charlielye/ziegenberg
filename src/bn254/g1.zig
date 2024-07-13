const std = @import("std");
const Fq = @import("fq.zig").Fq;
const Fr = @import("fr.zig").Fr;
const ProjectivePoint = @import("projective_point.zig").ProjectivePoint;

const G1Params = struct {
    pub const one_x = Fq.one;
    pub const one_y = Fq{ .limbs = .{ 0xa6ba871b8b1e1b3a, 0x14f1d651eb8e167b, 0xccdd46def0f28c58, 0x1c14ef83340fbe5e } };
    // pub const a = Fq.zero;
    pub const b = Fq{ .limbs = .{ 0x7a17caa950ad28d7, 0x1f6ac17ae15521b9, 0x334bea4e696bd284, 0x2a1f6744ce179d8e } };
};

const G1Element = ProjectivePoint(Fq, G1Params);

test "random" {
    const a = G1Element.random();
    try std.testing.expect(a.on_curve());
}

test "infinty" {
    try std.testing.expect(G1Element.infinity.is_infinity());
}

test "eql" {
    const a = G1Element.random();
    const b = a.normalize();

    try std.testing.expect(a.eql(b));
    try std.testing.expect(a.eql(a));
    try std.testing.expect(!a.eql(G1Element.infinity));
    try std.testing.expect(!G1Element.infinity.eql(a));

    const c = G1Element.random();
    try std.testing.expect(!a.eql(c));
}

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

    const lhs = G1Element.from_xyz(a_x, a_y, a_z);
    const rhs = G1Element.from_xyz(b_x, b_y, b_z);
    const expected = G1Element.from_xyz(e_x, e_y, e_z);

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

    const lhs = G1Element.from_xyz(a_x, a_y, a_z);
    const expected = G1Element.from_xyz(e_x, e_y, e_z);

    const result = lhs.dbl().dbl().dbl();

    try std.testing.expect(expected.eql(result));
}

test "add dbl exception" {
    const a = G1Element.random();
    const dbl_result = a.dbl();
    const add_result = a.add(a);
    try std.testing.expect(dbl_result.eql(add_result));
}

test "add infinity exception" {
    const lhs = G1Element.random();
    const rhs = lhs.neg();
    const result = lhs.add(rhs);
    try std.testing.expectEqual(G1Element.infinity, result);

    const result2 = lhs.add(G1Element.infinity);
    try std.testing.expectEqual(lhs, result2);

    const result3 = G1Element.infinity.add(lhs);
    try std.testing.expectEqual(lhs, result3);
}

test "add dbl consistency" {
    const a = G1Element.random();
    const b = G1Element.random();
    const c = a.add(b);
    const d = a.add(b.neg());
    const add_result = c.add(d);
    const dbl_result = a.dbl();
    try std.testing.expect(dbl_result.eql(add_result));
}

test "add dbl consistency repeated" {
    const a = G1Element.random();
    const b = a.dbl(); // b = 2a
    const c = b.dbl(); // c = 4a

    const d = a.add(b); // d = 3a
    const e = a.add(c); // e = 5a
    const result = d.add(e); // result = 8a

    const expected = c.dbl(); // expected = 8a

    try std.testing.expect(result.eql(expected));
}

test "group exponentiation" {
    const a = Fr.from_limbs(.{ 0xb67299b792199cf0, 0xc1da7df1e7e12768, 0x692e427911532edf, 0x13dd85e87dc89978 });
    const expected_x = Fq.from_limbs(.{ 0x9bf840faf1b4ba00, 0xe81b7260d068e663, 0x7610c9a658d2c443, 0x278307cd3d0cddb0 });
    const expected_y = Fq.from_limbs(.{ 0xf6ed5fb779ebecb, 0x414ca771acbe183c, 0xe3692cb56dfbdb67, 0x3d3c5ed19b080a3 });
    const expected = G1Element.from_xyz(expected_x, expected_y, Fq.one);

    const result = (G1Element.one.mul(a));

    try std.testing.expect(result.eql(expected));
}

test "group exponentiation zero and one" {
    const result = G1Element.one.mul(Fr.zero);
    try std.testing.expect(result.is_infinity());

    const result2 = G1Element.one.mul(Fr.one);
    try std.testing.expect(result2.eql(G1Element.one));
}

test "group exponentiation consistency" {
    const a = Fr.random();
    const b = Fr.random();
    const c = a.mul(b);

    const input = G1Element.one;
    const result = input.mul(a).mul(b);

    const expected = input.mul(c);

    try std.testing.expect(result.eql(expected));
}
