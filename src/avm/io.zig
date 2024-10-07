const std = @import("std");

pub const Tag = enum {
    UINT0,
    UINT1,
    UINT8,
    UINT16,
    UINT32,
    UINT64,
    UINT128,
    FF,

    pub fn format(self: Tag, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{@tagName(self)});
    }
};

const ThreeOperands8 = struct {
    indirect: u8,
    tag: Tag,
    op1_slot: u8,
    op2_slot: u8,
    op3_slot: u8,
};

const ThreeOperands16 = struct {
    indirect: u8,
    tag: Tag,
    op1_slot: u16,
    op2_slot: u16,
    op3_slot: u16,
};

const KernelInputOperands = struct {
    indirect: u8,
    offset: u32,
};

const ExternalCallOperands = struct {
    indirect: u8,
    gas: u32,
    addr: u32,
    args: u32,
    argsSize: u32,
    ret: u32,
    retSize: u32,
    success: u32,
    functionSelector: u32,
};

pub const AvmOpcode = union(enum) {
    // Compute - Arithmetic. 0
    ADD_8: ThreeOperands8,
    ADD_16: ThreeOperands16,
    SUB_8: ThreeOperands8,
    SUB_16: ThreeOperands16,
    MUL_8: ThreeOperands8,
    MUL_16: ThreeOperands16,
    DIV_8: ThreeOperands8,
    DIV_16: ThreeOperands16,
    FDIV_8: ThreeOperands8,
    FDIV_16: ThreeOperands16,
    // Compute - Comparison. 10
    EQ_8: ThreeOperands8,
    EQ_16: ThreeOperands16,
    LT_8: ThreeOperands8,
    LT_16: ThreeOperands16,
    LTE_8: ThreeOperands8,
    LTE_16: ThreeOperands16,
    // Compute - Bitwise. 16
    AND_8: ThreeOperands8,
    AND_16: ThreeOperands16,
    OR_8: ThreeOperands8,
    OR_16: ThreeOperands16,
    XOR_8: ThreeOperands8,
    XOR_16: ThreeOperands16,
    NOT_8: struct { indirect: u8, op1_slot: u8, op2_slot: u8 },
    NOT_16: struct { indirect: u8, op1_slot: u16, op2_slot: u16 },
    SHL_8: ThreeOperands8,
    SHL_16: ThreeOperands16,
    SHR_8: ThreeOperands8,
    SHR_16: ThreeOperands16,
    // Compute - Type Conversions. 28
    CAST_8: struct { indirect: u8, tag: Tag, op1_slot: u8, op2_slot: u8 },
    CAST_16: struct { indirect: u8, tag: Tag, op1_slot: u16, op2_slot: u16 },
    // Execution Environment - Globals. 30
    GETENVVAR_16: struct { indirect: u8, var_idx: u8, dst_slot: u16 },
    // Execution Environment - Calldata. 31
    CALLDATACOPY: struct { indirect: u8, start_slot: u32, size_slot: u32, dst_slot: u32 },
    // Machine State - Internal Control Flow. 32
    JUMP_16: struct { address: u16 },
    JUMPI_16: struct { indirect: u8, address: u16, condition_slot: u16 },
    INTERNALCALL: struct { address: u32 },
    INTERNALRETURN: struct {},
    // Machine State - Memory. 36
    SET_8: struct { indirect: u8, tag: Tag, value: u8, dst_slot: u8 },
    SET_16: struct { indirect: u8, tag: Tag, value: u16, dst_slot: u16 },
    SET_32: struct { indirect: u8, tag: Tag, value: u32, dst_slot: u16 },
    SET_64: struct { indirect: u8, tag: Tag, value: u64, dst_slot: u16 },
    SET_128: struct { indirect: u8, tag: Tag, value: u128, dst_slot: u16 },
    SET_FF: struct { indirect: u8, tag: Tag, value: u256, dst_slot: u16 },
    MOV_8: struct { indirect: u8, src_slot: u8, dst_slot: u8 },
    MOV_16: struct { indirect: u8, src_slot: u16, dst_slot: u16 },
    CMOV: struct { indirect: u8, condition: u32, src1: u32, src2: u32, dest: u32 },
    // Side Effects - Storage. 45
    SLOAD: struct { indirect: u8, slot_slot: u32, dst_slot: u32 },
    SSTORE: struct { indirect: u8, slot_slot: u32, value_slot: u32 },
    // Side Effects - Notes, Nullfiers, Logs, Messages. 47
    NOTEHASHEXISTS: struct { indirect: u8, value: u32, leafIndex: u32, result: u32 },
    EMITNOTEHASH: struct { indirect: u8, value: u32 },
    NULLIFIEREXISTS: struct { indirect: u8, value: u32, address: u32, result: u32 },
    EMITNULLIFIER: struct { indirect: u8, value: u32 },
    L1TOL2MSGEXISTS: struct { indirect: u8, value: u32, leafIndex: u32, result: u32 },
    GETCONTRACTINSTANCE: struct { indirect: u8, index: u32, result: u32 },
    EMITUNENCRYPTEDLOG: struct { indirect: u8, data: u32, dataSize: u32 },
    SENDL2TOL1MSG: struct { indirect: u8, data: u32, dataSize: u32 },
    // Control Flow - Contract Calls. 55
    CALL: ExternalCallOperands,
    STATICCALL: ExternalCallOperands,
    DELEGATE_CALL: struct {},
    RETURN: struct { indirect: u8, data: u32, dataSize: u32 },
    REVERT_8: struct { indirect: u8, data: u8, dataSize: u8 },
    REVERT_16: struct { indirect: u8, data: u16, dataSize: u16 },
    // Misc. 60
    DEBUGLOG: struct { indirect: u8, msg_slot: u32, msg_size: u32, fields_slot: u32, fields_size_slot: u32 },
    // Gadgets
    KECCAK: struct { indirect: u8, data: u32, dataLength: u32, result: u32 },
    POSEIDON2: struct { indirect: u8, data: u32, result: u32 },
    SHA256COMPRESSION: struct {
        indirect: u8,
        state: u32,
        roundConstants: u32,
        data: u32,
        dataLength: u32,
        result: u32,
    },
    KECCAKF1600: struct { indirect: u8, state: u32, roundConstants: u32, result: u32 },
    PEDERSEN: struct { indirect: u8, x: u32, y: u32, z: u32, result: u32 },
    ECADD: struct {
        indirect: u8,
        lhsX: u32,
        lhsY: u32,
        lhsIsInf: u32,
        rhsX: u32,
        rhsY: u32,
        rhsIsInf: u32,
        result: u32,
    },
    MSM: struct { indirect: u8, points: u32, scalars: u32, length: u32, result: u32 },
    PEDERSENCOMMITMENT: struct { indirect: u8, data: u32, randomness: u32, length: u32, result: u32 },
    TORADIXLE: struct {
        indirect: u8,
        src_slot: u32,
        dst_slot: u32,
        radix_slot: u32,
        num_limbs: u32,
        output_bits: u8,
    },

    pub fn format(self: AvmOpcode, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const tag_name = @tagName(self);
        try writer.print("{s: >16} ", .{tag_name});

        const union_info = @typeInfo(AvmOpcode).Union;
        inline for (union_info.fields) |field| {
            if (self == @field(AvmOpcode, field.name)) {
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

    try writer.print("{{", .{});
    var first = true;
    inline for (type_info.Struct.fields) |field| {
        if (!first) try writer.print(", ", .{});
        first = false;

        const field_value = @field(ptr, field.name);
        // if (field.type == u256) {
        //     try writer.print(".{s} = {x}", .{ field.name, field_value });
        // } else {
        try writer.print(".{s} = {any}", .{ field.name, field_value });
        // }
    }
    try writer.print("}}", .{});
}

pub fn deserializeOpcodes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]AvmOpcode {
    var instructions = std.ArrayList(AvmOpcode).init(allocator);
    defer instructions.deinit();

    var i: usize = 0;
    while (i < bytes.len) {
        const opcode_byte = bytes[i];
        i += 1;

        const union_info = @typeInfo(AvmOpcode).Union;
        const opcode: union_info.tag_type.? = @enumFromInt(opcode_byte);

        inline for (union_info.fields) |field| {
            if (opcode == @field(union_info.tag_type.?, field.name)) {
                const operands = try readOperands(field.type, bytes, &i);
                const instruction = @unionInit(AvmOpcode, field.name, operands);
                try instructions.append(instruction);
                // std.debug.print("{any}\n", .{instruction});
            }
        }
    }

    return instructions.toOwnedSlice();
}

pub fn load(allocator: std.mem.Allocator, file_path: ?[]const u8) ![]AvmOpcode {
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
