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
        // Hash all public keys together
        const inputs = [_]Fr{
            Fr.from_int(@intFromEnum(constants.GeneratorIndex.public_keys_hash)),
            self.master_nullifier_public_key.x,
            self.master_nullifier_public_key.y,
            self.master_incoming_viewing_public_key.x,
            self.master_incoming_viewing_public_key.y,
            self.master_outgoing_viewing_public_key.x,
            self.master_outgoing_viewing_public_key.y,
            self.master_tagging_public_key.x,
            self.master_tagging_public_key.y,
        };
        return poseidon2.hash(&inputs);
    }
};
