const std = @import("std");
const aztec_address = @import("./aztec_address.zig");
const complete_address = @import("./complete_address.zig");
const constants = @import("./constants.gen.zig");
const contract_class = @import("./contract_class.zig");
const contract_instance = @import("./contract_instance.zig");
const key_derivation = @import("./key_derivation.zig");
const partial_address = @import("./partial_address.zig");
const public_keys = @import("./public_keys.zig");

// Export types that are used externally
pub const AztecAddress = aztec_address.AztecAddress;
pub const ContractInstance = contract_instance.ContractInstance;
pub const PublicKeys = public_keys.PublicKeys;
pub const CompleteAddress = complete_address.CompleteAddress;
pub const PartialAddress = partial_address.PartialAddress;
pub const deriveKeys = key_derivation.deriveKeys;

test {
    std.testing.refAllDecls(@This());
    _ = aztec_address;
    _ = complete_address;
    _ = constants;
    _ = contract_class;
    _ = contract_instance;
    _ = key_derivation;
    _ = partial_address;
    _ = public_keys;
}