const std = @import("std");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const AztecAddress = @import("aztec_address.zig").AztecAddress;
const PublicKeys = @import("public_keys.zig").PublicKeys;
const GrumpkinFr = @import("../grumpkin/fr.zig").Fr;
const GrumpkinFq = @import("../grumpkin/fq.zig").Fq;
const deriveKeys = @import("key_derivation.zig").deriveKeys;
const computeAddress = @import("key_derivation.zig").computeAddress;

const GrumpkinScalar = GrumpkinFr;

pub const CompleteAddress = struct {
    aztec_address: AztecAddress,
    public_keys: PublicKeys,
    partial_address: Bn254Fr,

    pub fn fromSecretKeyAndPartialAddress(secret_key: Bn254Fr, partial_address: Bn254Fr) CompleteAddress {
        const public_keys = deriveKeys(secret_key).public_keys;
        const address = computeAddress(public_keys, partial_address);

        return CompleteAddress{
            .aztec_address = address,
            .public_keys = public_keys,
            .partial_address = partial_address,
        };
    }
};
