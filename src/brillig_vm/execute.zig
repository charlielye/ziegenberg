const std = @import("std");
const deserializeOpcodes = @import("io.zig").deserializeOpcodes;
const BrilligOpcode = @import("io.zig").BrilligOpcode;
const BitSize = @import("io.zig").BitSize;
const io = @import("io.zig");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const root = @import("../blackbox/field.zig");
const blackbox = @import("../blackbox/blackbox.zig");

pub fn execute(file_path: []const u8, calldata_path: ?[]const u8, show_stats: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const opcodes = try io.load(allocator, file_path);
    std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    var calldata: []u256 = &[_]u256{};
    if (calldata_path) |path| {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        const calldata_bytes = try f.readToEndAllocOptions(allocator, std.math.maxInt(usize), null, 32, null);
        calldata = std.mem.bytesAsSlice(u256, calldata_bytes);
        for (0..calldata.len) |i| {
            calldata[i] = @byteSwap(calldata[i]);
        }
    }
    std.debug.print("Calldata consists of {} elements.\n", .{calldata.len});

    var t = try std.time.Timer.start();
    std.debug.print("Initing...\n", .{});
    var brillig_vm = try BrilligVm.init(allocator, calldata);
    defer brillig_vm.deinit(allocator);
    std.debug.print("Init time: {}us\n", .{t.read() / 1000});

    std.debug.print("Executing...\n", .{});
    t.reset();
    const result = brillig_vm.executeVm(opcodes);
    std.debug.print("time taken: {}us\n", .{t.read() / 1000});
    if (show_stats) brillig_vm.dumpStats();
    return result;
}

extern fn mlock(addr: ?*u8, len: usize) callconv(.C) i32;

const BrilligVm = struct {
    const mem_size = 1024 * 1024 * (512 + 128);
    const jump_table = [_]*const fn (*BrilligVm, *BrilligOpcode) void{
        &processBinaryFieldOp,
        &processBinaryIntOp,
        &processNot,
        &processCast,
        &processJumpIfNot,
        &processJumpIf,
        &processJump,
        &processCalldatacopy,
        &processCall,
        &processConst,
        &processIndirectConst,
        &processReturn,
        &processForeignCall,
        &processMov,
        &processCmov,
        &processLoad,
        &processStore,
        &processBlackbox,
        &processTrap,
        &processStop,
    };
    memory: []align(4096) u256,
    calldata: []u256,
    callstack: std.ArrayList(u64),
    pc: u64 = 0,
    halted: bool = false,
    trapped: bool = false,
    ops_executed: u64 = 0,
    counters: [@typeInfo(io.BlackBoxOp).Union.fields.len]usize,

    pub fn init(allocator: std.mem.Allocator, calldata: []u256) !BrilligVm {
        const vm = BrilligVm{
            .memory = try allocator.alignedAlloc(u256, 4096, mem_size),
            .calldata = calldata,
            .callstack = try std.ArrayList(u64).initCapacity(allocator, 1024),
            .counters = std.mem.zeroes([@typeInfo(io.BlackBoxOp).Union.fields.len]usize),
        };

        // Advise huge pages.
        // try std.posix.madvise(@ptrCast(vm.memory.ptr), mem_size * 32, std.posix.MADV.HUGEPAGE);
        // std.debug.print("Memory allocated with Transparent Huge Pages enabled {}\n", .{mem_size * 32});

        // Lock the allocated memory in RAM using mlock.
        // This is really so we can perf test execution without is polluting the callstacks with page faults.
        // It's worse performance overall.
        // const mlock_result = mlock(@ptrCast(vm.memory.ptr), mem_size * 32);
        // if (mlock_result != 0) {
        //     std.debug.print("mlock failed with error code {}\n", .{mlock_result});
        //     return error.MLOCK;
        // }
        // std.debug.print("Mem locked.\n", .{});

        // @memset(vm.memory, 0);
        return vm;
    }

    pub fn deinit(self: *BrilligVm, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
    }

    pub fn executeVm(self: *BrilligVm, opcodes: []BrilligOpcode) !void {
        while (!self.halted) {
            const opcode = &opcodes[self.pc];
            // std.debug.print("{}: {any}\n", .{ pc, opcode });
            const i = @intFromEnum(opcode.*);
            if (i > BrilligVm.jump_table.len - 1) {
                return error.UnknownOpcode;
            }
            BrilligVm.jump_table[i](self, opcode);
            self.ops_executed += 1;
        }

        if (self.trapped) {
            return error.Trapped;
        }
    }

    fn processConst(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const op = &opcode.Const;
        const dest_index = op.destination;
        // TODO: Move to deserialize time. Convert to montgomery if a field so it happens just once.
        if (op.bit_size == BitSize.Field and (op.value & (1 << 255)) == 0) {
            op.value = @as(u256, @bitCast(Bn254Fr.from_int(op.value).limbs)) | (1 << 255);
        }
        self.memory[dest_index] = op.value;
        self.pc += 1;
    }

    fn processIndirectConst(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const op = &opcode.IndirectConst;
        const dest_ptr_index = op.destination_pointer;
        const dest_address = self.memory[dest_ptr_index];
        // TODO: Move to deserialize time. Convert to montgomery if a field so it happens just once.
        if (op.bit_size == BitSize.Field and (op.value & (1 << 255)) == 0) {
            op.value = @as(u256, @bitCast(Bn254Fr.from_int(op.value).limbs)) | (1 << 255);
        }
        self.memory[@truncate(dest_address)] = op.value;
        self.pc += 1;
    }

    fn processCalldatacopy(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const op = &opcode.CalldataCopy;
        const size: u64 = @truncate(self.memory[op.size_address]);
        const offset: u64 = @truncate(self.memory[op.offset_address]);
        if (self.calldata.len < size) {
            self.trapped = true;
            return;
        }
        for (0..size) |i| {
            const addr = op.destination_address + i;
            const src_index = offset + i;
            // std.debug.print("copy {} to slot {}\n", .{ calldata[src_index], addr });
            self.memory[addr] = self.calldata[src_index];
        }
        self.pc += 1;
    }

    fn processCast(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const op = &opcode.Cast;
        switch (op.bit_size) {
            .Integer => |int_size| {
                root.bn254_fr_normalize(@ptrCast(&self.memory[op.source]));
                const mask = (@as(u256, 1) << getBitSize(int_size)) - 1;
                self.memory[op.destination] = self.memory[op.source] & mask;
            },
            .Field => {
                self.memory[op.destination] = self.memory[op.source];
            },
        }
        self.pc += 1;
    }

    fn processMov(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const mov = &opcode.Mov;
        self.memory[mov.destination] = self.memory[mov.source];
        self.pc += 1;
    }

    fn processCmov(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const mov = &opcode.ConditionalMov;
        self.memory[mov.destination] = self.memory[if (self.memory[mov.condition] != 0) mov.source_a else mov.source_b];
        self.pc += 1;
    }

    fn processStore(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const store = &opcode.Store;
        self.memory[@truncate(self.memory[store.destination_pointer])] = self.memory[store.source];
        self.pc += 1;
    }

    fn processLoad(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const load = &opcode.Load;
        self.memory[load.destination] = self.memory[@truncate(self.memory[load.source_pointer])];
        self.pc += 1;
    }

    fn processCall(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const call = &opcode.Call;
        self.callstack.append(self.pc + 1) catch unreachable;
        self.pc = call.location;
    }

    fn processReturn(self: *BrilligVm, _: *BrilligOpcode) void {
        self.pc = self.callstack.pop();
    }

    fn processJump(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const jmp = &opcode.Jump;
        self.pc = jmp.location;
    }

    fn processJumpIf(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const jmp = &opcode.JumpIf;
        self.pc = if (self.memory[jmp.condition] == 1) jmp.location else self.pc + 1;
    }

    fn processJumpIfNot(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const jmp = &opcode.JumpIfNot;
        self.pc = if (self.memory[jmp.condition] == 0) jmp.location else self.pc + 1;
    }

    fn processNot(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const not = &opcode.Not;
        self.memory[not.destination] = switch (not.bit_size) {
            .U0 => unreachable,
            .U1 => self.unaryNot(u1, not),
            .U8 => self.unaryNot(u8, not),
            .U16 => self.unaryNot(u16, not),
            .U32 => self.unaryNot(u32, not),
            .U64 => self.unaryNot(u64, not),
            .U128 => self.unaryNot(u128, not),
        };
        self.pc += 1;
    }

    fn processBinaryIntOp(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const int_op = &opcode.BinaryIntOp;
        self.memory[int_op.destination] = switch (int_op.bit_size) {
            .U0 => unreachable,
            .U1 => self.binaryIntOp(u1, opcode.BinaryIntOp),
            .U8 => self.binaryIntOp(u8, opcode.BinaryIntOp),
            .U16 => self.binaryIntOp(u16, opcode.BinaryIntOp),
            .U32 => self.binaryIntOp(u32, opcode.BinaryIntOp),
            .U64 => self.binaryIntOp(u64, opcode.BinaryIntOp),
            .U128 => self.binaryIntOp(u128, opcode.BinaryIntOp),
        };
        self.pc += 1;
    }

    fn processBinaryFieldOp(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const field_op = &opcode.BinaryFieldOp;
        const lhs = &self.memory[field_op.lhs];
        const rhs = &self.memory[field_op.rhs];
        const dest = &self.memory[field_op.destination];
        switch (field_op.op) {
            .Add => root.bn254_fr_add(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .Mul => root.bn254_fr_mul(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .Sub => root.bn254_fr_sub(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .Div => root.bn254_fr_div(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .Equals => root.bn254_fr_eq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .LessThan => root.bn254_fr_lt(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .LessThanEquals => root.bn254_fr_leq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            else => unreachable,
        }
        self.pc += 1;
    }

    fn processBlackbox(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const blackbox_op = &opcode.BlackBox;
        const memory = self.memory;

        const idx = @intFromEnum(blackbox_op.*);
        self.counters[idx] += 1;

        switch (blackbox_op.*) {
            .Sha256Compression => |op| {
                blackbox.blackbox_sha256_compression(
                    @ptrCast(&memory[@truncate(memory[op.input.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.hash_values.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
                );
            },
            .Blake2s => |op| {
                blackbox.blackbox_blake2s(
                    @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
                    @truncate(memory[op.message.size]),
                    @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
                );
            },
            .Blake3 => |op| {
                blackbox.blackbox_blake3(
                    @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
                    @truncate(memory[op.message.size]),
                    @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
                );
            },
            .Keccakf1600 => |op| {
                blackbox.blackbox_keccak1600(
                    @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
                    @truncate(memory[op.message.size]),
                    @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
                );
            },
            .Poseidon2Permutation => |op| {
                blackbox.blackbox_poseidon2_permutation(
                    @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
                    @truncate(memory[op.message.size]),
                );
            },
            .PedersenCommitment => |op| {
                blackbox.blackbox_pedersen_commit(
                    @ptrCast(&memory[@truncate(memory[op.inputs.pointer])]),
                    @truncate(memory[op.inputs.size]),
                    @truncate(memory[op.domain_separator]),
                    @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
                );
            },
            .PedersenHash => |op| {
                blackbox.blackbox_pedersen_hash(
                    @ptrCast(&memory[@truncate(memory[op.inputs.pointer])]),
                    @truncate(memory[op.inputs.size]),
                    @truncate(memory[op.domain_separator]),
                    @ptrCast(&memory[op.output]),
                );
            },
            .ToRadix => |op| {
                blackbox.blackbox_to_radix(
                    @ptrCast(&memory[op.input]),
                    @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
                    op.output.size,
                    @truncate(memory[op.radix]),
                );
            },
            .AES128Encrypt => |op| {
                blackbox.blackbox_aes_encrypt(
                    @ptrCast(&memory[@truncate(memory[op.inputs.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.iv.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.key.pointer])]),
                    @truncate(memory[op.inputs.size]),
                    @ptrCast(&memory[@truncate(memory[op.outputs.pointer])]),
                    @ptrCast(&memory[op.outputs.size]),
                );
            },
            .EcdsaSecp256k1 => |op| {
                blackbox.blackbox_secp256k1_verify_signature(
                    @ptrCast(&memory[@truncate(memory[op.hashed_msg.pointer])]),
                    @truncate(memory[op.hashed_msg.size]),
                    @ptrCast(&memory[@truncate(memory[op.public_key_x.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.public_key_y.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.signature.pointer])]),
                    @ptrCast(&memory[op.result]),
                );
            },
            .EcdsaSecp256r1 => |op| {
                blackbox.blackbox_secp256r1_verify_signature(
                    @ptrCast(&memory[@truncate(memory[op.hashed_msg.pointer])]),
                    @truncate(memory[op.hashed_msg.size]),
                    @ptrCast(&memory[@truncate(memory[op.public_key_x.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.public_key_y.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.signature.pointer])]),
                    @ptrCast(&memory[op.result]),
                );
            },
            .SchnorrVerify => |op| {
                blackbox.blackbox_schnorr_verify_signature(
                    @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
                    @truncate(memory[op.message.size]),
                    @ptrCast(&memory[op.public_key_x]),
                    @ptrCast(&memory[op.public_key_y]),
                    @ptrCast(&memory[@truncate(memory[op.signature.pointer])]),
                    @ptrCast(&memory[op.result]),
                );
            },
            .MultiScalarMul => |op| {
                blackbox.blackbox_msm(
                    @ptrCast(&memory[@truncate(memory[op.points.pointer])]),
                    @truncate(memory[op.points.size]),
                    @ptrCast(&memory[@truncate(memory[op.scalars.pointer])]),
                    @ptrCast(&memory[@truncate(memory[op.outputs.pointer])]),
                );
            },
            .EmbeddedCurveAdd => |op| {
                blackbox.blackbox_ecc_add(
                    @ptrCast(&memory[op.input1_x]),
                    @ptrCast(&memory[op.input1_y]),
                    @ptrCast(&memory[op.input1_infinite]),
                    @ptrCast(&memory[op.input2_x]),
                    @ptrCast(&memory[op.input2_y]),
                    @ptrCast(&memory[op.input2_infinite]),
                    @ptrCast(&memory[@truncate(memory[op.result.pointer])]),
                );
            },
            else => {
                std.debug.print("Unimplemented: {}\n", .{blackbox_op});
                unreachable;
            },
        }
        self.pc += 1;
    }

    fn processForeignCall(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const fc = &opcode.ForeignCall;
        if (std.mem.eql(u8, "print", fc.function)) {
            std.debug.print("print called\n", .{});
        } else {
            std.debug.print("Unimplemented: {s}\n", .{fc.function});
            unreachable;
        }
        self.pc += 1;
    }

    fn processStop(self: *BrilligVm, _: *BrilligOpcode) void {
        self.halted = true;
    }

    fn processTrap(self: *BrilligVm, _: *BrilligOpcode) void {
        self.halted = true;
        self.trapped = true;
        std.debug.print("Trap! (todo print revert_data)\n", .{});
    }

    pub fn dumpMem(self: *BrilligVm, n: usize) void {
        for (0..n) |i| {
            std.debug.print("{:0>3}: 0x{x:0>64}\n", .{ i, self.memory[i] });
        }
    }

    pub fn dumpStats(self: *BrilligVm) void {
        std.debug.print("Opcodes executed: {}\n", .{self.ops_executed});

        // Print the counters next to the enum variant names
        std.debug.print("Blackbox calls:\n", .{});
        inline for (@typeInfo(io.BlackBoxOp).Union.fields, 0..) |enumField, idx| {
            std.debug.print("  {s}: {}\n", .{ enumField.name, self.counters[idx] });
        }
    }

    fn binaryIntOp(self: *BrilligVm, comptime int_type: type, op: anytype) int_type {
        const lhs: int_type = @truncate(self.memory[op.lhs]);
        const rhs: int_type = @truncate(self.memory[op.rhs]);
        const bit_size = @bitSizeOf(int_type);
        const r = switch (op.op) {
            .Add => lhs +% rhs,
            .Sub => lhs -% rhs,
            .Div => lhs / rhs,
            .Mul => lhs *% rhs,
            .And => lhs & rhs,
            .Or => lhs | rhs,
            .Xor => lhs ^ rhs,
            .Shl => if (rhs < bit_size) lhs << @truncate(rhs) else 0,
            .Shr => if (rhs < bit_size) lhs >> @truncate(rhs) else 0,
            .Equals => @intFromBool(lhs == rhs),
            .LessThan => @intFromBool(lhs < rhs),
            .LessThanEquals => @intFromBool(lhs <= rhs),
        };
        // std.debug.print("{} op {} = {}\n", .{ lhs, rhs, r });
        return r;
    }

    fn unaryNot(self: *BrilligVm, comptime int_type: type, op: anytype) int_type {
        const rhs: int_type = @truncate(~self.memory[op.source]);
        return rhs;
    }
};

fn getBitSize(int_size: io.IntegerBitSize) u8 {
    return switch (int_size) {
        .U0 => unreachable,
        .U1 => 1,
        .U8 => 8,
        .U16 => 16,
        .U32 => 32,
        .U64 => 64,
        .U128 => 128,
    };
}
