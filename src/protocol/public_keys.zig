const std = @import("std");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const G1 = @import("../grumpkin/g1.zig").G1;
const poseidon2 = @import("../poseidon2/poseidon2.zig");
const constants = @import("constants.gen.zig");

// Type alias for clarity
const Fr = Bn254Fr;

pub const PublicKeys = struct {
    master_nullifier_public_key: G1.Element,
    master_incoming_viewing_public_key: G1.Element,
    master_outgoing_viewing_public_key: G1.Element,
    master_tagging_public_key: G1.Element,

    pub fn default() PublicKeys {
        return .{
            .master_nullifier_public_key = G1.Element.from_xy(
                Fr.from_int(constants.DEFAULT_NPK_M_X),
                Fr.from_int(constants.DEFAULT_NPK_M_Y),
            ),
            .master_incoming_viewing_public_key = G1.Element.from_xy(
                Fr.from_int(constants.DEFAULT_IVPK_M_X),
                Fr.from_int(constants.DEFAULT_IVPK_M_Y),
            ),
            .master_outgoing_viewing_public_key = G1.Element.from_xy(
                Fr.from_int(constants.DEFAULT_OVPK_M_X),
                Fr.from_int(constants.DEFAULT_OVPK_M_Y),
            ),
            .master_tagging_public_key = G1.Element.from_xy(
                Fr.from_int(constants.DEFAULT_TPK_M_X),
                Fr.from_int(constants.DEFAULT_TPK_M_Y),
            ),
        };
    }

    pub fn hash(self: PublicKeys) Fr {
        const inputs = .{
            constants.GeneratorIndex.public_keys_hash,
            self.master_nullifier_public_key.x,
            self.master_nullifier_public_key.y,
            self.master_nullifier_public_key.is_infinity(),
            self.master_incoming_viewing_public_key.x,
            self.master_incoming_viewing_public_key.y,
            self.master_incoming_viewing_public_key.is_infinity(),
            self.master_outgoing_viewing_public_key.x,
            self.master_outgoing_viewing_public_key.y,
            self.master_outgoing_viewing_public_key.is_infinity(),
            self.master_tagging_public_key.x,
            self.master_tagging_public_key.y,
            self.master_tagging_public_key.is_infinity(),
        };
        return poseidon2.hashTuple(inputs);
    }
};

test "compute public keys hash" {
    const keys = PublicKeys{
        .master_nullifier_public_key = G1.Element.from_xy(
            Fr.from_int(1),
            Fr.from_int(2),
        ),
        .master_incoming_viewing_public_key = G1.Element.from_xy(
            Fr.from_int(3),
            Fr.from_int(4),
        ),
        .master_outgoing_viewing_public_key = G1.Element.from_xy(
            Fr.from_int(5),
            Fr.from_int(6),
        ),
        .master_tagging_public_key = G1.Element.from_xy(
            Fr.from_int(7),
            Fr.from_int(8),
        ),
    };

    const actual = keys.hash();
    const expected_public_keys_hash = Fr.from_int(0x0fecd9a32db731fec1fded1b9ff957a1625c069245a3613a2538bd527068b0ad);

    std.debug.print("actual: {x}\n", .{actual});
    std.debug.print("expected: {x}\n", .{expected_public_keys_hash});

    try std.testing.expect(actual.eql(expected_public_keys_hash));
}

test "compute default hash" {
    const keys = PublicKeys.default();

    const actual = keys.hash();
    const test_data_default_hash = Fr.from_int(0x1d3bf1fb93ae0e9cda83b203dd91c3bfb492a9aecf30ec90e1057eced0f0e62d);

    std.debug.print("actual default: {x}\n", .{actual});
    std.debug.print("expected default: {x}\n", .{test_data_default_hash});

    try std.testing.expect(actual.eql(test_data_default_hash));
}
