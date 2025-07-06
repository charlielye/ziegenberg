const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const AztecAddress = @import("aztec_address.zig").AztecAddress;
const PublicKeys = @import("public_keys.zig").PublicKeys;
const poseidon2 = @import("../poseidon2/poseidon2.zig");
const constants = @import("constants.gen.zig");
const key_derivation = @import("key_derivation.zig");
const nargo = @import("../nargo/package.zig");

pub const CONTRACT_CLASS_VERSION: u8 = 1;

/// Aztec differentiates contracts classes and instances.
/// A contract class represents the code of the contract, but holds no state.
/// Classes are identified by an id that is a commitment to all its data.
pub const ContractClass = struct {
    version: u8 = CONTRACT_CLASS_VERSION,
    artifact_hash: Fr,
    private_functions: []nargo.Function,
    public_bytecode: []const u8,
    id: Fr,
    private_functions_root: Fr,
    public_bytecode_commitment: Fr,

    pub fn fromContractAbi(contract: nargo.ContractAbi) ContractClass {
        const id = poseidon2.hash(&[_]Fr{
            Fr.from_int(constants.GeneratorIndex.contract_leaf),
            contract.artifact_hash,
            contract.private_function_tree_root,
            contract.public_bytecode_commitment,
        });
        return .{
            .artifact_hash = contract.artifact_hash,
            .private_functions = contract.private_functions,
            .public_bytecode = contract.public_function.bytecode,
            .private_functions_root = contract.private_function_tree_root,
            .public_bytecode_commitment = contract.public_bytecode_commitment,
            .id = id,
        };
    }
};
