const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const BrilligOpcode = @import("../bvm/io.zig").BrilligOpcode;
const bincode = @import("../bincode/bincode.zig");
const formatOpcode = @import("../bvm/io.zig").formatOpcode;
const formatStruct = @import("../bvm/io.zig").formatStruct;
const formatUnionBody = @import("../bvm/io.zig").formatUnionBody;

const BrilligBytecode = []BrilligOpcode;

pub const Program = struct {
    functions: []Circuit,
    unconstrained_functions: []BrilligBytecode,
};

pub const Circuit = struct {
    // current_witness_index is the highest witness index in the circuit. The next witness to be added to this circuit
    // will take on this value. (The value is cached here as an optimization.)
    current_witness_index: u32,
    opcodes: []Opcode,
    expression_width: ExpressionWidth,

    /// The set of private inputs to the circuit.
    private_parameters: []Witness,
    // ACIR distinguishes between the public inputs which are provided externally or calculated within the circuit and returned.
    // The elements of these sets may not be mutually exclusive, i.e. a parameter may be returned from the circuit.
    // All public inputs (parameters and return values) must be provided to the verifier at verification time.
    /// The set of public inputs provided by the prover.
    public_parameters: []Witness,
    /// The set of public inputs calculated within the circuit.
    return_values: []Witness,
    /// Maps opcode locations to failed assertion payloads.
    /// The data in the payload is embedded in the circuit to provide useful feedback to users
    /// when a constraint in the circuit is not satisfied.
    ///
    // Note: This should be a BTreeMap, but serde-reflect is creating invalid
    // c++ code at the moment when it is, due to OpcodeLocation needing a comparison
    // implementation which is never generated.
    assert_messages: []struct { loc: OpcodeLocation, payload: AssertionPayload },

    /// States whether the backend should use a SNARK recursion friendly prover.
    /// If implemented by a backend, this means that proofs generated with this circuit
    /// will be friendly for recursively verifying inside of another SNARK.
    recursive: bool,
};

pub const Witness = u32;
const BlockId = u32;
const BrilligFunctionId = u32;
const AcirFunctionId = u32;
pub const WitnessEntry = struct {
    pub const meta = [_]bincode.Meta{
        .{ .field = "value", .src_type = []const u8 },
    };
    index: u32,
    value: u256,
};
pub const StackItem = struct {
    index: u32,
    witnesses: []WitnessEntry,
};

pub const LinearCombination = struct {
    pub const meta = [_]bincode.Meta{
        .{ .field = "q_l", .src_type = []const u8 },
    };
    q_l: Fr,
    w_l: Witness,

    pub fn format(self: LinearCombination, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try formatStruct(self, writer);
    }
};

pub const MulTerm = struct {
    pub const meta = [_]bincode.Meta{
        .{ .field = "q_m", .src_type = []const u8 },
    };
    q_m: Fr,
    w_l: Witness,
    w_r: Witness,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try formatStruct(self, writer);
    }
};

pub const Expression = struct {
    pub const meta = [_]bincode.Meta{
        .{ .field = "q_c", .src_type = []const u8 },
    };

    // To avoid having to create intermediate variables pre-optimization
    // We collect all of the multiplication terms in the assert-zero opcode
    // A multiplication term is of the form q_M * wL * wR
    // Hence this vector represents the following sum: q_M1 * wL1 * wR1 + q_M2 * wL2 * wR2 + .. +
    mul_terms: []MulTerm,

    linear_combinations: []LinearCombination,

    // Constant term.
    q_c: Fr,

    pub fn fromConst(value: Fr) Expression {
        return .{ .q_c = value, .linear_combinations = &.{}, .mul_terms = &.{} };
    }

    pub fn fromWitness(allocator: std.mem.Allocator, witness: Witness) Expression {
        const lc = allocator.alloc(LinearCombination, 1) catch unreachable;
        lc[0] = .{ .q_l = Fr.one, .w_l = witness };
        return .{ .q_c = Fr.zero, .linear_combinations = lc, .mul_terms = &.{} };
    }

    pub fn toWitness(self: *const Expression) ?Witness {
        if (self.isDegreeOneUnivariate()) {
            const term = self.linear_combinations[0];
            if (term.q_l.eql(Fr.one) and self.q_c.is_zero()) {
                return term.w_l;
            }
        }
        return null;
    }

    pub fn isConst(self: *const Expression) bool {
        return self.mul_terms.len == 0 and self.linear_combinations.len == 0;
    }

    pub fn toConst(self: *const Expression) ?Fr {
        return if (self.isConst()) self.q_c else null;
    }

    /// Returns `true` if highest degree term in the expression is one or less.
    ///
    /// - `mul_term` in an expression contains degree-2 terms
    /// - `linear_combinations` contains degree-1 terms
    /// Hence, it is sufficient to check that there are no `mul_terms`
    ///
    /// Examples:
    /// -  f(x,y) = x + y would return true
    /// -  f(x,y) = xy would return false, the degree here is 2
    /// -  f(x,y) = 0 would return true, the degree is 0
    pub fn isLinear(self: *const Expression) bool {
        return self.mul_terms.len == 0;
    }

    /// Returns `true` if the expression can be seen as a degree-1 univariate polynomial
    ///
    /// - `mul_terms` in an expression can be univariate, however unless the coefficient
    /// is zero, it is always degree-2.
    /// - `linear_combinations` contains the sum of degree-1 terms, these terms do not
    /// need to contain the same variable and so it can be multivariate. However, we
    /// have thus far only checked if `linear_combinations` contains one term, so this
    /// method will return false, if the `Expression` has not been simplified.
    ///
    /// Hence, we check in the simplest case if an expression is a degree-1 univariate,
    /// by checking if it contains no `mul_terms` and it contains one `linear_combination` term.
    ///
    /// Examples:
    /// - f(x,y) = x would return true
    /// - f(x,y) = x + 6 would return true
    /// - f(x,y) = 2*y + 6 would return true
    /// - f(x,y) = x + y would return false
    /// - f(x,y) = x + x should return true, but we return false *** (we do not simplify)
    /// - f(x,y) = 5 would return false
    pub fn isDegreeOneUnivariate(self: *const Expression) bool {
        return self.isLinear() and self.linear_combinations.len == 1;
    }

    pub fn format(self: *const Expression, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        // try formatStruct(self, writer);
        try writer.print("{{", .{});
        if (self.mul_terms.len > 0) {
            try writer.print(" .mt = {any}", .{self.mul_terms});
        }
        if (self.linear_combinations.len > 0) {
            try writer.print(" .lc = {any}", .{self.linear_combinations});
        }
        if (!self.q_c.is_zero()) {
            try writer.print(" .qc = {short}", .{self.q_c});
        }
        try writer.print(" }}", .{});
    }
};

const ExpressionWidth = union(enum) {
    Unbounded,
    Bounded: u64,
};

pub const MemOp = struct {
    /// A constant expression that can be 0 (read) or 1 (write)
    operation: Expression,
    /// array index, it must be less than the array length
    index: Expression,
    /// the value we are reading, when operation is 0, or the value we write at
    /// the specified index, when operation is 1
    value: Expression,
    pub fn readAtMemIndex(allocator: std.mem.Allocator, index: Fr, witness: Witness) MemOp {
        return MemOp{
            .operation = Expression.fromConst(Fr.zero),
            .index = Expression.fromConst(index),
            .value = Expression.fromWitness(allocator, witness),
        };
    }

    pub fn writeToMemIndex(index: Fr, value: Expression) MemOp {
        return MemOp{
            .operation = Expression.fromConst(Fr.one),
            .index = Expression.fromConst(index),
            .value = value,
        };
    }
};

const OpcodeLocation = union(enum) {
    Acir: u64,
    // TODO(https://github.com/noir-lang/noir/issues/5792): We can not get rid of this enum field entirely just yet as this format is still
    // used for resolving assert messages which is a breaking serialization change.
    Brillig: struct { acir_index: u64, brillig_index: u64 },
};

const ExpressionOrMemory = union(enum) {
    Expression: Expression,
    Memory: BlockId,
};

const AssertionPayload = union(enum) {
    StaticString: []u8,
    Dynamic: struct { error_selector: u64, x: []ExpressionOrMemory },
};

const BrilligInputs = union(enum) {
    Single: Expression,
    Array: []Expression,
    MemoryArray: BlockId,

    pub fn format(self: BrilligInputs, comptime str: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try formatUnionBody(self, str, options, writer);
    }
};

const BrilligOutputs = union(enum) {
    Simple: Witness,
    Array: []Witness,

    pub fn format(self: BrilligOutputs, comptime str: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try formatUnionBody(self, str, options, writer);
    }
};

const BlockType = union(enum) {
    Memory,
    CallData: u32,
    ReturnData,
};

pub const Opcode = union(enum) {
    /// An `AssertZero` opcode adds the constraint that `P(w) = 0`, where
    /// `w=(w_1,..w_n)` is a tuple of `n` witnesses, and `P` is a multi-variate
    /// polynomial of total degree at most `2`.
    ///
    /// The coefficients `{q_M}_{i,j}, q_i,q_c` of the polynomial are known
    /// values which define the opcode.
    ///
    /// A general expression of assert-zero opcode is the following:
    /// ```text
    /// \sum_{i,j} {q_M}_{i,j}w_iw_j + \sum_i q_iw_i +q_c = 0
    /// ```
    ///
    /// An assert-zero opcode can be used to:
    /// - **express a constraint** on witnesses; for instance to express that a
    ///   witness `w` is a boolean, you can add the opcode: `w*w-w=0`
    /// - or, to **compute the value** of an arithmetic operation of some inputs.
    /// For instance, to multiply two witnesses `x` and `y`, you would use the
    /// opcode `z-x*y=0`, which would constrain `z` to be `x*y`.
    ///
    /// The solver expects that at most one witness is not known when executing the opcode.
    AssertZero: Expression,

    /// Calls to "gadgets" which rely on backends implementing support for
    /// specialized constraints.
    ///
    /// Often used for exposing more efficient implementations of
    /// SNARK-unfriendly computations.
    ///
    /// All black box functions take as input a tuple `(witness, num_bits)`,
    /// where `num_bits` is a constant representing the bit size of the input
    /// witness, and they have one or several witnesses as output.
    ///
    /// Some more advanced computations assume that the proving system has an
    /// 'embedded curve'. It is a curve that cycles with the main curve of the
    /// proving system, i.e the scalar field of the embedded curve is the base
    /// field of the main one, and vice-versa.
    ///
    /// Aztec's Barretenberg uses BN254 as the main curve and Grumpkin as the
    /// embedded curve.
    BlackBoxOp: BlackBoxOp,

    /// This opcode is a specialization of a Brillig opcode. Instead of having
    /// some generic assembly code like Brillig, a directive has a hardcoded
    /// name which tells the solver which computation to do: with Brillig, the
    /// computation refers to the compiled bytecode of an unconstrained Noir
    /// function, but with a directive, the computation is hardcoded inside the
    /// compiler.
    ///
    /// Directives will be replaced by Brillig opcodes in the future.
    Directive: Directive,

    /// Atomic operation on a block of memory
    ///
    /// ACIR is able to address any array of witnesses. Each array is assigned
    /// an id (BlockId) and needs to be initialized with the MemoryInit opcode.
    /// Then it is possible to read and write from/to an array by providing the
    /// index and the value we read/write as arithmetic expressions. Note that
    /// ACIR arrays all have a known fixed length (given in the MemoryInit
    /// opcode below)
    ///
    /// - predicate: an arithmetic expression that disables the execution of the
    ///   opcode when the expression evaluates to zero
    MemoryOp: struct {
        /// identifier of the array
        block_id: BlockId,
        /// describe the memory operation to perform
        op: MemOp,
        /// Predicate of the memory operation - indicates if it should be skipped
        predicate: ?Expression,
    },

    /// Initialize an ACIR array from a vector of witnesses.
    /// - block_id: identifier of the array
    /// - init: Vector of witnesses specifying the initial value of the array
    ///
    /// There must be only one MemoryInit per block_id, and MemoryOp opcodes must
    /// come after the MemoryInit.
    MemoryInit: struct { block_id: BlockId, init: []Witness, block_type: BlockType },

    /// Calls to unconstrained functions
    BrilligCall: struct {
        /// Id for the function being called. It is the responsibility of the executor
        /// to fetch the appropriate Brillig bytecode from this id.
        id: BrilligFunctionId,
        /// Inputs to the function call
        inputs: []BrilligInputs,
        /// Outputs to the function call
        outputs: []BrilligOutputs,
        /// Predicate of the Brillig execution - indicates if it should be skipped
        predicate: ?Expression,
    },

    /// Calls to functions represented as a separate circuit. A call opcode allows us
    /// to build a call stack when executing the outer-most circuit.
    Call: struct {
        /// Id for the function being called. It is the responsibility of the executor
        /// to fetch the appropriate circuit from this id.
        id: AcirFunctionId,
        /// Inputs to the function call
        inputs: []Witness,
        /// Outputs of the function call
        outputs: []Witness,
        /// Predicate of the circuit execution - indicates if it should be skipped
        predicate: ?Expression,
    },

    pub fn format(self: Opcode, comptime str: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try formatOpcode(self, str, options, writer);
    }
};

const Directive = union(enum) {
    //decomposition of a: a=\sum b[i]*radix^i where b is an array of witnesses < radix in little endian form
    ToLeRadix: struct { a: Expression, b: []Witness, radix: u32 },

    pub fn format(self: Directive, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} ", .{@tagName(self)});
        inline for (@typeInfo(@TypeOf(self)).Union.fields) |field| {
            if (self == @field(@TypeOf(self), field.name)) {
                try formatStruct(@field(self, field.name), writer);
            }
        }
    }
};

const Constant = struct {
    pub const meta = [_]bincode.Meta{
        .{ .field = "value", .src_type = []const u8 },
    };
    value: Fr,
};

const ConstantOrWitnessEnum = union(enum) {
    Constant: Constant,
    Witness: Witness,

    pub fn format(self: ConstantOrWitnessEnum, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .Constant => |i| try writer.print("{s}", .{i.value}),
            .Witness => |w| try writer.print("{}>", .{w}),
        }
    }
};

pub const FunctionInput = struct {
    input: ConstantOrWitnessEnum,
    num_bits: u32,

    pub fn format(self: FunctionInput, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({}){}", .{ self.num_bits, self.input });
    }
};

const BlackBoxOp = union(enum) {
    AES128Encrypt: struct {
        inputs: []FunctionInput,
        iv: [16]FunctionInput,
        key: [16]FunctionInput,
        outputs: []Witness,
    },
    AND: struct {
        lhs: FunctionInput,
        rhs: FunctionInput,
        output: Witness,
    },
    XOR: struct {
        lhs: FunctionInput,
        rhs: FunctionInput,
        output: Witness,
    },
    RANGE: struct {
        input: FunctionInput,
    },
    Blake2s: struct {
        inputs: []FunctionInput,
        outputs: [32]Witness,
    },
    Blake3: struct {
        inputs: []FunctionInput,
        outputs: [32]Witness,
    },
    SchnorrVerify: struct {
        public_key_x: FunctionInput,
        public_key_y: FunctionInput,
        signature: [64]FunctionInput,
        message: []FunctionInput,
        output: Witness,
    },
    EcdsaSecp256k1: struct {
        public_key_x: [32]FunctionInput,
        public_key_y: [32]FunctionInput,
        signature: [64]FunctionInput,
        hashed_message: [32]FunctionInput,
        output: Witness,
    },
    EcdsaSecp256r1: struct {
        public_key_x: [32]FunctionInput,
        public_key_y: [32]FunctionInput,
        signature: [64]FunctionInput,
        hashed_message: [32]FunctionInput,
        output: Witness,
    },
    MultiScalarMul: struct {
        points: []FunctionInput,
        scalars: []FunctionInput,
        outputs: struct { x: Witness, y: Witness, i: Witness },
    },
    EmbeddedCurveAdd: struct {
        input1: [3]FunctionInput,
        input2: [3]FunctionInput,
        outputs: struct { x: Witness, y: Witness, i: Witness },
    },
    Keccakf1600: struct {
        inputs: [25]FunctionInput,
        outputs: [25]Witness,
    },
    RecursiveAggregation: struct {
        verification_key: []FunctionInput,
        proof: []FunctionInput,
        /// These represent the public inputs of the proof we are verifying
        /// They should be checked against in the circuit after construction
        /// of a new aggregation state
        public_inputs: []FunctionInput,
        /// A key hash is used to check the validity of the verification key.
        /// The circuit implementing this opcode can use this hash to ensure that the
        /// key provided to the circuit matches the key produced by the circuit creator
        key_hash: FunctionInput,
        proof_type: u32,
    },
    BigIntAdd: struct {
        lhs: u32,
        rhs: u32,
        output: u32,
    },
    BigIntSub: struct {
        lhs: u32,
        rhs: u32,
        output: u32,
    },
    BigIntMul: struct {
        lhs: u32,
        rhs: u32,
        output: u32,
    },
    BigIntDiv: struct {
        lhs: u32,
        rhs: u32,
        output: u32,
    },
    BigIntFromLeBytes: struct {
        inputs: []FunctionInput,
        modulus: []u8,
        output: u32,
    },
    BigIntToLeBytes: struct {
        input: u32,
        outputs: []Witness,
    },
    Poseidon2Permutation: struct {
        /// Input state for the permutation of Poseidon2
        inputs: []FunctionInput,
        /// Permuted state
        outputs: []Witness,
        /// State length (length of input/output slices).
        len: u32,
    },
    Sha256Compression: struct {
        /// 512 bits of the input message, represented by 16 u32s.
        inputs: [16]FunctionInput,
        /// Vector of 8 u32s used to compress the input.
        hash_values: [8]FunctionInput,
        /// Output of the compression, represented by 8 u32s.
        outputs: [8]Witness,
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

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Program {
    var reader = std.io.fixedBufferStream(bytes);
    return bincode.deserializeAlloc(&reader.reader(), allocator, Program) catch |err| {
        std.debug.print("Error deserializing at: 0x{x}\n", .{try reader.getPos()});
        return err;
    };
}

pub fn load(allocator: std.mem.Allocator, file_path: ?[]const u8) !Program {
    var serialized_data: []u8 = undefined;
    if (file_path) |p| {
        const file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        serialized_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    } else {
        const stdin = std.io.getStdIn();
        serialized_data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    }

    return try deserialize(allocator, serialized_data);
}
