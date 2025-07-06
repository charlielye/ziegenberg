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
    version: u8 = CONTRACT_INSTANCE_VERSION,
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
        allocator: std.mem.Allocator,
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

        // Compute initialization hash.
        const initialization_hash = if (ctor)
            computeInitializationHash(allocator, ctor, params.constructor_args)
        else
            Fr.zero;

        const instance = ContractInstance{
            .salt = salt,
            .deployer = deployer,
            .current_contract_class_id = contract_class.id,
            .original_contract_class_id = contract_class.id,
            .initialization_hash = initialization_hash,
            .public_keys = public_keys,
            .address = null,
        };
        instance.address = instance.computeAddress();
        return instance;
    }

    /// Computes the initialization hash for a constructor.
    fn computeInitializationHash(
        allocator: std.mem.Allocator,
        ctor: nargo.Function,
        args: []const Fr,
    ) Fr {
        const args_fields = std.ArrayList(Fr).initCapacity(allocator, args.len + 1);
        defer args_fields.deinit();
        args_fields.append(Fr.from_int(constants.GeneratorIndex.function_args)) catch unreachable;
        for (args) |arg| args_fields.append(arg) catch unreachable;
        const args_hash = poseidon2.hash(args_fields.items);
        return poseidon2.hash(&[_]Fr{
            Fr.from_int(constants.GeneratorIndex.constructor),
            Fr.from_int(ctor.selector),
            args_hash,
        });
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

    /// Computes the address for this contract instance.
    pub fn computeAddress(self: *ContractInstance) AztecAddress {
        // Contract address is computed from public keys hash and partial address
        const partial_address = self.computePartialAddress();
        return key_derivation.computeAddress(self.public_keys, partial_address);
    }

    /// Computes the partial address (a component of the full address computation).
    pub fn computePartialAddress(self: *ContractInstance) Fr {
        const inputs = [_]Fr{
            Fr.from_int(constants.GeneratorIndex.partial_address),
            self.current_contract_class_id,
            self.salt,
        };
        return poseidon2.hash(&inputs);
    }

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
