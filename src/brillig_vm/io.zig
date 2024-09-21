const std = @import("std");
const bincode = @import("./bincode.zig");
const Bn254Fr = @import("../bn254/fr.zig").Fr;

// const Circuit = struct {
//     current_witness_index: u32,
//     opcodes: []Opcodes,
// };

const MemoryAddress = u64;

const HeapArray = struct {
    pointer: MemoryAddress,
    size: u64,
};

const HeapVector = struct {
    pointer: MemoryAddress,
    size: MemoryAddress,
};

const BinaryFieldOp = enum {
    Add,
    Sub,
    Mul,
    Div,
    IntegerDiv,
    Equals,
    LessThan,
    LessThanEquals,
};

const BinaryIntOp = enum {
    Add,
    Sub,
    Mul,
    Div,
    Equals,
    LessThan,
    LessThanEquals,
    And,
    Or,
    Xor,
    Shl,
    Shr,
};

pub const IntegerBitSize = enum {
    U0,
    U1,
    U8,
    U16,
    U32,
    U64,
    U128,
};

pub const BitSize = union(enum) {
    Field,
    Integer: IntegerBitSize,
};

const Label = u64;

const HeapValueType = union(enum) {
    Simple: BitSize,
    Array: struct {
        value_types: []HeapValueType,
        size: u64,
    },
    Vector: struct {
        value_types: []HeapValueType,
    },
};

const ValueOrArray = union(enum) {
    MemoryAddress: MemoryAddress,
    HeapArray: HeapArray,
    HeapVector: HeapVector,
};

const Meta = struct {
    field: []const u8,
    src_type: type,
};

const BlackBoxOp = union(enum) {
    AES128Encrypt: struct {
        inputs: HeapVector,
        iv: HeapArray,
        key: HeapArray,
        outputs: HeapVector,
    },
    Sha256: struct {
        message: HeapVector,
        output: HeapArray,
    },
    Blake2s: struct {
        message: HeapVector,
        output: HeapArray,
    },
    Blake3: struct {
        message: HeapVector,
        output: HeapArray,
    },
    Keccak256: struct {
        message: HeapVector,
        output: HeapArray,
    },
    Keccakf1600: struct {
        message: HeapVector,
        output: HeapArray,
    },
    EcdsaSecp256k1: struct {
        hashed_msg: HeapVector,
        public_key_x: HeapArray,
        public_key_y: HeapArray,
        signature: HeapArray,
        result: MemoryAddress,
    },
    EcdsaSecp256r1: struct {
        hashed_msg: HeapVector,
        public_key_x: HeapArray,
        public_key_y: HeapArray,
        signature: HeapArray,
        result: MemoryAddress,
    },
    SchnorrVerify: struct {
        public_key_x: MemoryAddress,
        public_key_y: MemoryAddress,
        message: HeapVector,
        signature: HeapVector,
        result: MemoryAddress,
    },
    PedersenCommitment: struct {
        inputs: HeapVector,
        domain_separator: MemoryAddress,
        output: HeapArray,
    },
    PedersenHash: struct {
        inputs: HeapVector,
        domain_separator: MemoryAddress,
        output: MemoryAddress,
    },
    MultiScalarMul: struct {
        points: HeapVector,
        scalars: HeapVector,
        outputs: HeapArray,
    },
    EmbeddedCurveAdd: struct {
        input1_x: MemoryAddress,
        input1_y: MemoryAddress,
        input1_infinite: MemoryAddress,
        input2_x: MemoryAddress,
        input2_y: MemoryAddress,
        input2_infinite: MemoryAddress,
        result: HeapArray,
    },
    BigIntAdd: struct {
        lhs: MemoryAddress,
        rhs: MemoryAddress,
        output: MemoryAddress,
    },
    BigIntSub: struct {
        lhs: MemoryAddress,
        rhs: MemoryAddress,
        output: MemoryAddress,
    },
    BigIntMul: struct {
        lhs: MemoryAddress,
        rhs: MemoryAddress,
        output: MemoryAddress,
    },
    BigIntDiv: struct {
        lhs: MemoryAddress,
        rhs: MemoryAddress,
        output: MemoryAddress,
    },
    BigIntFromLeBytes: struct {
        inputs: HeapVector,
        modulus: HeapVector,
        output: MemoryAddress,
    },
    BigIntToLeBytes: struct {
        input: MemoryAddress,
        output: HeapVector,
    },
    Poseidon2Permutation: struct {
        message: HeapVector,
        output: HeapArray,
        len: MemoryAddress,
    },
    Sha256Compression: struct {
        input: HeapVector,
        hash_values: HeapVector,
        output: HeapArray,
    },
    ToRadix: struct {
        input: MemoryAddress,
        radix: MemoryAddress,
        output: HeapArray,
        output_bits: bool,
    },
};

pub const BrilligOpcode = union(enum) {
    BinaryFieldOp: struct {
        destination: MemoryAddress,
        op: BinaryFieldOp,
        lhs: MemoryAddress,
        rhs: MemoryAddress,
    },
    BinaryIntOp: struct {
        destination: MemoryAddress,
        op: BinaryIntOp,
        bit_size: IntegerBitSize,
        lhs: MemoryAddress,
        rhs: MemoryAddress,
    },
    Not: struct {
        destination: MemoryAddress,
        source: MemoryAddress,
        bit_size: IntegerBitSize,
    },
    Cast: struct {
        destination: MemoryAddress,
        source: MemoryAddress,
        bit_size: BitSize,
    },
    JumpIfNot: struct {
        condition: MemoryAddress,
        location: Label,
    },
    JumpIf: struct {
        condition: MemoryAddress,
        location: Label,
    },
    Jump: struct {
        location: Label,
    },
    CalldataCopy: struct {
        destination_address: MemoryAddress,
        size_address: MemoryAddress,
        offset_address: MemoryAddress,
    },
    Call: struct {
        location: Label,
    },
    Const: struct {
        pub const meta = [_]Meta{
            .{ .field = "value", .src_type = []const u8 },
        };
        destination: MemoryAddress,
        bit_size: BitSize,
        value: u256,
    },
    IndirectConst: struct {
        pub const meta = [_]Meta{
            .{ .field = "value", .src_type = []const u8 },
        };
        destination_pointer: MemoryAddress,
        bit_size: BitSize,
        value: u256,
    },
    Return: void,
    ForeignCall: struct {
        function: []const u8,
        destinations: []ValueOrArray,
        destination_value_types: []HeapValueType,
        inputs: []ValueOrArray,
        input_value_types: []HeapValueType,
    },
    Mov: struct {
        destination: MemoryAddress,
        source: MemoryAddress,
    },
    ConditionalMov: struct {
        destination: MemoryAddress,
        source_a: MemoryAddress,
        source_b: MemoryAddress,
        condition: MemoryAddress,
    },
    Load: struct {
        destination: MemoryAddress,
        source_pointer: MemoryAddress,
    },
    Store: struct {
        destination_pointer: MemoryAddress,
        source: MemoryAddress,
    },
    BlackBox: BlackBoxOp,
    Trap: struct {
        revert_data: HeapArray,
    },
    Stop: struct {
        return_data_offset: u64,
        return_data_size: u64,
    },
};

pub fn deserializeOpcodes(allocator: std.mem.Allocator, bytes: []const u8) ![]BrilligOpcode {
    var reader = std.io.fixedBufferStream(bytes);
    return bincode.deserializeAlloc(&reader.reader(), allocator, []BrilligOpcode) catch |err| {
        std.debug.print("Error deserializing: {}\n", .{err});
        return err;
    };
}

test "deserialize" {
    const serialized_data = @embedFile("bytecode");

    const result = deserializeOpcodes(serialized_data[0x36a..]) catch {
        std.debug.print("Deserialization failed\n", .{});
        return;
    };

    if (result.len == 0) {
        return;
    }

    for (result) |elem| {
        std.debug.print("Deserialized opcode: {any}\n", .{elem});
    }

    try std.testing.expectEqual(47, result.len);
}
