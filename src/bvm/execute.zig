const std = @import("std");
const deserializeOpcodes = @import("io.zig").deserializeOpcodes;
const BrilligOpcode = @import("io.zig").BrilligOpcode;
const BitSize = @import("io.zig").BitSize;
const io = @import("io.zig");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const root = @import("../blackbox/field.zig");
const blackbox = @import("../blackbox/blackbox.zig");

pub const ExecuteOptions = struct {
    file_path: ?[]const u8 = null,
    calldata_path: ?[]const u8 = null,
    show_stats: bool = false,
    show_trace: bool = false,
};

pub fn execute(options: ExecuteOptions) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const opcodes = try io.load(allocator, options.file_path);
    std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    var calldata: []u256 = &[_]u256{};
    if (options.calldata_path) |path| {
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
    const result = brillig_vm.executeVm(opcodes, options.show_trace);
    std.debug.print("time taken: {}us\n", .{t.read() / 1000});
    if (options.show_stats) brillig_vm.dumpStats();
    return result;
}

extern fn mlock(addr: ?*u8, len: usize) callconv(.C) i32;

pub const BrilligVm = struct {
    const mem_size = 1024 * 1024;
    // const mem_size = 1024 * 1024 * 32;
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
    callstack: std.ArrayList(usize),
    pc: usize = 0,
    halted: bool = false,
    trapped: bool = false,
    return_data: []align(32) u256,
    ops_executed: u64 = 0,
    max_slot_set: u64 = 0,
    counters: [@typeInfo(io.BlackBoxOp).Union.fields.len]usize,

    pub fn init(allocator: std.mem.Allocator, calldata: []u256) !BrilligVm {
        const vm = BrilligVm{
            .memory = try allocator.alignedAlloc(u256, 4096, mem_size),
            .calldata = calldata,
            .callstack = try std.ArrayList(usize).initCapacity(allocator, 1024),
            .counters = std.mem.zeroes([@typeInfo(io.BlackBoxOp).Union.fields.len]usize),
            .return_data = &.{},
        };

        // Lock the allocated memory in RAM using mlock.
        // This is really so we can perf test execution without polluting the callstacks with page faults.
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

    pub fn executeVm(self: *BrilligVm, opcodes: []BrilligOpcode, show_trace: bool) !void {
        while (!self.halted) {
            const opcode = &opcodes[self.pc];

            if (show_trace) {
                const stdout = std.io.getStdOut().writer();
                try stdout.print("{:0>4}: {:0>4}: {any}\n", .{ self.ops_executed, self.pc, opcode });
            }

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
        // TODO: Move to deserialize time. Convert to montgomery if a field so it happens just once.
        if (op.bit_size == BitSize.Field and (op.value & (1 << 255)) == 0) {
            op.value = @as(u256, @bitCast(Bn254Fr.from_int(op.value).limbs)) | (1 << 255);
        }
        self.setSlot(op.destination, op.value);
        self.pc += 1;
        // std.debug.print("({}) set slot {} = {}\n", .{
        //     op.bit_size,
        //     op.destination.resolve(self.memory),
        //     op.value,
        // });
    }

    fn processIndirectConst(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const op = &opcode.IndirectConst;
        const dest_ptr_index = self.resolveSlot(op.destination_pointer);
        const dest_address = self.memory[dest_ptr_index];
        // TODO: Move to deserialize time. Convert to montgomery if a field so it happens just once.
        if (op.bit_size == BitSize.Field and (op.value & (1 << 255)) == 0) {
            op.value = @as(u256, @bitCast(Bn254Fr.from_int(op.value).limbs)) | (1 << 255);
        }
        self.setSlotAtIndex(@truncate(dest_address), op.value);
        self.pc += 1;
        // std.debug.print("({}) set slot {} = {}\n", .{
        //     op.bit_size,
        //     dest_address,
        //     op.value,
        // });
    }

    fn processCalldatacopy(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const op = &opcode.CalldataCopy;
        const size: usize = @truncate(self.getSlot(op.size_address));
        const offset: usize = @truncate(self.getSlot(op.offset_address));
        if (self.calldata.len < size) {
            self.trap();
            return;
        }
        for (0..size) |i| {
            const addr = self.resolveSlot(op.destination_address) + i;
            const src_index = offset + i;
            // std.debug.print("copy {} to slot {}\n", .{ calldata[src_index], addr });
            self.setSlotAtIndex(addr, self.calldata[src_index]);
        }
        self.pc += 1;
    }

    fn processCast(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const op = &opcode.Cast;
        switch (op.bit_size) {
            .Integer => |int_size| {
                root.bn254_fr_normalize(@ptrCast(self.getSlotAddr(op.source)));
                const mask = (@as(u256, 1) << getBitSize(int_size)) - 1;
                self.setSlot(op.destination, self.getSlot(op.source) & mask);
            },
            .Field => {
                self.setSlot(op.destination, self.getSlot(op.source));
            },
        }
        self.pc += 1;
    }

    fn processMov(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const mov = &opcode.Mov;
        self.setSlot(mov.destination, self.getSlot(mov.source));
        self.pc += 1;
        // std.io.getStdOut().writer().print("mov slot {} = {} (value: {})\n", .{
        //     mov.source.resolve(self.memory),
        //     mov.destination.resolve(self.memory),
        //     self.getSlot(mov.source),
        // }) catch unreachable;
    }

    fn processCmov(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const mov = &opcode.ConditionalMov;
        self.setSlot(
            mov.destination,
            if (self.getSlot(mov.condition) != 0) self.getSlot(mov.source_a) else self.getSlot(mov.source_b),
        );
        self.pc += 1;
    }

    fn processStore(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const store = &opcode.Store;
        self.setSlotAtIndex(@truncate(self.getSlot(store.destination_pointer)), self.getSlot(store.source));
        self.pc += 1;
    }

    fn processLoad(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const load = &opcode.Load;
        self.setSlot(load.destination, self.memory[@truncate(self.getSlot(load.source_pointer))]);
        self.pc += 1;
        // std.io.getStdOut().writer().print("load slot {} = {} (value: {})\n", .{
        //     load.destination.resolve(self.memory),
        //     self.memory[load.source_pointer.resolve(self.memory)],
        //     self.memory[@truncate(self.memory[load.source_pointer.resolve(self.memory)])],
        // }) catch unreachable;
    }

    fn processCall(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const call = &opcode.Call;
        self.callstack.append(self.pc + 1) catch unreachable;
        self.pc = @truncate(call.location);
    }

    fn processReturn(self: *BrilligVm, _: *BrilligOpcode) void {
        self.pc = self.callstack.pop();
    }

    fn processJump(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const jmp = &opcode.Jump;
        self.pc = @truncate(jmp.location);
    }

    fn processJumpIf(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const jmp = &opcode.JumpIf;
        self.pc = if (self.getSlot(jmp.condition) == 1) @truncate(jmp.location) else self.pc + 1;
    }

    fn processJumpIfNot(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const jmp = &opcode.JumpIfNot;
        self.pc = if (self.getSlot(jmp.condition) == 0) @truncate(jmp.location) else self.pc + 1;
    }

    fn processNot(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const not = &opcode.Not;
        // std.io.getStdOut().writer().print("{} = ", .{self.getSlot(not.source)}) catch unreachable;
        self.setSlot(not.destination, switch (not.bit_size) {
            .U1 => self.unaryNot(u1, not),
            .U8 => self.unaryNot(u8, not),
            .U16 => self.unaryNot(u16, not),
            .U32 => self.unaryNot(u32, not),
            .U64 => self.unaryNot(u64, not),
            .U128 => self.unaryNot(u128, not),
        });
        // std.io.getStdOut().writer().print("{}\n", .{self.getSlot(not.destination)}) catch unreachable;
        self.pc += 1;
    }

    fn processBinaryIntOp(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const int_op = &opcode.BinaryIntOp;
        self.setSlot(int_op.destination, switch (int_op.bit_size) {
            .U1 => self.binaryIntOp(u1, opcode.BinaryIntOp),
            .U8 => self.binaryIntOp(u8, opcode.BinaryIntOp),
            .U16 => self.binaryIntOp(u16, opcode.BinaryIntOp),
            .U32 => self.binaryIntOp(u32, opcode.BinaryIntOp),
            .U64 => self.binaryIntOp(u64, opcode.BinaryIntOp),
            .U128 => self.binaryIntOp(u128, opcode.BinaryIntOp),
        });
        self.pc += 1;
    }

    fn processBinaryFieldOp(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const field_op = &opcode.BinaryFieldOp;
        const lhs = self.getSlotAddr(field_op.lhs);
        const rhs = self.getSlotAddr(field_op.rhs);
        const dest = self.getSlotAddr(field_op.destination);
        switch (field_op.op) {
            .Add => root.bn254_fr_add(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .Mul => root.bn254_fr_mul(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .Sub => root.bn254_fr_sub(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .Div => if (!root.bn254_fr_div(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest))) self.trap(),
            .Equals => root.bn254_fr_eq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .LessThan => root.bn254_fr_lt(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .LessThanEquals => root.bn254_fr_leq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .IntegerDiv => {
                root.bn254_fr_normalize(@ptrCast(lhs));
                root.bn254_fr_normalize(@ptrCast(rhs));
                dest.* = lhs.* / rhs.*;
            },
        }
        self.pc += 1;
    }

    fn processBlackbox(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const blackbox_op = &opcode.BlackBox;

        const idx = @intFromEnum(blackbox_op.*);
        self.counters[idx] += 1;

        switch (blackbox_op.*) {
            .Sha256Compression => |op| {
                blackbox.blackbox_sha256_compression(
                    @ptrCast(self.getIndirectSlotAddr(op.input.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.hash_values.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.output.pointer)),
                );
            },
            .Blake2s => |op| {
                blackbox.blackbox_blake2s(
                    @ptrCast(self.getIndirectSlotAddr(op.message.pointer)),
                    @truncate(self.getSlot(op.message.size)),
                    @ptrCast(self.getIndirectSlotAddr(op.output.pointer)),
                );
            },
            .Blake3 => |op| {
                blackbox.blackbox_blake3(
                    @ptrCast(self.getIndirectSlotAddr(op.message.pointer)),
                    @truncate(self.getSlot(op.message.size)),
                    @ptrCast(self.getIndirectSlotAddr(op.output.pointer)),
                );
            },
            .Keccakf1600 => |op| {
                blackbox.blackbox_keccak1600(
                    @ptrCast(self.getIndirectSlotAddr(op.message.pointer)),
                    @truncate(self.memory[op.message.size]),
                    @ptrCast(self.getIndirectSlotAddr(op.output.pointer)),
                );
            },
            .Poseidon2Permutation => |op| {
                blackbox.blackbox_poseidon2_permutation(
                    @ptrCast(self.getIndirectSlotAddr(op.message.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.output.pointer)),
                    @truncate(self.getSlot(op.message.size)),
                );
            },
            // .PedersenCommitment => |op| {
            //     blackbox.blackbox_pedersen_commit(
            //         @ptrCast(self.getIndirectSlotAddr(op.inputs.pointer)),
            //         @truncate(self.getSlot(op.inputs.size)),
            //         @truncate(self.getSlot(op.domain_separator)),
            //         @ptrCast(self.getIndirectSlotAddr(op.output.pointer)),
            //     );
            // },
            // .PedersenHash => |op| {
            //     blackbox.blackbox_pedersen_hash(
            //         @ptrCast(self.getIndirectSlotAddr(op.inputs.pointer)),
            //         @truncate(self.getSlot(op.inputs.size)),
            //         @truncate(self.getSlot(op.domain_separator)),
            //         @ptrCast(self.getSlotAddr(op.output)),
            //     );
            // },
            .ToRadix => |op| {
                blackbox.blackbox_to_radix(
                    @ptrCast(self.getSlotAddr(op.input)),
                    @ptrCast(self.getIndirectSlotAddr(op.output.pointer)),
                    @truncate(op.output.size),
                    @truncate(self.getSlot(op.radix)),
                );
            },
            .AES128Encrypt => |op| {
                blackbox.blackbox_aes_encrypt(
                    @ptrCast(self.getIndirectSlotAddr(op.inputs.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.iv.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.key.pointer)),
                    @truncate(self.getSlot(op.inputs.size)),
                    @ptrCast(self.getIndirectSlotAddr(op.outputs.pointer)),
                    @ptrCast(self.getSlotAddr(op.outputs.size)),
                );
            },
            .EcdsaSecp256k1 => |op| {
                blackbox.blackbox_secp256k1_verify_signature(
                    @ptrCast(self.getIndirectSlotAddr(op.hashed_msg.pointer)),
                    @truncate(self.getSlot(op.hashed_msg.size)),
                    @ptrCast(self.getIndirectSlotAddr(op.public_key_x.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.public_key_y.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.signature.pointer)),
                    @ptrCast(self.getSlotAddr(op.result)),
                );
            },
            .EcdsaSecp256r1 => |op| {
                blackbox.blackbox_secp256r1_verify_signature(
                    @ptrCast(self.getIndirectSlotAddr(op.hashed_msg.pointer)),
                    @truncate(self.getSlot(op.hashed_msg.size)),
                    @ptrCast(self.getIndirectSlotAddr(op.public_key_x.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.public_key_y.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.signature.pointer)),
                    @ptrCast(self.getSlotAddr(op.result)),
                );
            },
            .SchnorrVerify => |op| {
                blackbox.blackbox_schnorr_verify_signature(
                    @ptrCast(self.getIndirectSlotAddr(op.message.pointer)),
                    @truncate(self.getSlot(op.message.size)),
                    @ptrCast(self.getSlotAddr(op.public_key_x)),
                    @ptrCast(self.getSlotAddr(op.public_key_y)),
                    @ptrCast(self.getIndirectSlotAddr(op.signature.pointer)),
                    @ptrCast(self.getSlotAddr(op.result)),
                );
            },
            .MultiScalarMul => |op| {
                blackbox.blackbox_msm(
                    @ptrCast(self.getIndirectSlotAddr(op.points.pointer)),
                    @truncate(self.getSlot(op.points.size)),
                    @ptrCast(self.getIndirectSlotAddr(op.scalars.pointer)),
                    @ptrCast(self.getIndirectSlotAddr(op.outputs.pointer)),
                );
            },
            .EmbeddedCurveAdd => |op| {
                blackbox.blackbox_ecc_add(
                    @ptrCast(self.getSlotAddr(op.input1_x)),
                    @ptrCast(self.getSlotAddr(op.input1_y)),
                    @ptrCast(self.getSlotAddr(op.input1_infinite)),
                    @ptrCast(self.getSlotAddr(op.input2_x)),
                    @ptrCast(self.getSlotAddr(op.input2_y)),
                    @ptrCast(self.getSlotAddr(op.input2_infinite)),
                    @ptrCast(self.getIndirectSlotAddr(op.result.pointer)),
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

    fn processStop(self: *BrilligVm, opcode: *BrilligOpcode) void {
        const op = &opcode.Stop;
        self.halted = true;
        self.return_data = self.memory[op.return_data_offset .. op.return_data_offset + op.return_data_size];
        for (self.return_data) |*v| root.bn254_fr_normalize(@ptrCast(v));
    }

    fn processTrap(self: *BrilligVm, _: *BrilligOpcode) void {
        self.trap();
        std.debug.print("Trap! (todo print revert_data)\n", .{});
    }

    pub fn dumpMem(self: *BrilligVm, n: usize) void {
        for (0..n) |i| {
            std.debug.print("{:0>3}: 0x{x:0>64}\n", .{ i, self.memory[i] });
        }
    }

    pub fn dumpStats(self: *BrilligVm) void {
        std.debug.print("Opcodes executed: {}\n", .{self.ops_executed});
        std.debug.print("Max slot set: {}\n", .{self.max_slot_set});

        // Print the counters next to the enum variant names
        std.debug.print("Blackbox calls:\n", .{});
        inline for (@typeInfo(io.BlackBoxOp).Union.fields, 0..) |enumField, idx| {
            std.debug.print("  {s}: {}\n", .{ enumField.name, self.counters[idx] });
        }
    }

    fn binaryIntOp(self: *BrilligVm, comptime int_type: type, op: anytype) int_type {
        const lhs: int_type = @truncate(self.getSlot(op.lhs));
        const rhs: int_type = @truncate(self.getSlot(op.rhs));
        const bit_size = @bitSizeOf(int_type);
        const r = switch (op.op) {
            .Add => lhs +% rhs,
            .Sub => lhs -% rhs,
            .Div => if (rhs != 0) lhs / rhs else blk: {
                self.trap();
                break :blk 0;
            },
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
        // std.io.getStdOut().writer().print("({}) {} op {} = {}\n", .{ int_type, lhs, rhs, r }) catch unreachable;
        return r;
    }

    inline fn unaryNot(self: *BrilligVm, comptime int_type: type, op: anytype) int_type {
        return @truncate(~self.memory[op.source.resolve(self.memory)]);
    }

    inline fn resolveSlot(self: *BrilligVm, mem_address: io.MemoryAddress) usize {
        return mem_address.resolve(self.memory);
    }

    inline fn getSlot(self: *BrilligVm, mem_address: io.MemoryAddress) u256 {
        return self.memory[mem_address.resolve(self.memory)];
    }

    inline fn getSlotAddr(self: *BrilligVm, mem_address: io.MemoryAddress) *align(32) u256 {
        return &self.memory[mem_address.resolve(self.memory)];
    }

    inline fn getIndirectSlotAddr(self: *BrilligVm, mem_address: io.MemoryAddress) *align(32) u256 {
        return &self.memory[@truncate(self.getSlot(mem_address))];
    }

    inline fn setSlot(self: *BrilligVm, mem_address: io.MemoryAddress, value: u256) void {
        self.setSlotAtIndex(mem_address.resolve(self.memory), value);
    }

    inline fn setSlotAtIndex(self: *BrilligVm, index: usize, value: u256) void {
        if (self.max_slot_set < index) {
            self.max_slot_set = index;
        }
        self.memory[index] = value;
    }

    inline fn trap(self: *BrilligVm) void {
        self.trapped = true;
        self.halted = true;
    }
};

fn getBitSize(int_size: io.IntegerBitSize) u8 {
    return switch (int_size) {
        .U1 => 1,
        .U8 => 8,
        .U16 => 16,
        .U32 => 32,
        .U64 => 64,
        .U128 => 128,
    };
}
