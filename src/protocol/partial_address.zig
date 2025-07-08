const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const G1 = @import("../grumpkin/g1.zig").G1;
const AztecAddress = @import("./aztec_address.zig").AztecAddress;
const poseidon2 = @import("../poseidon2/poseidon2.zig");
const constants = @import("constants.gen.zig");

pub const PartialAddress = struct {
    value: Fr,

    pub fn init(value: Fr) PartialAddress {
        return .{ .value = value };
    }

    pub fn compute(
        contract_class_id: Fr,
        salt: Fr,
        initialization_hash: Fr,
        deployer: AztecAddress,
    ) PartialAddress {
        return PartialAddress.computeFromSaltedInitializationHash(
            contract_class_id,
            PartialAddress.computeSaltedInitializationHash(
                salt,
                initialization_hash,
                deployer,
            ),
        );
    }

    pub fn computeFromSaltedInitializationHash(
        contract_class_id: Fr,
        salted_initialization_hash: Fr,
    ) PartialAddress {
        return PartialAddress.init(poseidon2.hashTuple(
            .{
                constants.GeneratorIndex.partial_address,
                contract_class_id,
                salted_initialization_hash,
            },
        ));
    }

    pub fn computeSaltedInitializationHash(salt: Fr, initialization_hash: Fr, deployer: AztecAddress) Fr {
        return poseidon2.hashTuple(
            .{
                constants.GeneratorIndex.partial_address,
                salt,
                initialization_hash,
                deployer.value,
            },
        );
    }

    // pub fn fromForeignCallParam(param: ForeignCallParam) !AztecAddress {
    //     if (param != .Single) return error.InvalidParam;
    //     return AztecAddress.init(Fr.from_int(param.Single));
    // }

    // pub fn toForeignCallParam(self: AztecAddress) ForeignCallParam {
    //     return ForeignCallParam{ .Single = self.value.to_int() };
    // }

    pub fn format(
        self: PartialAddress,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        return self.value.format(fmt, options, writer);
    }

    // pub fn eql(self: PartialAddress, other: PartialAddress) bool {
    //     return self.value.eql(other.value);
    // }

    // pub fn hash(self: PartialAddress) u64 {
    //     return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.limbs));
    // }
};
