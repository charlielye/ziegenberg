const std = @import("std");

pub const Tag = enum {
    FF,
    U1,
    U8,
    U16,
    U32,
    U64,
    U128,
    UNSET,

    pub fn format(self: Tag, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{@tagName(self)});
    }
};

fn ThreeOperands(slot_type: type) type {
    return struct {
        indirect: u8,
        op1_slot: slot_type,
        op2_slot: slot_type,
        op3_slot: slot_type,
    };
}

const ThreeOperands8 = ThreeOperands(u8);
const ThreeOperands16 = ThreeOperands(u16);
const ThreeOperands32 = ThreeOperands(u32);

const KernelInputOperands = struct {
    indirect: u8,
    offset: u16,
};

const ExternalCallOperands = struct {
    indirect: u8,
    gas: u16,
    addr: u16,
    args: u16,
    argsSize: u16,
    ret: u16,
    retSize: u16,
    success: u16,
    functionSelector: u16,
};

fn AvmOpcodes(slot_type: type) type {
    return union(enum) {
        // Compute - Arithmetic.
        ADD: ThreeOperands(slot_type),
        SUB: ThreeOperands(slot_type),
        MUL: ThreeOperands(slot_type),
        DIV: ThreeOperands(slot_type),
        FDIV: ThreeOperands(slot_type),
        // Compute - Comparison.
        EQ: ThreeOperands(slot_type),
        LT: ThreeOperands(slot_type),
        LTE: ThreeOperands(slot_type),
        // Compute - Bitwise.
        AND: ThreeOperands(slot_type),
        OR: ThreeOperands(slot_type),
        XOR: ThreeOperands(slot_type),
        NOT: struct { indirect: u8, op1_slot: slot_type, op2_slot: slot_type },
        SHL: ThreeOperands(slot_type),
        SHR: ThreeOperands(slot_type),
        // Compute - Type Conversions.
        CAST: struct { indirect: u8, tag: Tag, op1_slot: slot_type, op2_slot: slot_type },
        // Execution Environment - Globals.
        GETENVVAR: struct { indirect: u8, var_idx: u8, dst_slot: slot_type },
        // Execution Environment - Calldata.
        CALLDATACOPY: struct { indirect: u8, start_slot: slot_type, size_slot: slot_type, dst_slot: slot_type },
        // Machine State - Internal Control Flow.
        JUMP: struct { address: u16 },
        JUMPI: struct { indirect: u8, address: u16, condition_slot: slot_type },
        INTERNALCALL: struct { address: u16 },
        INTERNALRETURN: struct {},
        // Machine State - Memory.
        SET8: struct { indirect: u8, tag: Tag, value: u8, dst_slot: slot_type },
        SET16: struct { indirect: u8, tag: Tag, value: u16, dst_slot: slot_type },
        SET32: struct { indirect: u8, tag: Tag, value: u32, dst_slot: slot_type },
        SET64: struct { indirect: u8, tag: Tag, value: u64, dst_slot: slot_type },
        SET128: struct { indirect: u8, tag: Tag, value: u128, dst_slot: slot_type },
        SETFF: struct { indirect: u8, tag: Tag, value: u256, dst_slot: slot_type },
        MOV: struct { indirect: u8, src_slot: slot_type, dst_slot: slot_type },
        // Side Effects - Storage.
        SLOAD: struct { indirect: u8, slot_slot: slot_type, dst_slot: slot_type },
        SSTORE: struct { indirect: u8, slot_slot: slot_type, value_slot: slot_type },
        // Side Effects - Notes, Nullfiers, Logs, Messages.
        NOTEHASHEXISTS: struct { indirect: u8, value: u16, leafIndex: u16, result: u16 },
        EMITNOTEHASH: struct { indirect: u8, value: u16 },
        NULLIFIEREXISTS: struct { indirect: u8, value: u16, address: u16, result: u16 },
        EMITNULLIFIER: struct { indirect: u8, value: u16 },
        L1TOL2MSGEXISTS: struct { indirect: u8, value: u16, leafIndex: u16, result: u16 },
        GETCONTRACTINSTANCE: struct { indirect: u8, index: u32, result: u32 },
        EMITUNENCRYPTEDLOG: struct { indirect: u8, data: u16, dataSize: u16 },
        SENDL2TOL1MSG: struct { indirect: u8, data: u16, dataSize: u16 },
        // Control Flow - Contract Calls. 55
        CALL: ExternalCallOperands,
        STATICCALL: ExternalCallOperands,
        RETURN: struct { indirect: u8, data_slot: slot_type, size_slot: slot_type },
        REVERT: struct { indirect: u8, data_slot: slot_type, size_slot: slot_type },
        // Misc. 60
        DEBUGLOG: struct {
            indirect: u8,
            msg_slot: slot_type,
            msg_size: u16,
            fields_slot: slot_type,
            fields_size_slot: slot_type,
        },
        // Gadgets
        POSEIDON2: struct { indirect: u8, input_slot: slot_type, output_slot: slot_type },
        SHA256COMPRESSION: struct {
            indirect: u8,
            output_slot: slot_type,
            state_slot: slot_type,
            inputs_slot: slot_type,
        },
        KECCAKF1600: struct { indirect: u8, dst_slot: slot_type, msg_slot: slot_type },
        ECADD: struct {
            indirect: u16,
            lhs_x_slot: slot_type,
            lhs_y_slot: slot_type,
            lhs_inf_slot: slot_type,
            rhs_x_slot: slot_type,
            rhs_y_slot: slot_type,
            rhs_inf_slot: slot_type,
            dst_slot: slot_type,
        },
        MSM: struct {
            indirect: u8,
            points_slot: slot_type,
            scalars_slot: slot_type,
            dst_slot: slot_type,
            size_slot: slot_type,
        },
        TORADIXLE: struct {
            indirect: u8,
            src_slot: slot_type,
            dst_slot: slot_type,
            radix_slot: slot_type,
            num_limbs: u16,
            output_bits: u8,
        },
        NOOP: struct {},

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            const tag_name = @tagName(self);
            try writer.print("{s: >16} ", .{tag_name});

            const union_info = @typeInfo(@This()).Union;
            inline for (union_info.fields) |field| {
                if (self == @field(@This(), field.name)) {
                    const field_ptr = @field(self, field.name);
                    try formatStruct(field.type, field_ptr, writer);
                }
            }
        }
    };
}

const AvmOpcode8 = AvmOpcodes(u8);
const AvmOpcode16 = AvmOpcodes(u16);
pub const AvmOpcode32 = AvmOpcodes(u32);

// Helper function to get the associated type of a union tag.
fn getUnionFieldType(comptime UnionType: type, comptime TagName: []const u8) type {
    @setEvalBranchQuota(5000);
    const info = @typeInfo(UnionType);
    const union_info = info.Union;
    for (union_info.fields) |field| {
        if (std.mem.eql(u8, field.name, TagName)) {
            return field.type;
        }
    }
}

// Represents the wire format of AVM bytecode.
// We deserialize to this, then normalize to AvmOpcode32.
// This means come execution we:
//   - Don't need to worry about the size variants.
//   - Can dereference slots without truncation (mem can grow beyond 16 bit slot addresses).
const AvmWireOpcode = union(enum) {
    // Compute - Arithmetic. 0
    ADD_8: getUnionFieldType(AvmOpcode8, "ADD"),
    ADD_16: getUnionFieldType(AvmOpcode16, "ADD"),
    SUB_8: getUnionFieldType(AvmOpcode8, "SUB"),
    SUB_16: getUnionFieldType(AvmOpcode16, "SUB"),
    MUL_8: getUnionFieldType(AvmOpcode8, "MUL"),
    MUL_16: getUnionFieldType(AvmOpcode16, "MUL"),
    DIV_8: getUnionFieldType(AvmOpcode8, "DIV"),
    DIV_16: getUnionFieldType(AvmOpcode16, "DIV"),
    FDIV_8: getUnionFieldType(AvmOpcode8, "FDIV"),
    FDIV_16: getUnionFieldType(AvmOpcode16, "FDIV"),
    // Compute - Comparison. 10
    EQ_8: getUnionFieldType(AvmOpcode8, "EQ"),
    EQ_16: getUnionFieldType(AvmOpcode16, "EQ"),
    LT_8: getUnionFieldType(AvmOpcode8, "LT"),
    LT_16: getUnionFieldType(AvmOpcode16, "LT"),
    LTE_8: getUnionFieldType(AvmOpcode8, "LTE"),
    LTE_16: getUnionFieldType(AvmOpcode16, "LTE"),
    // Compute - Bitwise. 16
    AND_8: getUnionFieldType(AvmOpcode8, "AND"),
    AND_16: getUnionFieldType(AvmOpcode16, "AND"),
    OR_8: getUnionFieldType(AvmOpcode8, "OR"),
    OR_16: getUnionFieldType(AvmOpcode16, "OR"),
    XOR_8: getUnionFieldType(AvmOpcode8, "XOR"),
    XOR_16: getUnionFieldType(AvmOpcode16, "XOR"),
    NOT_8: getUnionFieldType(AvmOpcode8, "NOT"),
    NOT_16: getUnionFieldType(AvmOpcode16, "NOT"),
    SHL_8: getUnionFieldType(AvmOpcode8, "SHL"),
    SHL_16: getUnionFieldType(AvmOpcode16, "SHL"),
    SHR_8: getUnionFieldType(AvmOpcode8, "SHR"),
    SHR_16: getUnionFieldType(AvmOpcode16, "SHR"),
    // Compute - Type Conversions. 28
    CAST_8: getUnionFieldType(AvmOpcode8, "CAST"),
    CAST_16: getUnionFieldType(AvmOpcode16, "CAST"),
    // Execution Environment - Globals. 30
    GETENVVAR_16: getUnionFieldType(AvmOpcode16, "GETENVVAR"),
    // Execution Environment - Calldata. 31
    CALLDATACOPY: getUnionFieldType(AvmOpcode16, "CALLDATACOPY"),
    // Machine State - Internal Control Flow. 32
    JUMP_16: getUnionFieldType(AvmOpcode16, "JUMP"),
    JUMPI_16: getUnionFieldType(AvmOpcode16, "JUMPI"),
    INTERNALCALL: getUnionFieldType(AvmOpcode16, "INTERNALCALL"),
    INTERNALRETURN: getUnionFieldType(AvmOpcode16, "INTERNALRETURN"),
    // Machine State - Memory. 36
    SET8: getUnionFieldType(AvmOpcode8, "SET8"), // TODO: This needs fixing to 16 bit slot size.
    SET16: getUnionFieldType(AvmOpcode16, "SET16"),
    SET32: getUnionFieldType(AvmOpcode16, "SET32"),
    SET64: getUnionFieldType(AvmOpcode16, "SET64"),
    SET128: getUnionFieldType(AvmOpcode16, "SET128"),
    SETFF: getUnionFieldType(AvmOpcode16, "SETFF"),
    MOV_8: getUnionFieldType(AvmOpcode8, "MOV"),
    MOV_16: getUnionFieldType(AvmOpcode16, "MOV"),
    // Side Effects - Storage. 44
    SLOAD: getUnionFieldType(AvmOpcode16, "SLOAD"),
    SSTORE: getUnionFieldType(AvmOpcode16, "SSTORE"),
    // Side Effects - Notes, Nullfiers, Logs, Messages. 46
    NOTEHASHEXISTS: getUnionFieldType(AvmOpcode16, "NOTEHASHEXISTS"),
    EMITNOTEHASH: getUnionFieldType(AvmOpcode16, "EMITNOTEHASH"),
    NULLIFIEREXISTS: getUnionFieldType(AvmOpcode16, "NULLIFIEREXISTS"),
    EMITNULLIFIER: getUnionFieldType(AvmOpcode16, "EMITNULLIFIER"),
    L1TOL2MSGEXISTS: getUnionFieldType(AvmOpcode16, "L1TOL2MSGEXISTS"),
    GETCONTRACTINSTANCE: getUnionFieldType(AvmOpcode32, "GETCONTRACTINSTANCE"),
    EMITUNENCRYPTEDLOG: getUnionFieldType(AvmOpcode16, "EMITUNENCRYPTEDLOG"),
    SENDL2TOL1MSG: getUnionFieldType(AvmOpcode16, "SENDL2TOL1MSG"),
    // Control Flow - Contract Calls. 54
    CALL: getUnionFieldType(AvmOpcode16, "CALL"),
    STATICCALL: getUnionFieldType(AvmOpcode16, "STATICCALL"),
    RETURN: getUnionFieldType(AvmOpcode16, "RETURN"),
    REVERT_8: getUnionFieldType(AvmOpcode8, "REVERT"),
    REVERT_16: getUnionFieldType(AvmOpcode16, "REVERT"),
    // Misc. 59
    DEBUGLOG: getUnionFieldType(AvmOpcode16, "DEBUGLOG"),
    // Gadgets. 60
    POSEIDON2: getUnionFieldType(AvmOpcode16, "POSEIDON2"),
    SHA256COMPRESSION: getUnionFieldType(AvmOpcode16, "SHA256COMPRESSION"),
    KECCAKF1600: getUnionFieldType(AvmOpcode16, "KECCAKF1600"),
    ECADD: getUnionFieldType(AvmOpcode16, "ECADD"),
    MSM: getUnionFieldType(AvmOpcode16, "MSM"),
    TORADIXLE: getUnionFieldType(AvmOpcode16, "TORADIXLE"),
    NOOP: getUnionFieldType(AvmOpcode16, "NOOP"),

    pub fn format(self: AvmWireOpcode, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const tag_name = @tagName(self);
        try writer.print("{s: >16} ", .{tag_name});

        const union_info = @typeInfo(AvmWireOpcode).Union;
        inline for (union_info.fields) |field| {
            if (self == @field(AvmWireOpcode, field.name)) {
                const field_ptr = @field(self, field.name);
                try formatStruct(field.type, field_ptr, writer);
            }
        }
    }
};

// Function to read operands into the operand struct
fn readOperands(comptime T: type, bytes: []const u8, index: *usize) !T {
    var result: T = undefined;
    var i = index.*;

    const fields = @typeInfo(T).Struct.fields;

    inline for (fields) |field| {
        const field_ptr = &@field(&result, field.name);
        const field_size = @sizeOf(field.type);

        if (i + field_size > bytes.len) {
            return error.InvalidBytecode;
        }

        // const value = try readValue(field.type, bytes, i);
        const value = switch (@typeInfo(field.type)) {
            .Int => std.mem.readInt(field.type, @ptrCast(bytes[i..]), std.builtin.Endian.big),
            .Enum => @as(Tag, @enumFromInt(bytes[i])),
            else => unreachable,
        };
        // const value = std.mem.readInt(field.type, @ptrCast(bytes[i..]), std.builtin.Endian.big);
        field_ptr.* = value;

        i += field_size;
    }

    index.* = i;
    return result;
}

fn formatStruct(comptime T: type, ptr: anytype, writer: anytype) !void {
    const type_info = @typeInfo(T);
    if (type_info != .Struct) {
        return;
    }

    try writer.print("{{ ", .{});
    var first = true;
    comptime var slot_field_index: usize = 0;
    comptime var num_slot_operands: usize = 0;
    comptime for (type_info.Struct.fields) |field| {
        if (std.mem.endsWith(u8, field.name, "_slot")) {
            num_slot_operands += 1;
        }
    };
    inline for (type_info.Struct.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "indirect")) {
            continue;
        }

        if (!first) try writer.print(", ", .{});
        first = false;

        const field_value = @field(ptr, field.name);
        if (comptime std.mem.endsWith(u8, field.name, "_slot")) {
            const is_relative = (ptr.indirect >> (num_slot_operands + slot_field_index)) & 0x1 == 1;
            const is_indirect = (ptr.indirect >> slot_field_index) & 0x1 == 1;
            try writer.print(".{s} = {s}{any}{s}", .{
                field.name,
                if (is_relative) "+" else "",
                field_value,
                if (is_indirect) ">" else "",
            });
            slot_field_index += 1;
        } else {
            try writer.print(".{s} = {any}", .{ field.name, field_value });
        }
    }
    try writer.print(" }}", .{});
}

fn deserializeOpcodes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]AvmOpcode32 {
    var instructions = std.ArrayList(AvmWireOpcode).init(allocator);
    defer instructions.deinit();

    var i: usize = 0;
    while (i < bytes.len) {
        const opcode_byte = bytes[i];
        i += 1;

        const union_info = @typeInfo(AvmWireOpcode).Union;
        const opcode: union_info.tag_type.? = @enumFromInt(opcode_byte);

        inline for (union_info.fields) |field| {
            if (opcode == @field(union_info.tag_type.?, field.name)) {
                const operands = try readOperands(field.type, bytes, &i);
                const instruction = @unionInit(AvmWireOpcode, field.name, operands);
                try instructions.append(instruction);
                // std.debug.print("{any}\n", .{instruction});
            }
        }
    }

    return normalizeOpcodes(allocator, instructions.items);
}

fn normalizeOpcodes(
    allocator: std.mem.Allocator,
    opcodes: []AvmWireOpcode,
) ![]AvmOpcode32 {
    @setEvalBranchQuota(10000);

    var opcodes32 = try std.ArrayList(AvmOpcode32).initCapacity(allocator, opcodes.len);

    for (opcodes) |*opcode| {
        const tag = @tagName(opcode.*);

        const union_info_wire = @typeInfo(AvmWireOpcode).Union;
        const union_info_32 = @typeInfo(AvmOpcode32).Union;
        inline for (union_info_wire.fields) |old_opcode| {
            if (std.mem.eql(u8, old_opcode.name, tag)) {
                // We've matched at runtime against the opcode name, so can extract the old_value.
                const old_value = @field(opcode.*, old_opcode.name);
                // const new_tag = old_opcode.name[0 .. old_opcode.name.len - 2] ++ "_16";
                // @compileLog(std.fmt.comptimePrint("{s}", .{new_tag}));
                const new_tag = comptime if (std.mem.endsWith(u8, old_opcode.name, "_8"))
                    old_opcode.name[0 .. old_opcode.name.len - 2]
                else if (std.mem.endsWith(u8, old_opcode.name, "_16"))
                    old_opcode.name[0 .. old_opcode.name.len - 3]
                else
                    old_opcode.name;

                inline for (union_info_32.fields) |new_opcode| {
                    // Comptime, early out if it's not the correct variant.
                    if (comptime !std.mem.eql(u8, new_opcode.name, new_tag)) {
                        continue;
                    }
                    // Create a new value of the 32 bit variant type.
                    var new_value: new_opcode.type = undefined;
                    // Copy each field from the old variant to the new variant.
                    inline for (@typeInfo(new_opcode.type).Struct.fields) |struct_field| {
                        const old_field_value = @field(old_value, struct_field.name);
                        @field(new_value, struct_field.name) = old_field_value;
                    }

                    try opcodes32.append(@unionInit(AvmOpcode32, new_opcode.name, new_value));
                }
            }
        }
    }

    return try opcodes32.toOwnedSlice();
}

pub fn load(allocator: std.mem.Allocator, file_path: ?[]const u8) ![]AvmOpcode32 {
    var serialized_data: []u8 = undefined;
    if (file_path) |p| {
        const file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        serialized_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    } else {
        const stdin = std.io.getStdIn();
        serialized_data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    }

    return try deserializeOpcodes(allocator, serialized_data);
}
