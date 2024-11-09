const std = @import("std");
const F = @import("../bn254/fr.zig").Fr;
const io = @import("./io.zig");
const WitnessMap = @import("./witness_map.zig").WitnessMap;
const evaluate = @import("./expression_solver.zig").evaluate;

const Witness = io.Witness;
const Expression = io.Expression;

const MemoryIndex = u32;

pub const OpcodeResolutionError = error{
    IndexOutOfBounds,
    UnsatisfiedConstraint,
    ExpectedWitness,
    UnsolvedWitness,
};

pub const MemoryOpSolver = struct {
    allocator: std.mem.Allocator,
    block_value: std.AutoHashMap(MemoryIndex, F),
    block_len: u32,

    pub fn init(allocator: std.mem.Allocator) MemoryOpSolver {
        return MemoryOpSolver{
            .allocator = allocator,
            .block_value = std.AutoHashMap(MemoryIndex, F).init(allocator),
            .block_len = 0,
        };
    }

    pub fn deinit(self: *MemoryOpSolver) void {
        self.block_value.deinit();
    }

    pub fn writeMemoryIndex(self: *MemoryOpSolver, index: MemoryIndex, value: F) !void {
        if (index >= self.block_len) {
            return OpcodeResolutionError.IndexOutOfBounds;
        }
        try self.block_value.put(index, value);
    }

    pub fn readMemoryIndex(self: *MemoryOpSolver, index: MemoryIndex) !F {
        return self.block_value.get(index) orelse OpcodeResolutionError.IndexOutOfBounds;
    }

    pub fn initMemory(self: *MemoryOpSolver, init_witnesses: []const Witness, initial_witness: *WitnessMap) !void {
        self.block_len = @intCast(init_witnesses.len);

        for (init_witnesses, 0..) |witness, i| {
            const value = initial_witness.get(witness) orelse return error.WitnessNotFound;
            try self.writeMemoryIndex(@intCast(i), value);
        }
    }

    pub fn solveMemoryOp(
        self: *MemoryOpSolver,
        op: *const io.MemOp,
        initial_witness: *WitnessMap,
        predicate: ?*const Expression,
    ) !void {
        const operation = try self.getValue(&op.operation, initial_witness);

        // Find the memory index associated with this memory operation.
        const index_value = try self.getValue(&op.index, initial_witness);
        const memory_index: MemoryIndex = @intCast(index_value.to_int());

        // Calculate the value associated with this memory operation.
        // In read operations, this corresponds to the witness index at which the value from memory will be written.
        // In write operations, this corresponds to the expression which will be written to memory.
        const value = evaluate(self.allocator, &op.value, initial_witness);

        // `operation == 0` implies a read operation. (`operation == 1` implies write operation).
        const is_read_operation = operation.is_zero();

        // Fetch whether or not the predicate is false (e.g. equal to zero)
        const skip_operation = if (predicate) |p| (try self.getValue(p, initial_witness)).is_zero() else false;

        if (is_read_operation) {
            // `value_read = arr[memory_index]`
            // This is the value that we want to read into; i.e. copy from the memory block into this value.
            const value_read_witness = value.toWitness() orelse return OpcodeResolutionError.ExpectedWitness;
            const value_in_array = if (skip_operation) F.zero else try self.readMemoryIndex(memory_index);
            try initial_witness.put(value_read_witness, value_in_array);
        } else {
            if (skip_operation) {
                return;
            } else {
                // `arr[memory_index] = value_write`
                // This is the value that we want to write into; i.e. copy from `value_write` into the memory block.
                const value_to_write = try self.getValue(&value, initial_witness);
                try self.writeMemoryIndex(memory_index, value_to_write);
            }
        }
    }

    fn getValue(self: *MemoryOpSolver, expr: *const Expression, initial_witness: *WitnessMap) !F {
        return evaluate(self.allocator, expr, initial_witness).toConst() orelse return error.OpcodeNotSolvable;
    }
};

test "memory op solver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var initial_witness = WitnessMap.init(allocator);
    defer initial_witness.deinit();

    try initial_witness.put(1, F.one);
    try initial_witness.put(2, F.one);
    try initial_witness.put(3, F.from_int(2));

    const init_witnesses = [_]Witness{ 1, 2 };

    var block_solver = MemoryOpSolver.init(allocator);
    defer block_solver.deinit();

    try block_solver.initMemory(init_witnesses[0..], &initial_witness);

    const write_op = io.MemOp.writeToMemIndex(F.one, Expression.fromWitness(allocator, 3));
    const read_op = io.MemOp.readAtMemIndex(allocator, F.one, 4);

    const trace = &[_]io.MemOp{ write_op, read_op };

    for (trace) |*op| {
        try block_solver.solveMemoryOp(op, &initial_witness, null);
    }

    const witness_4_value = initial_witness.get(4) orelse unreachable;
    try std.testing.expectEqual(F.from_int(2), witness_4_value);
}
