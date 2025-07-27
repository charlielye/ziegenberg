const std = @import("std");
const io = @import("io.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const GrumpkinFr = @import("../grumpkin/fr.zig").Fr;
const solve = @import("./expression_solver.zig").solve;
const evaluate = @import("./expression_solver.zig").evaluate;
const bvm = @import("../bvm/package.zig");
const debug_context = @import("../bvm/debug_context.zig");
const DebugContext = debug_context.DebugContext;
const sha256 = @import("../blackbox/sha256_compress.zig");
const aes = @import("../aes/encrypt_cbc.zig");
const WitnessMap = @import("./witness_map.zig").WitnessMap;
const MemoryOpSolver = @import("./memory_op_solver.zig").MemoryOpSolver;
const G1 = @import("../grumpkin/g1.zig").G1;
const Poseidon2 = @import("../poseidon2/permutation.zig").Poseidon2;
const verify_signature = @import("../blackbox/ecdsa.zig").verify_signature;
const msm = @import("../msm/naive.zig").msm;

pub const CircuitVm = struct {
    allocator: std.mem.Allocator,
    program: *const io.Program,
    witnesses: WitnessMap,
    memory_solvers: std.AutoHashMap(u32, MemoryOpSolver),
    fc_handler: bvm.foreign_call.ForeignCallDispatcher,
    debug_ctx: ?bvm.brillig_vm.BrilligVmHooks,
    brillig_error_context: ?bvm.brillig_vm.ErrorContext = null,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const io.Program,
        calldata: []Fr,
        fc_handler: bvm.foreign_call.ForeignCallDispatcher,
        debug_ctx: ?bvm.brillig_vm.BrilligVmHooks,
    ) !CircuitVm {
        var witnesses = WitnessMap.init(allocator);
        // Load our calldata into first elements of the witness map.
        for (calldata, 0..) |e, i| {
            try witnesses.put(@truncate(i), e);
        }
        return CircuitVm{
            .allocator = allocator,
            .program = program,
            .witnesses = witnesses,
            .memory_solvers = std.AutoHashMap(u32, MemoryOpSolver).init(allocator),
            .fc_handler = fc_handler,
            .debug_ctx = debug_ctx,
        };
    }

    pub fn deinit(self: *CircuitVm) void {
        self.witnesses.deinit();
    }

    pub fn executeVm(self: *CircuitVm, function_index: usize) !void {
        for (self.program.functions[function_index].opcodes) |opcode| {
            // if (options.show_trace) {
            //     const stdout = std.io.getStdOut().writer();
            //     try stdout.print("{:0>4}: {any}\n", .{ i, opcode });
            // }

            switch (opcode) {
                .AssertZero => |op| try solve(self.allocator, &self.witnesses, &op),
                .BrilligCall => |op| {
                    if (op.predicate) |*p| {
                        const e = evaluate(self.allocator, p, &self.witnesses).toConst() orelse
                            return error.OpcodeNotSolvable;
                        if (e.is_zero()) {
                            for (op.outputs) |o| {
                                const witnesses = switch (o) {
                                    .Simple => &[_]io.Witness{o.Simple},
                                    .Array => o.Array,
                                };
                                for (witnesses) |w| {
                                    try self.witnesses.put(w, Fr.zero);
                                }
                            }
                            continue;
                        }
                    }
                    // TODO: Make Fr?
                    var calldata = std.ArrayList(u256).init(self.allocator);
                    for (op.inputs) |input| {
                        if (input == .MemoryArray) {
                            const block_id = input.MemoryArray;
                            const block = self.memory_solvers.get(block_id) orelse return error.MemBlockNotFound;
                            for (0..block.block_len) |mem_idx| {
                                const value = block.block_value.get(@intCast(mem_idx)) orelse
                                    return error.UninitializedMemory;
                                try calldata.append(value.to_int());
                            }
                        } else {
                            // Normalise a single input into an array.
                            const elems = switch (input) {
                                .Single => &[_]io.Expression{input.Single},
                                .Array => input.Array,
                                .MemoryArray => unreachable,
                            };
                            for (elems) |expr| {
                                const e = evaluate(self.allocator, &expr, &self.witnesses);
                                if (!e.isConst()) return error.OpcodeNotSolvable;
                                // std.debug.print("input calldata {} eq {}\n", .{ calldata.items.len, e.q_c.to_int() });
                                try calldata.append(e.q_c.to_int());
                            }
                        }
                    }
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    var brillig_vm = try bvm.BrilligVm.init(
                        arena.allocator(),
                        calldata.items,
                        self.fc_handler,
                        self.debug_ctx,
                    );
                    defer brillig_vm.deinit();

                    brillig_vm.executeVm(self.program.unconstrained_functions[op.id], .{}) catch |err| {
                        self.brillig_error_context = try brillig_vm.getErrorContext(self.allocator);
                        return err;
                    };

                    var return_data_idx: u32 = 0;
                    for (op.outputs) |o| {
                        const witnesses = switch (o) {
                            .Simple => &[_]io.Witness{o.Simple},
                            .Array => o.Array,
                        };
                        for (witnesses) |w| {
                            // std.debug.print("copying brillig result {} to witness {}\n", .{ brillig_vm.return_data[return_data_idx], w });
                            try self.witnesses.put(w, Fr.from_int(brillig_vm.return_data[return_data_idx]));
                            return_data_idx += 1;
                        }
                    }
                },
                .BlackBoxOp => |blackbox_op| {
                    switch (blackbox_op) {
                        .RANGE => {
                            // TODO: Solve pedantically.
                        },
                        .AND => |op| {
                            const lhs = self.resolveFunctionInput(u256, op.lhs);
                            const rhs = self.resolveFunctionInput(u256, op.rhs);
                            const result = lhs & rhs;
                            try self.witnesses.put(op.output, Fr.from_int(result));
                        },
                        .XOR => |op| {
                            const lhs = self.resolveFunctionInput(u256, op.lhs);
                            const rhs = self.resolveFunctionInput(u256, op.rhs);
                            const result = lhs ^ rhs;
                            try self.witnesses.put(op.output, Fr.from_int(result));
                        },
                        .Sha256Compression => |op| {
                            const input = self.resolveFunctionInputs(u32, 16, &op.inputs);
                            var hash_values = self.resolveFunctionInputs(u32, 8, &op.hash_values);
                            sha256.round(&input, &hash_values);
                            for (op.outputs, 0..) |w, wi| try self.witnesses.put(w, Fr.from_int(hash_values[wi]));
                        },
                        .Blake2s => |op| {
                            var input = try std.ArrayList(u8).initCapacity(self.allocator, op.inputs.len);
                            defer input.deinit();
                            for (op.inputs) |fi| {
                                try input.append(self.resolveFunctionInput(u8, fi));
                            }
                            var output: [32]u8 = undefined;
                            std.crypto.hash.blake2.Blake2s256.hash(input.items, &output, .{});
                            for (op.outputs, output) |w, v| try self.witnesses.put(w, Fr.from_int(v));
                        },
                        .Blake3 => |op| {
                            var input = try std.ArrayList(u8).initCapacity(self.allocator, op.inputs.len);
                            defer input.deinit();
                            for (op.inputs) |fi| {
                                try input.append(self.resolveFunctionInput(u8, fi));
                            }
                            var output: [32]u8 = undefined;
                            std.crypto.hash.Blake3.hash(input.items, &output, .{});
                            for (op.outputs, output) |w, v| try self.witnesses.put(w, Fr.from_int(v));
                        },
                        .Poseidon2Permutation => |op| {
                            const frs = self.resolveFunctionInputs(Fr, 4, op.inputs);
                            const r = Poseidon2.permutation(frs);
                            for (op.outputs, r) |w, v| try self.witnesses.put(w, v);
                        },
                        .Keccakf1600 => |op| {
                            const state = self.resolveFunctionInputs(u64, 25, &op.inputs);
                            var hasher = std.crypto.core.keccak.KeccakF(1600){ .st = state };
                            hasher.permute();
                            for (op.outputs, 0..) |w, wi| try self.witnesses.put(w, Fr.from_int(state[wi]));
                        },
                        .AES128Encrypt => |op| {
                            var inout = try std.ArrayList(u8).initCapacity(self.allocator, op.inputs.len);
                            defer inout.deinit();
                            for (op.inputs) |fi| {
                                try inout.append(self.resolveFunctionInput(u8, fi));
                            }
                            const key = self.resolveFunctionInputs(u8, 16, &op.key);
                            const iv = self.resolveFunctionInputs(u8, 16, &op.iv);
                            try aes.padAndEncryptCbc(&inout, &key, &iv);
                            for (op.outputs, inout.items) |w, v| try self.witnesses.put(w, Fr.from_int(v));
                        },
                        .EcdsaSecp256k1 => |op| {
                            const public_key_x = self.resolveFunctionInputs(u256, 32, &op.public_key_x);
                            const public_key_y = self.resolveFunctionInputs(u256, 32, &op.public_key_y);
                            const signature = self.resolveFunctionInputs(u256, 64, &op.signature);
                            const hashed_message = self.resolveFunctionInputs(u256, 32, &op.hashed_message);
                            var result: u256 = 0;
                            verify_signature(std.crypto.ecc.Secp256k1, &hashed_message, &public_key_x, &public_key_y, &signature, &result);
                            try self.witnesses.put(op.output, Fr.from_int(result));
                        },
                        .EcdsaSecp256r1 => |op| {
                            const public_key_x = self.resolveFunctionInputs(u256, 32, &op.public_key_x);
                            const public_key_y = self.resolveFunctionInputs(u256, 32, &op.public_key_y);
                            const signature = self.resolveFunctionInputs(u256, 64, &op.signature);
                            const hashed_message = self.resolveFunctionInputs(u256, 32, &op.hashed_message);
                            var result: u256 = 0;
                            verify_signature(std.crypto.ecc.P256, &hashed_message, &public_key_x, &public_key_y, &signature, &result);
                            try self.witnesses.put(op.output, Fr.from_int(result));
                        },
                        .EmbeddedCurveAdd => |op| {
                            const x1 = self.resolveFunctionInput(Fr, op.input1[0]);
                            const y1 = self.resolveFunctionInput(Fr, op.input1[1]);
                            const inf1 = self.resolveFunctionInput(u8, op.input1[2]);
                            const x2 = self.resolveFunctionInput(Fr, op.input2[0]);
                            const y2 = self.resolveFunctionInput(Fr, op.input2[1]);
                            const inf2 = self.resolveFunctionInput(u8, op.input2[2]);
                            const input1 = if (inf1 == 1) G1.Element.infinity else G1.Element.from_xy(x1, y1);
                            const input2 = if (inf2 == 1) G1.Element.infinity else G1.Element.from_xy(x2, y2);
                            const r = input1.add(input2).normalize();
                            try self.witnesses.put(op.outputs.x, r.x);
                            try self.witnesses.put(op.outputs.y, r.y);
                            try self.witnesses.put(op.outputs.i, if (r.is_infinity()) Fr.one else Fr.zero);
                        },
                        .MultiScalarMul => |op| {
                            const scalars_frs = try self.resolveVariableFunctionInputs(Fr, op.scalars);
                            const points_frs = try self.resolveVariableFunctionInputs(Fr, op.points);

                            const num_points = points_frs.len / 3;
                            var points = try std.ArrayList(G1.Element).initCapacity(self.allocator, num_points);
                            var scalars = try std.ArrayList(GrumpkinFr).initCapacity(self.allocator, num_points);

                            for (0..num_points) |j| {
                                const x = points_frs[j * 3];
                                const y = points_frs[j * 3 + 1];
                                const inf = points_frs[j * 3 + 2];

                                if (inf.is_zero()) {
                                    try points.append(G1.Element.from_xy(x, y));
                                } else {
                                    try points.append(G1.Element.infinity);
                                }

                                const slo = scalars_frs[j * 2].to_int();
                                const shi = scalars_frs[j * 2 + 1].to_int();
                                const s = slo | (shi << 128);
                                try scalars.append(GrumpkinFr.from_int(s));
                            }

                            const result = msm(G1, scalars.items, points.items).normalize();

                            try self.witnesses.put(op.outputs.x, result.x);
                            try self.witnesses.put(op.outputs.y, result.y);
                            try self.witnesses.put(op.outputs.i, if (result.is_infinity()) Fr.one else Fr.zero);
                        },
                        .RecursiveAggregation => {
                            // const vk = self.resolveVariableFunctionInputs(Fr, op.verification_key);
                            // const proof = self.resolveVariableFunctionInputs(Fr, op.proof);
                            // const public_inputs = self.resolveVariableFunctionInputs(Fr, op.public_inputs);
                        },
                        .BigIntAdd,
                        .BigIntDiv,
                        .BigIntMul,
                        .BigIntSub,
                        .BigIntFromLeBytes,
                        .BigIntToLeBytes,
                        => {
                            std.debug.print("Unimplemented BlackBoxOp: {any}\n", .{blackbox_op});
                            return error.Unimplemented;
                        },
                    }
                },
                .MemoryInit => |op| {
                    const r = try self.memory_solvers.getOrPut(op.block_id);
                    if (!r.found_existing) {
                        r.value_ptr.* = MemoryOpSolver.init(self.allocator);
                    }
                    try r.value_ptr.initMemory(op.init, &self.witnesses);
                },
                .MemoryOp => |op| {
                    const block = self.memory_solvers.getPtr(op.block_id) orelse return error.MemBlockNotFound;
                    try block.solveMemoryOp(&op.op, &self.witnesses, if (op.predicate) |p| &p else null);
                },
                else => return error.Unimplemented,
            }
        }
    }

    inline fn resolveVariableFunctionInputs(
        self: *CircuitVm,
        comptime T: type,
        src: []const io.FunctionInput,
    ) ![]T {
        var input = try std.ArrayList(T).initCapacity(self.allocator, src.len);
        defer input.deinit();
        for (src) |fi| {
            try input.append(self.resolveFunctionInput(T, fi));
        }
        return input.toOwnedSlice();
    }

    inline fn resolveFunctionInputs(
        self: *CircuitVm,
        comptime T: type,
        comptime len: usize,
        src: []const io.FunctionInput,
    ) [len]T {
        var dst: [len]T = undefined;
        for (src, 0..) |fi, j| dst[j] = self.resolveFunctionInput(T, fi);
        return dst;
    }

    inline fn resolveFunctionInput(self: *CircuitVm, comptime T: type, fi: io.FunctionInput) T {
        const f = switch (fi.input) {
            .Constant => |c| c.value,
            .Witness => |w| self.witnesses.get(w) orelse unreachable,
        };
        return if (T == Fr) f else @intCast(f.to_int());
    }
};
