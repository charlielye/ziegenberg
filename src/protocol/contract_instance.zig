const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const AztecAddress = @import("aztec_address.zig").AztecAddress;
const PublicKeys = @import("public_keys.zig").PublicKeys;
const ContractClass = @import("contract_class.zig").ContractClass;
const poseidon2 = @import("../poseidon2/poseidon2.zig");
const constants = @import("constants.gen.zig");
const key_derivation = @import("key_derivation.zig");
const nargo = @import("../nargo/package.zig");

pub const CONTRACT_INSTANCE_VERSION: u8 = 1;

/// A contract instance is a concrete deployment of a contract class. It always references a contract class,
/// which dictates what code it executes when called. It has state (both private and public), as well as an
/// address that acts as its identifier. It can be called into. It may have encryption and nullifying public keys.
pub const ContractInstance = struct {
    /// Version identifier. Initially one, bumped for any changes to the contract instance struct.
    version: u8,
    /// User-generated pseudorandom value for uniqueness.
    salt: Fr,
    /// Optional deployer address or zero if this was a universal deploy.
    deployer: AztecAddress,
    /// Identifier of the contract class for this instance.
    current_contract_class_id: Fr,
    /// Identifier of the original (at deployment) contract class for this instance.
    original_contract_class_id: Fr,
    /// Hash of the selector and arguments to the constructor.
    initialization_hash: Fr,
    /// Public keys associated with this instance.
    public_keys: PublicKeys,
    /// Optional address.
    address: ?AztecAddress,

    pub fn init(
        salt: Fr,
        deployer: AztecAddress,
        contract_class_id: Fr,
        initialization_hash: Fr,
        public_keys: PublicKeys,
    ) ContractInstance {
        return .{
            .version = CONTRACT_INSTANCE_VERSION,
            .salt = salt,
            .deployer = deployer,
            .current_contract_class_id = contract_class_id,
            .original_contract_class_id = contract_class_id,
            .initialization_hash = initialization_hash,
            .public_keys = public_keys,
            .address = null,
        };
    }

    /// Options for creating a contract instance from deployment parameters.
    pub const DeployParams = struct {
        constructor_name: ?[]const u8 = null,
        constructor_args: []const Fr = &[_]Fr{},
        salt: ?Fr = null,
        public_keys: ?PublicKeys = null,
        deployer: ?AztecAddress = null,
    };

    /// Creates a contract instance from deployment parameters.
    pub fn fromDeployParams(
        contract_abi: nargo.ContractAbi,
        params: DeployParams,
    ) ContractInstance {
        // Use provided values or defaults.
        const salt = params.salt orelse Fr.random();
        const public_keys = params.public_keys orelse PublicKeys.default();
        const deployer = params.deployer orelse AztecAddress.zero;
        const contract_class = ContractClass.fromContractAbi(contract_abi);

        // Get the constructor.
        var ctor = contract_abi.default_initializer;
        if (params.constructor_name) |name| {
            for (contract_abi.initializer_functions) |f| {
                if (std.mem.eql(u8, f.name, name)) {
                    ctor = f;
                }
            }
        }

        // Compute initialization hash
        const initialization_hash = computeInitializationHash(
            params.constructor_name,
            params.constructor_args,
        );

        // Create the instance
        var instance = init(
            salt,
            deployer,
            contract_class_id,
            initialization_hash,
            public_keys,
        );

        // Compute and set the address
        instance.address = instance.computeAddress();

        return instance;
    }

    /// Computes the initialization hash for a constructor.
    fn computeInitializationHash(
        constructor_name: ?[]const u8,
        args: []const Fr,
    ) Fr {
        // If no constructor, return zero
        if (constructor_name == null) {
            return Fr.zero;
        }

        // TODO: For now, we'll use a simplified version.
        // The full implementation would need:
        // 1. Compute function selector from constructor name
        // 2. Compute args hash using computeVarArgsHash
        // 3. Hash [selector, argsHash] with CONSTRUCTOR generator

        // Simplified: just hash the args if any
        if (args.len == 0) {
            return Fr.zero;
        }

        // Hash the constructor arguments
        return poseidon2.hashWithSeparator(
            args,
            @intFromEnum(constants.GeneratorIndex.function_args),
        );
    }

    // /// Computes the hash of the contract instance.
    // /// This hash is used for various purposes including address computation.
    // pub fn hash(self: ContractInstance) Fr {
    //     const inputs = [_]Fr{
    //         Fr.from_int(self.version),
    //         self.salt,
    //         self.deployer.value,
    //         self.current_contract_class_id,
    //         self.original_contract_class_id,
    //         self.initialization_hash,
    //         self.public_keys.hash(),
    //     };

    //     return poseidon2.hashWithSeparator(
    //         &inputs,
    //         @intFromEnum(constants.GeneratorIndex.contract_leaf),
    //     );
    // }

    // /// Computes the address for this contract instance.
    // pub fn computeAddress(self: ContractInstance) AztecAddress {
    //     // Contract address is computed from public keys hash and partial address
    //     const partial_address = self.computePartialAddress();
    //     return key_derivation.computeAddress(self.public_keys, partial_address);
    // }

    // /// Computes the partial address (a component of the full address computation).
    // pub fn computePartialAddress(self: ContractInstance) Fr {
    //     const inputs = [_]Fr{
    //         self.current_contract_class_id,
    //         self.salt,
    //     };

    //     return poseidon2.hashWithSeparator(
    //         &inputs,
    //         @intFromEnum(constants.GeneratorIndex.partial_address),
    //     );
    // }

    // /// Returns whether this instance was universally deployed (no specific deployer).
    // pub fn isUniversalDeploy(self: ContractInstance) bool {
    //     return self.deployer.value.eql(Fr.zero);
    // }

    // /// Creates a contract instance for a universal deploy.
    // pub fn universal(
    //     salt: Fr,
    //     contract_class_id: Fr,
    //     initialization_hash: Fr,
    //     public_keys: PublicKeys,
    // ) ContractInstance {
    //     return init(
    //         salt,
    //         AztecAddress.zero,
    //         contract_class_id,
    //         initialization_hash,
    //         public_keys,
    //     );
    // }
};
