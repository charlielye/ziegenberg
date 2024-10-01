const std = @import("std");

const ThreeOperands8 = struct {
    indirect: u8,
    tag: u8,
    op1: u8,
    op2: u8,
    op3: u8,
};

const ThreeOperands16 = struct {
    indirect: u8,
    tag: u8,
    op1: u16,
    op2: u16,
    op3: u16,
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

const OpCode = union(enum) {
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
    NOT_8: struct { indirect: u8, op1: u8, op2: u8 },
    NOT_16: struct { indirect: u8, op1: u16, op2: u16 },
    SHL_8: ThreeOperands8,
    SHL_16: ThreeOperands16,
    SHR_8: ThreeOperands8,
    SHR_16: ThreeOperands16,
    // Compute - Type Conversions. 28
    CAST_8: struct { indirect: u8, tag: u8, op1: u8, op2: u8 },
    CAST_16: struct { indirect: u8, tag: u8, op1: u16, op2: u16 },
    // Execution Environment - Globals. 30
    GETENVVAR_16: struct { indirect: u8, var_idx: u8, op1: u16 },
    // Execution Environment - Calldata. 31
    CALLDATACOPY: struct { indirect: u8, dest: u32, offset: u32, size: u32 },
    // Machine State - Internal Control Flow. 32
    JUMP_16: struct { address: u16 },
    JUMPI_16: struct { indirect: u8, condition: u16, address: u16 },
    INTERNALCALL: struct { destination: u32 },
    INTERNALRETURN: struct {},
    // Machine State - Memory. 36
    SET_8: struct { indirect: u8, tag: u8, value: u8, offset: u8 },
    SET_16: struct { indirect: u8, tag: u8, value: u16, offset: u16 },
    SET_32: struct { indirect: u8, tag: u8, value: u32, offset: u16 },
    SET_64: struct { indirect: u8, tag: u8, value: u64, offset: u16 },
    SET_128: struct { indirect: u8, tag: u8, value: u128, offset: u16 },
    SET_FF: struct { indirect: u8, tag: u8, value: u256, offset: u16 },
    MOV_8: struct { indirect: u8, src: u8, dest: u8 },
    MOV_16: struct { indirect: u8, src: u16, dest: u16 },
    CMOV: struct { indirect: u8, condition: u32, src1: u32, src2: u32, dest: u32 },
    // Side Effects - Storage. 45
    SLOAD: struct { indirect: u8, key: u32, value: u32 },
    SSTORE: struct { indirect: u8, key: u32, value: u32 },
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
    DEBUGLOG: struct { indirect: u8, value1: u32, value2: u32, value3: u32, value4: u32 },
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
        input: u32,
        base: u32,
        limbSize: u32,
        result: u32,
        packed_: u8,
    },

    pub fn format(self: OpCode, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const tag_name = @tagName(self);
        try writer.print("{s: >16} ", .{tag_name});

        const union_info = @typeInfo(OpCode).Union;
        inline for (union_info.fields) |field| {
            if (self == @field(OpCode, field.name)) {
                const field_ptr = @field(self, field.name);
                try format_struct(field.type, field_ptr, writer);
            }
        }
    }
};

// Function to read operands into the operand struct
fn read_operands(comptime T: type, bytes: []const u8, index: *usize) !T {
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
        const value = std.mem.readInt(field.type, @ptrCast(bytes[i..]), std.builtin.Endian.big);
        field_ptr.* = value;

        i += field_size;
    }

    index.* = i;
    return result;
}

pub fn deserialize_opcodes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]OpCode {
    var instructions = std.ArrayList(OpCode).init(allocator);
    defer instructions.deinit();

    var i: usize = 0;
    while (i < bytes.len) {
        const opcode_byte = bytes[i];
        i += 1;

        const union_info = @typeInfo(OpCode).Union;
        const opcode: union_info.tag_type.? = @enumFromInt(opcode_byte);

        inline for (union_info.fields) |field| {
            if (opcode == @field(union_info.tag_type.?, field.name)) {
                const operands = try read_operands(field.type, bytes, &i);
                const instruction = @unionInit(OpCode, field.name, operands);
                try instructions.append(instruction);
                // std.debug.print("{any}\n", .{instruction});
            }
        }
    }

    return instructions.toOwnedSlice();
}

fn format_struct(comptime T: type, ptr: anytype, writer: anytype) !void {
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
        try writer.print(".{s} = {any}", .{ field.name, field_value });
    }
    try writer.print("}}", .{});
}
