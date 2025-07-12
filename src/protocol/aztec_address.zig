const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const GrumpkinFr = @import("../grumpkin/fr.zig").Fr;
const G1 = @import("../grumpkin/g1.zig").G1;
const ForeignCallParam = @import("../bvm/foreign_call/param.zig").ForeignCallParam;
const PublicKeys = @import("public_keys.zig").PublicKeys;
const PartialAddress = @import("partial_address.zig").PartialAddress;
const keys = @import("key_derivation.zig");
const constants = @import("constants.gen.zig");
const poseidon2 = @import("../poseidon2/poseidon2.zig");

pub const AztecAddress = struct {
    value: Fr,

    pub const zero = AztecAddress.init(Fr.zero);

    pub fn init(value: Fr) AztecAddress {
        return .{ .value = value };
    }

    pub fn random() AztecAddress {
        return .{ .value = Fr.random() };
    }

    pub fn compute(public_keys: PublicKeys, partial_address: PartialAddress) AztecAddress {
        const preaddress = AztecAddress.computePreaddress(public_keys.hash(), partial_address);
        const preaddress_point = keys.derivePublicKeyFromSecretKey(GrumpkinFr.from_int(preaddress.to_int()));
        const address_point = preaddress_point.add(public_keys.master_incoming_viewing_public_key);
        const normalized = address_point.normalize();
        return AztecAddress.init(normalized.x);
    }

    pub fn computeFromClassId(
        contract_class_id: Fr,
        salted_initialization_hash: Fr,
        public_keys: PublicKeys,
    ) AztecAddress {
        const partial_address = PartialAddress.computeFromSaltedInitializationHash(
            contract_class_id,
            salted_initialization_hash,
        );

        return AztecAddress.compute(public_keys, partial_address);
    }

    fn computePreaddress(public_keys_hash: Fr, partial_address: PartialAddress) Fr {
        const inputs = [_]Fr{
            Fr.from_int(@intFromEnum(constants.GeneratorIndex.contract_address_v1)),
            public_keys_hash,
            partial_address.value,
        };
        return poseidon2.hash(&inputs);
    }

    // pub fn toAddressPoint(self: AztecAddress) G1.Element {
    //     _ = self;
    //     // TODO: #8970 - Computation of address point from x coordinate might fail
    //     // For now, this is a placeholder that needs proper implementation
    //     return G1.Element.infinity;
    // }

    pub fn fromForeignCallParam(param: ForeignCallParam) !AztecAddress {
        if (param != .Single) return error.InvalidParam;
        return AztecAddress.init(Fr.from_int(param.Single));
    }

    pub fn toForeignCallParam(self: AztecAddress) ForeignCallParam {
        return ForeignCallParam{ .Single = self.value.to_int() };
    }

    pub fn format(
        self: AztecAddress,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        return self.value.format(fmt, options, writer);
    }

    pub fn eql(self: AztecAddress, other: AztecAddress) bool {
        return self.value.eql(other.value);
    }

    pub fn hash(self: AztecAddress) u64 {
        return self.value.hash();
    }

    pub fn toField(self: AztecAddress) Fr {
        return self.value;
    }
};

test "compute address from partial and public keys" {
    const public_keys = PublicKeys{
        .master_nullifier_public_key = G1.Element.from_xy(
            Fr.from_int(0x22f7fcddfa3ce3e8f0cc8e82d7b94cdd740afa3e77f8e4a63ea78a239432dcab),
            Fr.from_int(0x0471657de2b6216ade6c506d28fbc22ba8b8ed95c871ad9f3e3984e90d9723a7),
        ),
        .master_incoming_viewing_public_key = G1.Element.from_xy(
            Fr.from_int(0x111223493147f6785514b1c195bb37a2589f22a6596d30bb2bb145fdc9ca8f1e),
            Fr.from_int(0x273bbffd678edce8fe30e0deafc4f66d58357c06fd4a820285294b9746c3be95),
        ),
        .master_outgoing_viewing_public_key = G1.Element.from_xy(
            Fr.from_int(0x09115c96e962322ffed6522f57194627136b8d03ac7469109707f5e44190c484),
            Fr.from_int(0x0c49773308a13d740a7f0d4f0e6163b02c5a408b6f965856b6a491002d073d5b),
        ),
        .master_tagging_public_key = G1.Element.from_xy(
            Fr.from_int(0x00d3d81beb009873eb7116327cf47c612d5758ef083d4fda78e9b63980b2a762),
            Fr.from_int(0x2f567d22d2b02fe1f4ad42db9d58a36afd1983e7e2909d1cab61cafedad6193a),
        ),
    };

    // Construct partial address from field
    const partial_address = PartialAddress.init(Fr.from_int(
        0x0a7c585381b10f4666044266a02405bf6e01fa564c8517d4ad5823493abd31de,
    ));

    // Compute address
    const address = AztecAddress.compute(public_keys, partial_address);

    // Expected value from derivation.test.ts
    const expected: u256 = 0x24e4646f58b9fbe7d38e317db8d5636c423fbbdfbe119fc190fe9c64747e0c62;

    try std.testing.expect(address.value.to_int() == expected);
}
