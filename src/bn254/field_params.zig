const field_arith = @import("field_arith.zig");

pub fn FieldParams(comptime Params: type) type {
    return struct {
        const modulus_u256: u256 = Params.modulus;
        const twice_modulus_u256: u256 = modulus_u256 + modulus_u256;
        const not_modulus_u256: u256 = @bitCast(-@as(i256, modulus_u256));
        const twice_not_modulus_u256: u256 = @bitCast(-@as(i256, twice_modulus_u256));

        pub const modulus_minus_two_u256: u256 = Params.modulus - 2;

        pub const modulus = field_arith.to_limbs(modulus_u256);
        pub const twice_modulus = field_arith.to_limbs(twice_modulus_u256);
        pub const not_modulus = field_arith.to_limbs(not_modulus_u256);
        pub const twice_not_modulus = field_arith.to_limbs(twice_not_modulus_u256);

        pub const r_squared = field_arith.to_limbs(Params.r_squared);
        pub const r_inv = Params.r_inv;

        const one = field_arith.to_montgomery_form(.{ 1, 0, 0, 0 });
    };
}
