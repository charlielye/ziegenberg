const std = @import("std");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const Bn254Fq = @import("../bn254/fq.zig").Fq;
const GrumpkinFr = @import("../grumpkin/fr.zig").Fr;
const GrumpkinFq = @import("../grumpkin/fq.zig").Fq;
const G1 = @import("../grumpkin/g1.zig").G1;
const poseidon2 = @import("../poseidon2/poseidon2.zig");
const constants = @import("constants.gen.zig");
const AztecAddress = @import("aztec_address.zig").AztecAddress;
const PublicKeys = @import("public_keys.zig").PublicKeys;
const CompleteAddress = @import("complete_address.zig").CompleteAddress;

// Type aliases for clarity
const Fr = Bn254Fr;
const Fq = GrumpkinFq; // This is actually Bn254Fr
const GrumpkinScalar = GrumpkinFr; // This is actually Bn254Fq

pub const KeyGenerators = enum(u32) {
    n = @intFromEnum(constants.GeneratorIndex.note_nullifier),
    iv = @intFromEnum(constants.GeneratorIndex.ivsk_m),
    ov = @intFromEnum(constants.GeneratorIndex.ovsk_m),
    r = @intFromEnum(constants.GeneratorIndex.tsk_m),
};

pub fn computeAppNullifierSecretKey(master_nullifier_secret_key: GrumpkinScalar, app: AztecAddress) Fr {
    return computeAppSecretKey(master_nullifier_secret_key, app, .n);
}

pub fn computeAppSecretKey(sk_m: GrumpkinScalar, app: AztecAddress, generator: KeyGenerators) Fr {
    // Convert GrumpkinScalar (hi, lo) to Fr values
    const hi = Fr.from_int(sk_m.limbs[1]);
    const lo = Fr.from_int(sk_m.limbs[0]);
    const inputs = [_]Fr{ Fr.from_int(@intFromEnum(generator)), hi, lo, app.value };
    return poseidon2.hash(&inputs);
}

pub fn computeOvskApp(ovsk: GrumpkinScalar, app: AztecAddress) Fq {
    const ovsk_app_fr = computeAppSecretKey(ovsk, app, .ov);
    // Here we are intentionally converting Fr (output of poseidon) to Fq
    var buf: [32]u8 = undefined;
    ovsk_app_fr.to_buf(&buf);
    return GrumpkinScalar.from_buf(buf);
}

fn sha512ToGrumpkinScalar(inputs: []const u8) GrumpkinScalar {
    var hash_output: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(inputs, &hash_output, .{});
    return GrumpkinScalar.from_int(@as(u512, @bitCast(hash_output)));
}

fn deriveKey(secret_key: Fr, generator: constants.GeneratorIndex) GrumpkinScalar {
    var input_buf: [36]u8 = undefined;
    secret_key.into_slice(input_buf[0..32]);
    std.mem.writeInt(u32, input_buf[32..36], @intFromEnum(generator), .big);
    return sha512ToGrumpkinScalar(&input_buf);
}

pub fn deriveMasterNullifierSecretKey(secret_key: Fr) GrumpkinScalar {
    return deriveKey(secret_key, constants.GeneratorIndex.nsk_m);
}

pub fn deriveMasterIncomingViewingSecretKey(secret_key: Fr) GrumpkinScalar {
    return deriveKey(secret_key, constants.GeneratorIndex.ivsk_m);
}

pub fn deriveMasterOutgoingViewingSecretKey(secret_key: Fr) GrumpkinScalar {
    return deriveKey(secret_key, constants.GeneratorIndex.ovsk_m);
}

pub fn deriveSigningKey(secret_key: Fr) GrumpkinScalar {
    // TODO(#5837): come up with a standard signing key derivation scheme instead of using ivsk_m as signing keys here
    return deriveKey(secret_key, constants.GeneratorIndex.ivsk_m);
}

pub fn computePreaddress(public_keys_hash: Fr, partial_address: Fr) Fr {
    const inputs = [_]Fr{
        Fr.from_int(@intFromEnum(constants.GeneratorIndex.contract_address_v1)),
        public_keys_hash,
        partial_address,
    };
    return poseidon2.hash(&inputs);
}

pub fn computeAddress(public_keys: PublicKeys, partial_address: Fr) AztecAddress {
    // Given public keys and a partial address, we can compute our address in the following steps.
    // 1. preaddress = poseidon2([publicKeysHash, partialAddress], GeneratorIndex.CONTRACT_ADDRESS_V1);
    // 2. addressPoint = (preaddress * G) + ivpk_m
    // 3. address = addressPoint.x
    const preaddress = computePreaddress(public_keys.hash(), partial_address);
    const preaddress_point = derivePublicKeyFromSecretKey(GrumpkinScalar.from_int(preaddress.to_int()));
    const address_point = preaddress_point.add(public_keys.master_incoming_viewing_public_key);
    const normalized = address_point.normalize();
    return AztecAddress.init(normalized.x);
}

pub fn computeAddressSecret(preaddress: Fr, ivsk: Fq) Fq {
    // TLDR; P1 = (h + ivsk) * G
    // if P1.y is pos
    //   S = (h + ivsk)
    // else
    //   S = Fq.MODULUS - (h + ivsk)
    const address_secret_candidate = ivsk.add(Fq.from_int(preaddress.to_int()));
    const address_point_candidate = derivePublicKeyFromSecretKey(address_secret_candidate);

    // Check if y-coordinate is positive (less than half the field modulus)
    const normalized = address_point_candidate.normalize();
    const half_modulus = Fr.modulus() / 2;
    if (normalized.y.to_int() > half_modulus) {
        // Negate the secret
        return Fq.from_int(Fq.modulus() - address_secret_candidate.to_int());
    }

    return address_secret_candidate;
}

pub fn derivePublicKeyFromSecretKey(secret_key: GrumpkinScalar) G1.Element {
    return G1.Element.one.mul(secret_key);
}

pub const DerivedKeys = struct {
    master_nullifier_secret_key: GrumpkinScalar,
    master_incoming_viewing_secret_key: GrumpkinScalar,
    master_outgoing_viewing_secret_key: GrumpkinScalar,
    master_tagging_secret_key: GrumpkinScalar,
    public_keys: PublicKeys,
};

pub fn deriveKeys(secret_key: Fr) DerivedKeys {
    // First we derive master secret keys.
    // We use sha512 here because this derivation will never take place in a circuit.
    const master_nullifier_secret_key = deriveMasterNullifierSecretKey(secret_key);
    const master_incoming_viewing_secret_key = deriveMasterIncomingViewingSecretKey(secret_key);
    const master_outgoing_viewing_secret_key = deriveMasterOutgoingViewingSecretKey(secret_key);

    // For tagging secret key.
    const master_tagging_secret_key = deriveKey(secret_key, constants.GeneratorIndex.tsk_m);

    // Then we derive master public keys.
    const master_nullifier_public_key = derivePublicKeyFromSecretKey(master_nullifier_secret_key);
    const master_incoming_viewing_public_key = derivePublicKeyFromSecretKey(master_incoming_viewing_secret_key);
    const master_outgoing_viewing_public_key = derivePublicKeyFromSecretKey(master_outgoing_viewing_secret_key);
    const master_tagging_public_key = derivePublicKeyFromSecretKey(master_tagging_secret_key);

    const public_keys = PublicKeys{
        .master_nullifier_public_key = master_nullifier_public_key,
        .master_incoming_viewing_public_key = master_incoming_viewing_public_key,
        .master_outgoing_viewing_public_key = master_outgoing_viewing_public_key,
        .master_tagging_public_key = master_tagging_public_key,
    };

    return DerivedKeys{
        .master_nullifier_secret_key = master_nullifier_secret_key,
        .master_incoming_viewing_secret_key = master_incoming_viewing_secret_key,
        .master_outgoing_viewing_secret_key = master_outgoing_viewing_secret_key,
        .master_tagging_secret_key = master_tagging_secret_key,
        .public_keys = public_keys,
    };
}

// Returns shared tagging secret computed with Diffie-Hellman key exchange.
fn computeTaggingSecretPoint(known_address: CompleteAddress, ivsk: Fq, external_address: AztecAddress) G1.Element {
    const known_preaddress = computePreaddress(known_address.public_keys.hash(), known_address.partial_address);
    // TODO: #8970 - Computation of address point from x coordinate might fail
    const external_address_point = external_address.toAddressPoint();
    // Given A (known complete address) -> B (external address) and h == preaddress
    // Compute shared secret as S = (h_A + ivsk_A) * Addr_Point_B
    const address_secret = computeAddressSecret(known_preaddress, ivsk);
    return external_address_point.mul(address_secret);
}

pub fn computeAppTaggingSecret(
    known_address: CompleteAddress,
    ivsk: Fq,
    external_address: AztecAddress,
    app: AztecAddress,
) Fr {
    const tagging_secret_point = computeTaggingSecretPoint(known_address, ivsk, external_address);
    const normalized = tagging_secret_point.normalize();
    const inputs = [_]Fr{ normalized.x, normalized.y, app.value };
    return poseidon2.hash(&inputs);
}
