const std = @import("std");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const AztecAddress = @import("../aztec_address.zig").AztecAddress;
const PublicKeys = @import("public_keys.zig").PublicKeys;

// Type alias for clarity
const Fr = Bn254Fr;

pub const CompleteAddress = struct {
    aztec_address: AztecAddress,
    public_keys: PublicKeys,
    partial_address: Fr,
};