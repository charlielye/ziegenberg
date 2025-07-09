const std = @import("std");
const io = @import("io.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const GrumpkinFr = @import("../grumpkin/fr.zig").Fr;
const solve = @import("./expression_solver.zig").solve;
const evaluate = @import("./expression_solver.zig").evaluate;
const BrilligVm = @import("../bvm/execute.zig").BrilligVm;
const ErrorContext = @import("../bvm/execute.zig").ErrorContext;
const sha256 = @import("../blackbox/sha256_compress.zig");
const aes = @import("../aes/encrypt_cbc.zig");
const WitnessMap = @import("./witness_map.zig").WitnessMap;
const MemoryOpSolver = @import("./memory_op_solver.zig").MemoryOpSolver;
const G1 = @import("../grumpkin/g1.zig").G1;
const Poseidon2 = @import("../poseidon2/permutation.zig").Poseidon2;
const nargo_toml = @import("../nargo/nargo_toml.zig");
const prover_toml = @import("../nargo/prover_toml.zig");
const nargo_artifact = @import("../nargo/artifact.zig");
const verify_signature = @import("../blackbox/ecdsa.zig").verify_signature;
const toml = @import("toml");
const msm = @import("../msm/naive.zig").msm;
const ForeignCallDispatcher = @import("../bvm/foreign_call/dispatcher.zig").Dispatcher;

pub const ExecuteOptions = struct {
    // If null, the current working directory is used.
    project_path: ?[]const u8 = null,
    // Absolute or relative to project_path.
    artifact_path: ?[]const u8 = null,
    witness_path: ?[]const u8 = null,
    bytecode_path: ?[]const u8 = null,
    calldata_path: ?[]const u8 = null,
    show_trace: bool = false,
    binary: bool = false,
};

fn anyIntToU256(width: ?u32, value: i256) u256 {
    if (width) |w| {
        const mask = (@as(u256, 1) << @truncate(w)) - 1;
        return @as(u256, @bitCast(value)) & mask;
    }
    return @bitCast(value);
}

fn parseNumberString(str: []const u8, width: ?u32) !u256 {
    return if (std.mem.startsWith(u8, str, "0x"))
        try std.fmt.parseInt(u256, str[2..], 16)
    else if (std.mem.startsWith(u8, str, "-0x"))
        anyIntToU256(width, -try std.fmt.parseInt(i256, str[3..], 16))
    else
        anyIntToU256(width, try std.fmt.parseInt(i256, str, 10));
}

// Example parameter:
//   {"name":"z","type":{"kind":"integer","sign":"unsigned","width":32},"visibility":"private"},
//   {"name":"x","type":{"kind":"array","length":5,"type":{"kind":"integer","sign":"unsigned","width":32}},"visibility":"private"},
fn loadCalldata(calldata_array: *std.ArrayList(Fr), param_type: nargo_artifact.Type, value: toml.Value) !void {
    switch (std.meta.stringToEnum(nargo_artifact.Kind, param_type.kind.?).?) {
        .boolean => {
            const as_int: u256 = switch (value) {
                .boolean => if (value.boolean) 1 else 0,
                .integer => if (value.integer != 0) 1 else 0,
                .string => if (try parseNumberString(value.string, null) == 0) 0 else 1,
                else => unreachable,
            };
            try calldata_array.append(Fr.from_int(as_int));
        },
        .field => {
            const as_int: u256 = switch (value) {
                .integer => @intCast(value.integer),
                .string => try parseNumberString(value.string, null),
                else => unreachable,
            };
            try calldata_array.append(Fr.from_int(as_int));
        },
        .integer => {
            const as_int: u256 = switch (value) {
                .integer => anyIntToU256(param_type.width, value.integer),
                .string => try parseNumberString(value.string, param_type.width),
                else => unreachable,
            };
            try calldata_array.append(Fr.from_int(as_int));
        },
        .string => {
            for (value.string) |elem| {
                const as_int: u256 = @intCast(elem);
                try calldata_array.append(Fr.from_int(as_int));
            }
        },
        .array => {
            for (value.array.items) |elem| {
                try loadCalldata(calldata_array, param_type.type.?.*, elem);
            }
        },
        .@"struct" => {
            for (param_type.fields.?) |field| {
                const field_value = value.table.get(field.name.?) orelse {
                    std.debug.print("Missing field {s} in struct {s}\n", .{ field.name.?, param_type.kind.? });
                    return error.MissingField;
                };
                try loadCalldata(calldata_array, field.type.?.*, field_value);
            }
        },
        .tuple => {
            for (value.array.items, 0..) |elem, i| {
                try loadCalldata(calldata_array, param_type.fields.?[i], elem);
            }
        },
    }
}

fn loadCalldataFromProverToml(
    allocator: std.mem.Allocator,
    artifact: *const nargo_artifact.ArtifactAbi,
    pt_path: []const u8,
) ![]Fr {
    const pt = try prover_toml.load(allocator, pt_path);
    var calldata_array = std.ArrayList(Fr).init(allocator);
    defer calldata_array.deinit();
    std.debug.print("Loading calldata from {s}...\n", .{pt_path});
    for (artifact.abi.parameters, 0..) |param, i| {
        const value = pt.get(param.name) orelse unreachable;
        _ = i;
        // std.debug.print("Parameter {}: {s} ({s}) = {any}\n", .{
        //     i,
        //     param.name,
        //     param.type.kind.?,
        //     value,
        // });
        try loadCalldata(&calldata_array, param.type, value);
    }
    return calldata_array.toOwnedSlice();
}

pub fn execute(options: ExecuteOptions) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const project_path = options.project_path orelse try std.fs.cwd().realpathAlloc(allocator, ".");

    // Load Nargo.toml.
    const nt_path = try std.fmt.allocPrint(allocator, "{s}/Nargo.toml", .{project_path});
    const nt = nargo_toml.load(allocator, nt_path) catch null;
    const name = if (nt) |t| t.package.name else std.fs.path.basename(project_path);

    const artifact_path = if (options.artifact_path) |path|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, path })
    else
        try std.fmt.allocPrint(allocator, "{s}/target/{s}.json", .{ project_path, name });

    // Init calldata to empty slice.
    var calldata: []Fr = &[_]Fr{};
    var program: io.Program = undefined;

    if (options.bytecode_path) |path| {
        std.debug.print("Loading bytecode from {s}...\n", .{path});
        // If bytecode path is provided, load bytecode from it, and optionally load calldata from given path if given.
        program = try io.load(allocator, path);

        if (options.calldata_path) |calldata_path| {
            const artifact = try nargo_artifact.ArtifactAbi.load(allocator, artifact_path);
            const pt_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, calldata_path });
            calldata = try loadCalldataFromProverToml(allocator, &artifact, pt_path);
        }
    } else {
        // Otherwise, load the bytecode from the artifact, and calldata from Prover.toml (unless overridden).
        const artifact = try nargo_artifact.ArtifactAbi.load(allocator, artifact_path);
        const bytecode = try artifact.getBytecode(allocator);
        program = try io.deserialize(allocator, bytecode);

        if (options.calldata_path) |path| {
            const pt_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, path });
            calldata = try loadCalldataFromProverToml(allocator, &artifact, pt_path);
        } else {
            // If default Prover.toml doesn't exist we continue with empty calldata.
            const pt_path = try std.fmt.allocPrint(allocator, "{s}/Prover.toml", .{project_path});
            calldata = loadCalldataFromProverToml(allocator, &artifact, pt_path) catch |err| switch (err) {
                error.FileNotFound => calldata,
                else => return err,
            };
        }
    }

    std.debug.assert(program.functions.len == 1);
    std.debug.print("Calldata consists of {} elements.\n", .{calldata.len});

    var fc_handler = ForeignCallDispatcher.init(allocator);
    defer fc_handler.deinit();

    var t = try std.time.Timer.start();
    std.debug.print("Initing...\n", .{});
    var vm = try CircuitVm.init(allocator, &program, calldata, &fc_handler);
    defer vm.deinit();
    std.debug.print("Init time: {}us\n", .{t.read() / 1000});

    std.debug.print("Executing...\n", .{});
    t.reset();
    const result = vm.executeVm(0, options.show_trace);
    std.debug.print("time taken: {}us\n", .{t.read() / 1000});

    result catch |err| {
        std.debug.print("Execution failed: {}\n", .{err});
        try vm.witnesses.printWitnesses(false);
        return err;
    };

    if (options.witness_path) |witness_path| {
        const file_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, witness_path });
        const file = try std.fs.cwd().createFile(file_name, .{ .truncate = true });
        defer file.close();
        std.debug.print("Writing witnesses to {s}\n", .{file_name});
        // Create a writer for the file that gzips the output.
        var compressor = try std.compress.gzip.compressor(file.writer(), .{});
        // Write the witnesses to the file.
        try vm.witnesses.writeWitnesses(options.binary, compressor.writer());
        try compressor.finish();
    } else {
        try vm.witnesses.printWitnesses(options.binary);
    }
}

pub const CircuitVm = struct {
    allocator: std.mem.Allocator,
    program: *const io.Program,
    witnesses: WitnessMap,
    memory_solvers: std.AutoHashMap(u32, MemoryOpSolver),
    fc_handler: ForeignCallDispatcher,
    brillig_error_context: ?ErrorContext = null,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const io.Program,
        calldata: []Fr,
        fc_handler: *ForeignCallDispatcher,
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
            .fc_handler = fc_handler.*,
        };
    }

    pub fn deinit(self: *CircuitVm) void {
        self.witnesses.deinit();
        self.fc_handler.deinit();
    }

    /// Print detailed error information when a Brillig VM trap occurs
    pub fn printBrilligTrapError(
        self: *const CircuitVm,
        function_name: []const u8,
        function_selector: u32,
        contract_artifact_path: ?[]const u8,
    ) void {
        if (self.brillig_error_context) |error_ctx| {
            std.debug.print("\n=== Nested VM Trap ===\n", .{});
            std.debug.print("Function: {s} (selector: 0x{x})\n", .{ function_name, function_selector });
            std.debug.print("Brillig PC: {}\n", .{error_ctx.pc});
            std.debug.print("Operations executed: {}\n", .{error_ctx.ops_executed});
            if (error_ctx.callstack.len > 0) {
                std.debug.print("Callstack: ", .{});
                for (error_ctx.callstack) |addr| {
                    std.debug.print("{} ", .{addr});
                }
                std.debug.print("\n", .{});
            }

            // Try to look up source location
            if (contract_artifact_path) |artifact_path| {
                std.debug.print("\nSource location:\n", .{});
                const debug_info = @import("../bvm/debug_info.zig");
                debug_info.lookupSourceLocation(self.allocator, artifact_path, function_name, error_ctx.pc) catch |lookup_err| {
                    std.debug.print("  Could not resolve source location: {}\n", .{lookup_err});
                };
            }
            std.debug.print("======================\n\n", .{});
        }
    }

    pub fn executeVm(self: *CircuitVm, function_index: usize, show_trace: bool) !void {
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
                    var brillig_vm = try BrilligVm.init(arena.allocator(), calldata.items, &self.fc_handler);
                    defer brillig_vm.deinit();
                    brillig_vm.executeVm(self.program.unconstrained_functions[op.id], show_trace, 0) catch |err| {
                        if (err == error.Trapped) {
                            self.brillig_error_context = try brillig_vm.getErrorContext(self.allocator);
                            std.debug.print("BrilligVm error context captured - PC: {}, Ops: {}\n", .{ self.brillig_error_context.?.pc, self.brillig_error_context.?.ops_executed });
                        }
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

test "SKIP_execute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fs = std.fs.cwd();

    const tests_root = "aztec-packages/noir/noir-repo/test_programs/execution_success";
    var dir = try fs.openDir(tests_root, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const test_name = entry.name;
        std.debug.print("\n\x1b[34mRunning test: {s}\x1b[0m\n", .{test_name});

        const project_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tests_root, test_name });
        const witness_rel_path = try std.fmt.allocPrint(allocator, "target/{s}.zb.gz", .{test_name});
        const options = ExecuteOptions{
            .project_path = project_path,
            .witness_path = witness_rel_path,
            .show_trace = false,
            .binary = true,
        };

        try execute(options);

        const result_path = try std.fmt.allocPrint(allocator, "{s}/target/{s}.zb.gz", .{ project_path, test_name });
        const expected_path = try std.fmt.allocPrint(allocator, "{s}/target/{s}.gz", .{ project_path, test_name });

        const result = try WitnessMap.initFromPath(allocator, result_path);
        var result_buf = std.ArrayList(u8).init(allocator);
        defer result_buf.deinit();
        try result.writeWitnesses(true, result_buf.writer());

        const expected = try WitnessMap.initFromPath(allocator, expected_path);
        var expected_buf = std.ArrayList(u8).init(allocator);
        defer expected_buf.deinit();
        try expected.writeWitnesses(true, expected_buf.writer());

        try std.testing.expectEqualDeep(result_buf.items, expected_buf.items);
    }
}
