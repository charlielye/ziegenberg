const std = @import("std");
const Field = @import("../field/field.zig").Field;
const FieldParams = @import("../field/field_params.zig").FieldParams;

const FrParams = struct {
    pub const modulus: u256 = 0x30644E72E131A029B85045B68181585D2833E84879B9709143E1F593F0000001;
    pub const r_squared = 0x0216D0B17F4E44A58C49833D53BB808553FE3AB1E35C59E31BB8E645AE216DA7;
    pub const r_inv = 0xc2e1f593efffffff;
};

pub const FrFieldParams = FieldParams(FrParams);
pub const Fr = Field(FrFieldParams);

test "add wrap" {
    const a = Fr.from_int(FrParams.modulus - 1);
    const r = a.add(Fr.one);
    try std.testing.expectEqual(0, r.to_int());
}
