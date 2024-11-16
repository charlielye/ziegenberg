const std = @import("std");
const bincode = @import("../bincode/bincode.zig");
const Fr = @import("../bn254/fr.zig").Fr;

pub const MemoryAddress = struct {
    relative: u32,
    value: u64,

    pub fn format(self: MemoryAddress, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}{}", .{ if (self.relative == 1) "+" else "", self.value });
    }

    pub inline fn resolve(self: MemoryAddress, mem: []u256) usize {
        if (self.relative == 1) {
            return @as(usize, @truncate(mem[0] + self.value));
        } else {
            return @truncate(self.value);
        }
    }
};

const HeapArray = struct {
    pointer: MemoryAddress,
    size: u64,

    pub fn format(self: HeapArray, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("HeapArray ", .{});
        try formatStruct(self, writer);
    }
};

const HeapVector = struct {
    pointer: MemoryAddress,
    size: MemoryAddress,

    pub fn format(self: HeapVector, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("HeapVector ", .{});
        try formatStruct(self, writer);
    }
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

    pub fn format(self: BinaryFieldOp, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{@tagName(self)});
    }
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

    pub fn format(self: BinaryIntOp, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{@tagName(self)});
    }
};

pub const IntegerBitSize = enum {
    U1,
    U8,
    U16,
    U32,
    U64,
    U128,

    pub fn format(self: IntegerBitSize, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{@tagName(self)});
    }
};

pub const BitSize = union(enum) {
    Field,
    Integer: IntegerBitSize,

    pub fn format(self: BitSize, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .Integer => |i| try writer.print("{s}", .{i}),
            .Field => try writer.print("Field", .{}),
        }
    }
};

const Label = u64;

pub const HeapValueType = union(enum) {
    Simple: BitSize,
    Array: struct {
        value_types: []HeapValueType,
        size: u64,
    },
    Vector: struct {
        value_types: []HeapValueType,
    },

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try formatUnionBody(self, fmt, options, writer);
    }
};

pub const ValueOrArray = union(enum) {
    MemoryAddress: MemoryAddress,
    HeapArray: HeapArray,
    HeapVector: HeapVector,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try formatUnionBody(self, fmt, options, writer);
    }
};

pub const BlackBoxOp = union(enum) {
    AES128Encrypt: struct {
        inputs: HeapVector,
        iv: HeapArray,
        key: HeapArray,
        outputs: HeapVector,
    },
    Blake2s: struct {
        message: HeapVector,
        output: HeapArray,
    },
    Blake3: struct {
        message: HeapVector,
        output: HeapArray,
    },
    Keccakf1600: struct {
        message: HeapArray,
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
        input: HeapArray,
        hash_values: HeapArray,
        output: HeapArray,
    },
    ToRadix: struct {
        input: MemoryAddress,
        radix: MemoryAddress,
        output: HeapArray,
        output_bits: bool,
    },

    pub fn format(self: BlackBoxOp, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} ", .{@tagName(self)});
        inline for (@typeInfo(BlackBoxOp).Union.fields) |field| {
            if (self == @field(BlackBoxOp, field.name)) {
                try formatStruct(@field(self, field.name), writer);
            }
        }
    }
};

pub const ForeignCall = struct {
    function: []const u8,
    destinations: []ValueOrArray,
    destination_value_types: []HeapValueType,
    inputs: []ValueOrArray,
    input_value_types: []HeapValueType,
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
        pub const meta = [_]bincode.Meta{
            .{ .field = "value", .src_type = []const u8 },
        };
        destination: MemoryAddress,
        bit_size: BitSize,
        value: u256,
    },
    IndirectConst: struct {
        pub const meta = [_]bincode.Meta{
            .{ .field = "value", .src_type = []const u8 },
        };
        destination_pointer: MemoryAddress,
        bit_size: BitSize,
        value: u256,
    },
    Return: void,
    ForeignCall: ForeignCall,
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
        revert_data: HeapVector,
    },
    Stop: struct {
        return_data: HeapVector,
    },

    pub fn format(self: BrilligOpcode, comptime str: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try formatOpcode(self, str, options, writer);
    }
};

pub fn formatOpcode(self: anytype, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    try writer.print("{s: >16} ", .{@tagName(self)});
    try formatUnionBody(self, "", .{}, writer);
}

pub fn formatUnionBody(self: anytype, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    inline for (@typeInfo(@TypeOf(self)).Union.fields) |field| {
        if (self == @field(@TypeOf(self), field.name)) {
            const field_ptr = @field(self, field.name);
            switch (@typeInfo(field.type)) {
                .Void => return,
                .Struct => {
                    if (!@hasDecl(field.type, "format")) {
                        try formatStruct(field_ptr, writer);
                    } else {
                        try writer.print("{}", .{field_ptr});
                    }
                },
                .Union => {
                    if (!@hasDecl(field.type, "format")) {
                        try formatUnionBody(field_ptr, "", {}, writer);
                    } else {
                        try writer.print("{}", .{field_ptr});
                    }
                },
                else => try writer.print("{any}", .{field_ptr}),
            }
        }
    }
}

fn every(comptime T: type, input: []const T, comptime f: fn (T) bool) bool {
    for (input) |e| if (!f(e)) return false;
    return true;
}

pub fn formatStruct(ptr: anytype, writer: anytype) !void {
    try writer.print("{{", .{});
    inline for (@typeInfo(@TypeOf(ptr)).Struct.fields) |field| {
        if (field.type == Fr) {
            try writer.print(" .{s} = {short}", .{ field.name, @field(ptr, field.name) });
        } else if (field.type == []const u8 and every(u8, @field(ptr, field.name), std.ascii.isPrint)) {
            try writer.print(" .{s} = '{s}'", .{ field.name, @field(ptr, field.name) });
        } else {
            try writer.print(" .{s} = {any}", .{ field.name, @field(ptr, field.name) });
        }
    }
    try writer.print(" }}", .{});
}

pub fn deserializeOpcodes(allocator: std.mem.Allocator, bytes: []const u8) ![]BrilligOpcode {
    var reader = std.io.fixedBufferStream(bytes);
    return bincode.deserializeAlloc(&reader.reader(), allocator, []BrilligOpcode) catch |err| {
        std.debug.print("Error deserializing: {}\n", .{err});
        return err;
    };
}

pub fn load(allocator: std.mem.Allocator, file_path: ?[]const u8) ![]BrilligOpcode {
    var serialized_data: []u8 = undefined;
    if (file_path) |p| {
        const file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        serialized_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    } else {
        const stdin = std.io.getStdIn();
        serialized_data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    }

    // Temp hack to locate start of brillig.
    // Assume first opcode is always the same.
    // const find: [32]u8 = @bitCast(@byteSwap(@as(u256, 0x0900000002000000000000000100000003000000400000000000000030303030)));
    const find: [32]u8 = @bitCast(@byteSwap(@as(u256, 0x0900000000000000020000000000000001000000030000004000000000000000)));
    const start = std.mem.indexOf(u8, serialized_data, find[0..]) orelse return error.FirstOpcodeNotFound;
    // std.debug.print("First opcode found at: {x}\n", .{start});

    // Jump back 8 bytes to include the opcode count.
    return try deserializeOpcodes(allocator, serialized_data[start - 8 ..]);
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
