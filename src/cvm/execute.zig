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
const nargo_toml = @import("../nargo/nargo_toml.zig");
const prover_toml = @import("../nargo/prover_toml.zig");
const nargo_artifact = @import("../nargo/artifact.zig");

pub const ExecuteOptions = struct {
    // If null, the current working directory is used.
    project_path: ?[]const u8 = null,
    // Absolute or relative to project_path.
    witness_path: ?[]const u8 = null,
    // bytecode_path: ?[]const u8 = null,
    // calldata_path: ?[]const u8 = null,
    show_trace: bool = false,
    binary: bool = false,
};

pub fn execute(options: ExecuteOptions) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const project_path = options.project_path orelse unreachable;

    const nt_path = try std.fmt.allocPrint(allocator, "{s}/Nargo.toml", .{project_path});
    const nt = try nargo_toml.load(allocator, nt_path);
    const pt_path = try std.fmt.allocPrint(allocator, "{s}/Prover.toml", .{project_path});
    const pt = try prover_toml.load(allocator, pt_path);
    const artifact_path = try std.fmt.allocPrint(allocator, "{s}/target/{s}.json", .{ project_path, nt.package.name });
    // std.debug.print("Loading artifact from {s}\n", .{artifact_path});
    const artifact = try nargo_artifact.load(allocator, artifact_path);
    var calldata_array = std.ArrayList(Fr).init(allocator);
    defer calldata_array.deinit();
    for (artifact.abi.parameters, 0..) |param, i| {
        std.debug.print("Parameter {}: {s} ({s}) = {s}\n", .{ i, param.name, param.type.kind, pt.get(param.name).?.string });
        const as_int = try std.fmt.parseInt(u256, pt.get(param.name).?.string, 10);
        try calldata_array.append(Fr.from_int(as_int));
    }
    const calldata: []Fr = calldata_array.items;
    const bytecode = try artifact.getBytecode(allocator);

    const program = try io.deserialize(allocator, bytecode);
    // const program = try io.load(allocator, options.bytecode_path);
    std.debug.assert(program.functions.len == 1);
    // const opcodes = program.functions[0].opcodes;
    // std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    // var calldata: []Fr = &[_]Fr{};
    // if (options.calldata_path) |path| {
    //     const f = try std.fs.cwd().openFile(path, .{});
    //     defer f.close();
    //     const calldata_bytes = try f.readToEndAllocOptions(allocator, std.math.maxInt(usize), null, 32, null);
    //     const calldata_u256 = std.mem.bytesAsSlice(u256, calldata_bytes);
    //     calldata = std.mem.bytesAsSlice(Fr, calldata_bytes);
    //     for (0..calldata.len) |i| {
    //         calldata[i] = Fr.from_int(@byteSwap(calldata_u256[i]));
    //     }
    // }
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

    // Open file writer at target/<package_name>.zb.gz
    const file_name = if (options.witness_path) |path|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, path })
    else
        try std.fmt.allocPrint(allocator, "{s}/target/{s}.zb.gz", .{ project_path, nt.package.name });

    const file = try std.fs.cwd().createFile(file_name, .{ .truncate = true });
    defer file.close();
    std.debug.print("Writing witnesses to {s}\n", .{file_name});
    // Create a writer for the file that gzips the output.
    var compressor = try std.compress.gzip.compressor(file.writer(), .{});
    // Write the witnesses to the file.
    try vm.witnesses.writeWitnesses(options.binary, compressor.writer());
    try compressor.finish();

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

test "execute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const options = ExecuteOptions{
        .project_path = "aztec-packages/noir/noir-repo/test_programs/execution_success/1_mul",
        .witness_path = "target/1_mul.zb.gz",
        .show_trace = true,
        .binary = true,
    };
    try execute(options);

    const result = try WitnessMap.initFromPath(
        allocator,
        "aztec-packages/noir/noir-repo/test_programs/execution_success/1_mul/target/1_mul.zb.gz",
    );
    var result_buf = std.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    try result.writeWitnesses(true, result_buf.writer());

    const expected = try WitnessMap.initFromPath(
        allocator,
        "aztec-packages/noir/noir-repo/test_programs/execution_success/1_mul/target/1_mul.gz",
    );
    var expected_buf = std.ArrayList(u8).init(allocator);
    defer expected_buf.deinit();
    try expected.writeWitnesses(true, expected_buf.writer());

    // try result.printWitnesses(false);
    // try expected.printWitnesses(false);
    try std.testing.expectEqualDeep(result_buf.items, expected_buf.items);
}
