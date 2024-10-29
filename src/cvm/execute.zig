const std = @import("std");
const io = @import("io.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const solve = @import("./expression_solver.zig").solve;
const evaluate = @import("./expression_solver.zig").evaluate;
const BrilligVm = @import("../bvm/execute.zig").BrilligVm;
const sha256_compress = @import("../blackbox/sha256_compress.zig").round;
const WitnessMap = @import("./witness_map.zig").WitnessMap;
// const root = @import("../blackbox/field.zig");
// const blackbox = @import("../blackbox/blackbox.zig");

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

    pub fn init(allocator: std.mem.Allocator, program: *const io.Program, calldata: []Fr) !CircuitVm {
        var witnesses = WitnessMap.init(allocator);
        for (calldata, 0..) |e, i| {
            try witnesses.put(@truncate(i), e);
        }
        return CircuitVm{ .allocator = allocator, .program = program, .witnesses = witnesses };
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
                const stdout = std.io.getStdErr().writer();
                try stdout.print("{:0>4}: {any}\n", .{ i, opcode });
            }

            switch (opcode) {
                .AssertZero => |op| try solve(self.allocator, &self.witnesses, &op),
                .BrilligCall => |op| {
                    var calldata = std.ArrayList(u256).init(self.allocator);
                    for (op.inputs) |input| {
                        if (input == .MemoryArray) {
                            unreachable;
                        } else {
                            const elems = switch (input) {
                                .Single => &[_]io.Expression{input.Single},
                                .Array => input.Array,
                                .MemoryArray => unreachable,
                            };
                            for (elems) |expr| {
                                const e = evaluate(self.allocator, &expr, &self.witnesses);
                                if (!e.isConst()) return error.OpcodeNotSolvable;
                                try calldata.append(e.q_c.to_int());
                            }
                        }
                    }
                    var brillig_vm = try BrilligVm.init(self.allocator, calldata.items);
                    defer brillig_vm.deinit(self.allocator);
                    try brillig_vm.executeVm(self.program.unconstrained_functions[op.id], show_trace, 0);
                    var return_data_idx: u32 = 0;
                    for (op.outputs) |o| {
                        const witnesses = switch (o) {
                            .Simple => &[_]io.Witness{o.Simple},
                            .Array => o.Array,
                        };
                        for (witnesses) |w| {
                            try self.witnesses.put(w, Fr.from_int(brillig_vm.return_data[return_data_idx]));
                            return_data_idx += 1;
                        }
                    }
                },
                .BlackBoxOp => |op| {
                    switch (op) {
                        .RANGE => {},
                        .Sha256Compression => |sha_op| {
                            var input: [16]u32 = undefined;
                            var hash_values: [8]u32 = undefined;
                            for (sha_op.inputs, 0..) |fi, j| input[j] = self.resolveFunctionInput(u32, fi);
                            for (sha_op.hash_values, 0..) |fi, j| hash_values[j] = self.resolveFunctionInput(u32, fi);
                            sha256_compress(&input, &hash_values);
                            for (sha_op.outputs, 0..) |w, wi| try self.witnesses.put(w, Fr.from_int(hash_values[wi]));
                        },
                        else => unreachable,
                    }
                },
                // else => std.debug.print("Skipping {}\n", .{opcode}),
                else => {},
            }
        }
    }

    pub fn resolveFunctionInput(self: *CircuitVm, comptime T: type, fi: io.FunctionInput) T {
        return switch (fi.input) {
            .Constant => |v| @truncate(v.to_int()),
            .Witness => |w| @truncate((self.witnesses.get(w) orelse unreachable).to_int()),
        };
    }
};
