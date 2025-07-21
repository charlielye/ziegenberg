const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const prover_toml = @import("prover_toml.zig");
const nargo_artifact = @import("artifact.zig");
const toml = @import("toml");

fn anyIntToU256(width: ?u32, value: i256) u256 {
    if (width) |w| {
        const mask = (@as(u256, 1) << @truncate(w)) - 1;
        return @as(u256, @bitCast(value)) & mask;
    }
    return @bitCast(value);
}

fn parseNumberString(str: []const u8, width: ?u32) !u256 {
    return if (std.mem.startsWith(u8, str, "0x"))
        try std.fmt.parseInt(u256, str[2..], 16)
    else if (std.mem.startsWith(u8, str, "-0x"))
        anyIntToU256(width, -try std.fmt.parseInt(i256, str[3..], 16))
    else
        anyIntToU256(width, try std.fmt.parseInt(i256, str, 10));
}

// Example parameter:
//   {"name":"z","type":{"kind":"integer","sign":"unsigned","width":32},"visibility":"private"},
//   {"name":"x","type":{"kind":"array","length":5,"type":{"kind":"integer","sign":"unsigned","width":32}},"visibility":"private"},
fn loadCalldata(calldata_array: *std.ArrayList(Fr), param_type: nargo_artifact.Type, value: toml.Value) !void {
    switch (std.meta.stringToEnum(nargo_artifact.Kind, param_type.kind.?).?) {
        .boolean => {
            const as_int: u256 = switch (value) {
                .boolean => if (value.boolean) 1 else 0,
                .integer => if (value.integer != 0) 1 else 0,
                .string => if (try parseNumberString(value.string, null) == 0) 0 else 1,
                else => unreachable,
            };
            try calldata_array.append(Fr.from_int(as_int));
        },
        .field => {
            const as_int: u256 = switch (value) {
                .integer => @intCast(value.integer),
                .string => try parseNumberString(value.string, null),
                else => unreachable,
            };
            try calldata_array.append(Fr.from_int(as_int));
        },
        .integer => {
            const as_int: u256 = switch (value) {
                .integer => anyIntToU256(param_type.width, value.integer),
                .string => try parseNumberString(value.string, param_type.width),
                else => unreachable,
            };
            try calldata_array.append(Fr.from_int(as_int));
        },
        .string => {
            for (value.string) |elem| {
                const as_int: u256 = @intCast(elem);
                try calldata_array.append(Fr.from_int(as_int));
            }
        },
        .array => {
            for (value.array.items) |elem| {
                try loadCalldata(calldata_array, param_type.type.?.*, elem);
            }
        },
        .@"struct" => {
            for (param_type.fields.?) |field| {
                const field_value = value.table.get(field.name.?) orelse {
                    std.debug.print("Missing field {s} in struct {s}\n", .{ field.name.?, param_type.kind.? });
                    return error.MissingField;
                };
                try loadCalldata(calldata_array, field.type.?.*, field_value);
            }
        },
        .tuple => {
            for (value.array.items, 0..) |elem, i| {
                try loadCalldata(calldata_array, param_type.fields.?[i], elem);
            }
        },
    }
}

pub fn loadCalldataFromProverToml(
    allocator: std.mem.Allocator,
    artifact: *const nargo_artifact.ArtifactAbi,
    pt_path: []const u8,
) ![]Fr {
    const pt = try prover_toml.load(allocator, pt_path);
    var calldata_array = std.ArrayList(Fr).init(allocator);
    defer calldata_array.deinit();
    std.debug.print("Loading calldata from {s}...\n", .{pt_path});
    for (artifact.abi.parameters, 0..) |param, i| {
        const value = pt.get(param.name) orelse unreachable;
        _ = i;
        // std.debug.print("Parameter {}: {s} ({s}) = {any}\n", .{
        //     i,
        //     param.name,
        //     param.type.kind.?,
        //     value,
        // });
        try loadCalldata(&calldata_array, param.type, value);
    }
    return calldata_array.toOwnedSlice();
}
