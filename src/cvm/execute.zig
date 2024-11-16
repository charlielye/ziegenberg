const std = @import("std");
const io = @import("io.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const solve = @import("./expression_solver.zig").solve;
const evaluate = @import("./expression_solver.zig").evaluate;
const BrilligVm = @import("../bvm/execute.zig").BrilligVm;
const sha256 = @import("../blackbox/sha256_compress.zig");
const aes = @import("../aes/encrypt_cbc.zig");
const WitnessMap = @import("./witness_map.zig").WitnessMap;
const MemoryOpSolver = @import("./memory_op_solver.zig").MemoryOpSolver;
const G1 = @import("../grumpkin/g1.zig").G1;
const Poseidon2 = @import("../poseidon2/permutation.zig").Poseidon2;

pub const ExecuteOptions = struct {
    file_path: ?[]const u8 = null,
    calldata_path: ?[]const u8 = null,
    show_stats: bool = false,
    show_trace: bool = false,
    binary: bool = false,
};

pub fn execute(options: ExecuteOptions) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const program = try io.load(allocator, options.file_path);
    std.debug.assert(program.functions.len == 1);
    // const opcodes = program.functions[0].opcodes;
    // std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    var calldata: []Fr = &[_]Fr{};
    if (options.calldata_path) |path| {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        const calldata_bytes = try f.readToEndAllocOptions(allocator, std.math.maxInt(usize), null, 32, null);
        const calldata_u256 = std.mem.bytesAsSlice(u256, calldata_bytes);
        calldata = std.mem.bytesAsSlice(Fr, calldata_bytes);
        for (0..calldata.len) |i| {
            calldata[i] = Fr.from_int(@byteSwap(calldata_u256[i]));
        }
    }
    std.debug.print("Calldata consists of {} elements.\n", .{calldata.len});

    var t = try std.time.Timer.start();
    std.debug.print("Initing...\n", .{});
    var vm = try CircuitVm.init(allocator, &program, calldata);
    defer vm.deinit();
    std.debug.print("Init time: {}us\n", .{t.read() / 1000});

    std.debug.print("Executing...\n", .{});
    t.reset();
    const result = vm.executeVm(0, options.show_trace);
    std.debug.print("time taken: {}us\n", .{t.read() / 1000});

    try vm.witnesses.printWitnesses(options.binary);

    return result;
}

const CircuitVm = struct {
    allocator: std.mem.Allocator,
    program: *const io.Program,
    witnesses: WitnessMap,
    memory_solvers: std.AutoHashMap(u32, MemoryOpSolver),

    pub fn init(allocator: std.mem.Allocator, program: *const io.Program, calldata: []Fr) !CircuitVm {
        var witnesses = WitnessMap.init(allocator);
        for (calldata, 0..) |e, i| {
            try witnesses.put(@truncate(i), e);
        }
        return CircuitVm{
            .allocator = allocator,
            .program = program,
            .witnesses = witnesses,
            .memory_solvers = std.AutoHashMap(u32, MemoryOpSolver).init(allocator),
        };
    }

    pub fn deinit(self: *CircuitVm) void {
        self.witnesses.deinit();
    }

    pub fn executeVm(self: *CircuitVm, function_index: usize, show_trace: bool) !void {
        // const buf = try self.allocator.alloc(u8, 1024 * 1024);
        // defer self.allocator.free(buf);
        // var a = std.heap.FixedBufferAllocator.init(buf);

        for (self.program.functions[function_index].opcodes, 0..) |opcode, i| {
            if (show_trace) {
                const stdout = std.io.getStdOut().writer();
                try stdout.print("{:0>4}: {any}\n", .{ i, opcode });
            }

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
                    var brillig_vm = try BrilligVm.init(self.allocator, calldata.items);
                    defer brillig_vm.deinit();
                    try brillig_vm.executeVm(self.program.unconstrained_functions[op.id], show_trace, 0);
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
                        .RANGE => {},
                        .Sha256Compression => |op| {
                            const input = self.resolveFunctionInputs(u32, 16, &op.inputs);
                            var hash_values = self.resolveFunctionInputs(u32, 8, &op.hash_values);
                            sha256.round(&input, &hash_values);
                            for (op.outputs, 0..) |w, wi| try self.witnesses.put(w, Fr.from_int(hash_values[wi]));
                        },
                        .AES128Encrypt => |op| {
                            var inout = try std.ArrayList(u8).initCapacity(self.allocator, op.inputs.len);
                            const key = self.resolveFunctionInputs(u8, 16, &op.key);
                            const iv = self.resolveFunctionInputs(u8, 16, &op.iv);
                            try aes.padAndEncryptCbc(&inout, &key, &iv);
                            for (op.outputs, inout.items) |w, v| try self.witnesses.put(w, Fr.from_int(v));
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
                        // .MultiScalarMul => {},
                        .Poseidon2Permutation => |op| {
                            const frs = self.resolveFunctionInputs(Fr, 4, op.inputs);
                            const r = Poseidon2.permutation(frs);
                            for (op.outputs, r) |w, v| try self.witnesses.put(w, v);
                        },
                        else => return error.Unimplemented,
                    }
                },
                .Directive => |op| {
                    switch (op) {
                        .ToLeRadix => |tle_op| {
                            const e = evaluate(self.allocator, &tle_op.a, &self.witnesses);
                            if (!e.isConst()) return error.OpcodeNotSolvable;
                            var in = e.q_c.to_int();
                            for (tle_op.b) |w| {
                                const quotient = in / tle_op.radix;
                                const remainder = in - (quotient * tle_op.radix);
                                try self.witnesses.put(w, Fr.from_int(remainder));
                                in = quotient;
                            }
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
