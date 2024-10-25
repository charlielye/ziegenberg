const std = @import("std");
const io = @import("./io.zig");
const F = @import("../bn254/fr.zig").Fr;

const Witness = io.Witness;
const Expression = io.Expression;
const WitnessMap = io.WitnessMap;
const MulTerm = io.MulTerm;
const LinearCombination = io.LinearCombination;

pub const ExpressionBuilder = struct {
    mul_terms: std.ArrayList(MulTerm),
    linear_combinations: std.ArrayList(LinearCombination),
    q_c: F,

    pub fn init(allocator: std.mem.Allocator) ExpressionBuilder {
        return ExpressionBuilder{
            .mul_terms = std.ArrayList(MulTerm).init(allocator),
            .linear_combinations = std.ArrayList(LinearCombination).init(allocator),
            .q_c = F.zero,
        };
    }

    pub fn deinit(self: *ExpressionBuilder) void {
        self.mul_terms.deinit();
        self.linear_combinations.deinit();
    }

    fn toExpression(self: *ExpressionBuilder) io.Expression {
        return .{
            .mul_terms = self.mul_terms.toOwnedSlice() catch unreachable,
            .linear_combinations = self.linear_combinations.toOwnedSlice() catch unreachable,
            .q_c = self.q_c,
        };
    }
};

const OpcodeStatus = union(enum) {
    OpcodeSatisfied: F,
    OpcodeSolvable: struct {
        sum: F,
        unknown_var: LinearCombination,
    },
    OpcodeUnsolvable: void,
};

const MulTermResult = union(enum) {
    OneUnknown: LinearCombination,
    TooManyUnknowns: void,
    Solved: F,
};

const OpcodeResolutionError = error{
    OpcodeNotSolvable,
    UnsatisfiedConstraint,
};

fn insert_value(witness: Witness, value: F, witness_assignments: *WitnessMap) !void {
    const r = try witness_assignments.getOrPut(witness);
    if (r.found_existing) {
        if (!r.value_ptr.eql(value)) {
            return OpcodeResolutionError.UnsatisfiedConstraint;
        }
    } else {
        r.value_ptr.* = value;
    }
}

pub fn solve(allocator: std.mem.Allocator, initial_witness: *WitnessMap, opcode: *const io.Expression) !void {
    var evaluated_opcode = evaluate(allocator, opcode, initial_witness);

    const mul_result = try solve_mul_term(&evaluated_opcode, initial_witness);

    const opcode_status = solve_fan_in_term(&evaluated_opcode, initial_witness);

    switch (mul_result) {
        MulTermResult.TooManyUnknowns => return OpcodeResolutionError.OpcodeNotSolvable,
        MulTermResult.OneUnknown => |one_unknown| {
            switch (opcode_status) {
                OpcodeStatus.OpcodeUnsolvable => return OpcodeResolutionError.OpcodeNotSolvable,
                OpcodeStatus.OpcodeSolvable => |solvable| {
                    if (one_unknown.w_l == solvable.unknown_var.w_l) {
                        const total_sum = solvable.sum.add(evaluated_opcode.q_c);
                        if (one_unknown.q_l.add(solvable.unknown_var.q_l).is_zero()) {
                            if (!total_sum.is_zero()) {
                                return OpcodeResolutionError.UnsatisfiedConstraint;
                            }
                            return;
                        } else {
                            const assignment = total_sum.neg().div(one_unknown.q_l.add(solvable.unknown_var.q_l));
                            try insert_value(one_unknown.w_l, assignment, initial_witness);
                        }
                    } else {
                        return OpcodeResolutionError.OpcodeNotSolvable;
                    }
                },
                OpcodeStatus.OpcodeSatisfied => |sum| {
                    const total_sum = sum.add(evaluated_opcode.q_c);
                    if (one_unknown.q_l.is_zero()) {
                        if (!total_sum.is_zero()) {
                            return OpcodeResolutionError.UnsatisfiedConstraint;
                        } else {
                            return;
                        }
                    } else {
                        const assignment = total_sum.neg().div(one_unknown.q_l);
                        try insert_value(one_unknown.w_l, assignment, initial_witness);
                    }
                },
            }
        },
        MulTermResult.Solved => |a| {
            switch (opcode_status) {
                OpcodeStatus.OpcodeSatisfied => |b| {
                    if (!a.add(b).add(evaluated_opcode.q_c).is_zero()) {
                        return OpcodeResolutionError.UnsatisfiedConstraint;
                    } else {
                        return;
                    }
                },
                OpcodeStatus.OpcodeSolvable => |solvable| {
                    const total_sum = a.add(solvable.sum).add(evaluated_opcode.q_c);
                    if (solvable.unknown_var.q_l.is_zero()) {
                        if (!total_sum.is_zero()) {
                            return OpcodeResolutionError.UnsatisfiedConstraint;
                        }
                        return;
                    } else {
                        const assignment = total_sum.neg().div(solvable.unknown_var.q_l);
                        try insert_value(solvable.unknown_var.w_l, assignment, initial_witness);
                    }
                },
                OpcodeStatus.OpcodeUnsolvable => return OpcodeResolutionError.OpcodeNotSolvable,
            }
        },
    }
}

// Partially evaluate the expression using the known witnesses.
pub fn evaluate(allocator: std.mem.Allocator, expr: *const Expression, initial_witness: *WitnessMap) Expression {
    var e = ExpressionBuilder.init(allocator);

    for (expr.mul_terms) |term| {
        const mul_result = solve_mul_term_helper(&term, initial_witness);
        switch (mul_result) {
            MulTermResult.OneUnknown => |one_unknown| {
                if (!one_unknown.q_l.is_zero()) {
                    e.linear_combinations.append(one_unknown) catch unreachable;
                }
            },
            MulTermResult.TooManyUnknowns => {
                if (!term.q_m.is_zero()) {
                    e.mul_terms.append(term) catch unreachable;
                }
            },
            MulTermResult.Solved => |f| {
                e.q_c = e.q_c.add(f);
            },
        }
    }

    for (expr.linear_combinations) |term| {
        if (solve_fan_in_term_helper(&term, initial_witness)) |f| {
            e.q_c = e.q_c.add(f);
        } else if (!term.q_l.is_zero()) {
            e.linear_combinations.append(term) catch unreachable;
        }
    }

    e.q_c = e.q_c.add(expr.q_c);

    return e.toExpression();
}

fn solve_mul_term(arith_opcode: *const Expression, witness_assignments: *WitnessMap) !MulTermResult {
    const mul_terms_len = arith_opcode.mul_terms.len;

    if (mul_terms_len == 0) {
        return MulTermResult{ .Solved = F.zero };
    } else if (mul_terms_len == 1) {
        return solve_mul_term_helper(&arith_opcode.mul_terms[0], witness_assignments);
    } else {
        return OpcodeResolutionError.OpcodeNotSolvable;
    }
}

fn solve_mul_term_helper(term: *const MulTerm, witness_assignments: *WitnessMap) MulTermResult {
    const q_m = term.q_m;
    const w_l = term.w_l;
    const w_r = term.w_r;

    const w_l_value = witness_assignments.get(w_l);
    const w_r_value = witness_assignments.get(w_r);

    if (w_l_value) |w_l_val| {
        if (w_r_value) |w_r_val| {
            return MulTermResult{ .Solved = q_m.mul(w_l_val).mul(w_r_val) };
        } else {
            return MulTermResult{ .OneUnknown = .{
                .q_l = q_m.mul(w_l_val),
                .w_l = w_r,
            } };
        }
    } else {
        if (w_r_value) |w_r_val| {
            return MulTermResult{ .OneUnknown = .{
                .q_l = q_m.mul(w_r_val),
                .w_l = w_l,
            } };
        } else {
            return MulTermResult.TooManyUnknowns;
        }
    }
}

fn solve_fan_in_term_helper(term: *const LinearCombination, witness_assignments: *WitnessMap) ?F {
    const q_l = term.q_l;
    const w_l = term.w_l;
    if (witness_assignments.get(w_l)) |w_l_value| {
        return q_l.mul(w_l_value);
    } else {
        return null;
    }
}

fn solve_fan_in_term(arith_opcode: *const Expression, witness_assignments: *WitnessMap) OpcodeStatus {
    var unknown_variable = LinearCombination{ .q_l = F.zero, .w_l = undefined };
    var num_unknowns: usize = 0;
    var result = F.zero;

    for (arith_opcode.linear_combinations) |term| {
        if (solve_fan_in_term_helper(&term, witness_assignments)) |v| {
            result = result.add(v);
        } else {
            unknown_variable = term;
            num_unknowns += 1;
        }

        if (num_unknowns > 1) {
            return OpcodeStatus.OpcodeUnsolvable;
        }
    }

    if (num_unknowns == 0) {
        return OpcodeStatus{ .OpcodeSatisfied = result };
    }

    return OpcodeStatus{ .OpcodeSolvable = .{ .sum = result, .unknown_var = unknown_variable } };
}

test "expression solver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const a: Witness = 0;
    const b: Witness = 1;
    const c: Witness = 2;
    const d: Witness = 3;
    const e: Witness = 4;

    // a = b + c + d;
    var opcode_a = ExpressionBuilder.init(allocator);
    try opcode_a.linear_combinations.append(.{ .q_l = F.from_int(1), .w_l = a });
    try opcode_a.linear_combinations.append(.{ .q_l = F.from_int(1).neg(), .w_l = b });
    try opcode_a.linear_combinations.append(.{ .q_l = F.from_int(1).neg(), .w_l = c });
    try opcode_a.linear_combinations.append(.{ .q_l = F.from_int(1).neg(), .w_l = d });

    var opcode_b = ExpressionBuilder.init(allocator);
    try opcode_b.linear_combinations.append(.{ .q_l = F.from_int(1), .w_l = e });
    try opcode_b.linear_combinations.append(.{ .q_l = F.from_int(1).neg(), .w_l = a });
    try opcode_b.linear_combinations.append(.{ .q_l = F.from_int(1).neg(), .w_l = b });

    var values = WitnessMap.init(allocator);
    defer values.deinit();

    try values.put(b, F.from_int(2));
    try values.put(c, F.from_int(1));
    try values.put(d, F.from_int(1));

    try solve(allocator, &values, &opcode_a.toExpression());
    try solve(allocator, &values, &opcode_b.toExpression());

    const a_value = values.get(a).?;
    const e_value = values.get(e).?;

    try std.testing.expectEqual(4, a_value.to_int());
    try std.testing.expectEqual(6, e_value.to_int());
}
