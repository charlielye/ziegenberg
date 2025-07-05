const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const G1 = @import("../grumpkin/g1.zig").G1;
const ForeignCallParam = @import("../bvm/foreign_call/param.zig").ForeignCallParam;

pub const AztecAddress = struct {
    value: Fr,

    pub const zero = AztecAddress.init(Fr.zero);

    pub fn init(value: Fr) AztecAddress {
        return .{ .value = value };
    }

    pub fn random() AztecAddress {
        return .{ .value = Fr.random() };
    }

    pub fn toAddressPoint(self: AztecAddress) G1.Element {
        _ = self;
        // TODO: #8970 - Computation of address point from x coordinate might fail
        // For now, this is a placeholder that needs proper implementation
        return G1.Element.infinity;
    }

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
};
