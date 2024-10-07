const std = @import("std");
const deserializeOpcodes = @import("io.zig").deserializeOpcodes;
const AvmOpcode = @import("io.zig").AvmOpcode;
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

    // TODO: HACKING IN A VALUE FOR NOW.
    var calldata_arr = [_]u256{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var calldata: []u256 = &calldata_arr;
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
    var avm = try AztecVm.init(allocator, calldata);
    defer avm.deinit(allocator);
    std.debug.print("Init time: {}us\n", .{t.read() / 1000});

    std.debug.print("Executing...\n", .{});
    t.reset();
    const result = avm.executeVm(opcodes, options.show_trace);
    std.debug.print("time taken: {}us\n", .{t.read() / 1000});
    // if (show_stats) avm.dumpStats();
    avm.dumpMem(10, 0);
    return result;
}

extern fn mlock(addr: ?*u8, len: usize) callconv(.C) i32;

const AztecVm = struct {
    const mem_size = 1024 * 1024 * 250;
    memory: []align(4096) u256,
    memory_tags: []align(4096) io.Tag,
    calldata: []u256,
    callstack: std.ArrayList(u64),
    pc: u64 = 0,
    halted: bool = false,
    trapped: bool = false,
    ops_executed: u64 = 0,
    storage: std.AutoHashMap(u256, u256),
    // counters: [@typeInfo(io.BlackBoxOp).Union.fields.len]usize,

    pub fn init(allocator: std.mem.Allocator, calldata: []u256) !AztecVm {
        const vm = AztecVm{
            .memory = try allocator.alignedAlloc(u256, 4096, mem_size),
            .memory_tags = try allocator.alignedAlloc(io.Tag, 4096, mem_size),
            .calldata = calldata,
            .callstack = try std.ArrayList(u64).initCapacity(allocator, 1024),
            .storage = std.AutoHashMap(u256, u256).init(allocator),
            // .counters = std.mem.zeroes([@typeInfo(io.BlackBoxOp).Union.fields.len]usize),
        };

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

    pub fn deinit(self: *AztecVm, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
    }

    pub fn executeVm(self: *AztecVm, opcodes: []AvmOpcode, show_trace: bool) !void {
        while (!self.halted) {
            const opcode = &opcodes[self.pc];

            if (show_trace) {
                std.debug.print("{:0>4}: {:0>4}: {any}\n", .{ self.ops_executed, self.pc, opcode });
            }

            switch (opcode.*) {
                .SET_8 => |op| self.processSet(op),
                .SET_16 => |op| self.processSet(op),
                .SET_32 => |op| self.processSet(op),
                .SET_64 => |op| self.processSet(op),
                .SET_128 => |op| self.processSet(op),
                .SET_FF => |op| self.processSet(op),
                .MOV_8 => |op| self.processMov(op),
                .MOV_16 => |op| self.processMov(op),
                .CAST_8 => |op| self.processCast(op),
                .CAST_16 => |op| self.processCast(op),
                .CALLDATACOPY => |op| self.processCalldatacopy(op),
                .INTERNALCALL => |op| {
                    try self.callstack.append(self.pc);
                    self.pc = op.address - 1;
                },
                .INTERNALRETURN => self.pc = self.callstack.pop(),
                .EQ_8 => |op| self.processEq(op),
                .EQ_16 => |op| self.processEq(op),
                .LT_8 => |op| self.processLt(op),
                .LT_16 => |op| self.processLt(op),
                .LTE_8 => |op| self.processLte(op),
                .LTE_16 => |op| self.processLte(op),
                .ADD_8 => |op| self.processAdd(op),
                .ADD_16 => |op| self.processAdd(op),
                .SUB_8 => |op| self.processSub(op),
                .SUB_16 => |op| self.processSub(op),
                .MUL_8 => |op| self.processMul(op),
                .MUL_16 => |op| self.processMul(op),
                .DIV_8 => |op| self.processDiv(op),
                .DIV_16 => |op| self.processDiv(op),
                .NOT_8 => |op| self.processNot(op),
                .NOT_16 => |op| self.processNot(op),
                .JUMP_16 => |op| self.pc = op.address - 1,
                .JUMPI_16 => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    if (self.memory[op.condition_slot] != 0) {
                        self.pc = op.address - 1;
                    }
                },
                .RETURN => self.halted = true,
                .DEBUGLOG => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    self.dumpMem(@truncate(self.memory[op.fields_size_slot]), @truncate(self.memory[op.fields_slot]));
                },
                .SSTORE => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    try self.storage.put(self.memory[op.slot_slot], self.memory[op.value_slot]);
                },
                .SLOAD => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    self.memory[op.dst_slot] = self.storage.get(self.memory[op.slot_slot]) orelse 0;
                    self.memory_tags[op.dst_slot] = io.Tag.FF;
                },
                .GETENVVAR_16 => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    // TODO.
                    self.memory[op.dst_slot] = 0;
                },
                .TORADIXLE => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    blackbox.blackbox_to_radix(
                        @ptrCast(&self.memory[op.src_slot]),
                        @ptrCast(&self.memory[op.dst_slot]),
                        op.num_limbs,
                        @truncate(self.memory[op.radix_slot]),
                    );
                },
                .REVERT_8, .REVERT_16 => {
                    self.trapped = true;
                    self.halted = true;
                },
                else => {
                    std.debug.print("Unimplemented: {any}\n", .{opcode.*});
                    return error.Unimplemented;
                },
            }
            self.pc += 1;
            self.ops_executed += 1;
        }

        if (self.trapped) {
            return error.Trapped;
        }
    }

    // Given an opcode struct, dereferences any memory slot fields that are signalled to be indirect.
    // Returns a new opcode struct whereby each operand can be accessed directly.
    fn derefOpcodeSlots(self: *AztecVm, comptime T: type, opcode_in: T) T {
        var opcode = opcode_in;
        comptime var slot_field_index: usize = 0;
        inline for (@typeInfo(@TypeOf(opcode)).Struct.fields) |field| {
            if (comptime std.mem.endsWith(u8, field.name, "_slot")) {
                const is_indirect = (opcode.indirect >> slot_field_index) & 0x1 == 1;
                if (is_indirect) {
                    @field(opcode, field.name) = @truncate(self.memory[@field(opcode, field.name)]);
                }
                slot_field_index += 1;
            }
        }
        return opcode;
    }

    fn processSet(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        self.memory[op.dst_slot] = op.value;
        self.memory_tags[op.dst_slot] = op.tag;
    }

    fn processMov(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        self.memory[op.dst_slot] = self.memory[op.src_slot];
        self.memory_tags[op.dst_slot] = self.memory_tags[op.src_slot];
    }

    fn processEq(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        self.memory[op.op3_slot] = @intFromBool(self.memory[op.op1_slot] == self.memory[op.op2_slot]);
    }

    fn processLt(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        self.memory[op.op3_slot] = @intFromBool(self.memory[op.op1_slot] < self.memory[op.op2_slot]);
        self.memory_tags[op.op3_slot] = io.Tag.UINT1;
    }

    fn processLte(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        self.memory[op.op3_slot] = @intFromBool(self.memory[op.op1_slot] <= self.memory[op.op2_slot]);
        self.memory_tags[op.op3_slot] = io.Tag.UINT1;
    }

    fn processAdd(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        const op1 = self.memory[op.op1_slot];
        const op2 = self.memory[op.op2_slot];
        const mask = getBitMask(self.memory_tags[op.op1_slot]);
        self.memory[op.op3_slot] = (op1 +% op2) & mask;
        self.memory_tags[op.op3_slot] = self.memory_tags[op.op1_slot];
        // std.debug.print("op1: {} op2: {} op3: {} mask: {x}\n", .{ op1, op2, self.memory[op.op3_slot], mask });
    }

    fn processSub(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        const op1 = self.memory[op.op1_slot];
        const op2 = self.memory[op.op2_slot];
        const mask = getBitMask(self.memory_tags[op.op1_slot]);
        self.memory[op.op3_slot] = (op1 -% op2) & mask;
        self.memory_tags[op.op3_slot] = self.memory_tags[op.op1_slot];
        // std.debug.print("op1: {} op2: {} op3: {} mask: {x}\n", .{ op1, op2, self.memory[op.op3_slot], mask });
    }

    fn processMul(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        const op1 = self.memory[op.op1_slot];
        const op2 = self.memory[op.op2_slot];
        const mask = getBitMask(self.memory_tags[op.op1_slot]);
        self.memory[op.op3_slot] = (op1 *% op2) & mask;
        self.memory_tags[op.op3_slot] = self.memory_tags[op.op1_slot];
        // std.debug.print("op1: {} op2: {} op3: {} mask: {x}\n", .{ op1, op2, self.memory[op.op3_slot], mask });
    }

    fn processDiv(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        const op1 = self.memory[op.op1_slot];
        const op2 = self.memory[op.op2_slot];
        // const mask = getBitMask(self.memory_tags[op.op1_slot]);
        self.memory[op.op3_slot] = (op1 / op2);
        self.memory_tags[op.op3_slot] = self.memory_tags[op.op1_slot];
        // std.debug.print("op1: {} op2: {} op3: {} mask: {x}\n", .{ op1, op2, self.memory[op.op3_slot], mask });
    }

    fn processNot(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        const mask = getBitMask(self.memory_tags[op.op1_slot]);
        const op1 = self.memory[op.op1_slot];
        self.memory[op.op2_slot] = (~op1) & mask;
        self.memory_tags[op.op2_slot] = self.memory_tags[op.op1_slot];
        // std.debug.print("op1: {} op2: {} mask: {}\n", .{ op1, self.memory[op.op2_slot], mask });
    }

    fn processCast(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        const mask = getBitMask(op.tag);
        self.memory[op.op2_slot] = self.memory[op.op1_slot] & mask;
        self.memory_tags[op.op2_slot] = op.tag;
    }

    fn processCalldatacopy(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        const size: u64 = @truncate(self.memory[op.size_slot]);
        const start_slot: u64 = @truncate(self.memory[op.start_slot]);
        // std.debug.print("cdc {} {}\n", .{ size, start_slot });
        if (self.calldata.len < size) {
            self.halted = true;
            self.trapped = true;
            return;
        }
        for (0..size) |i| {
            const addr = op.dst_slot + i;
            const src_index = start_slot + i;
            // std.debug.print("copy {} to slot {}\n", .{ self.calldata[src_index], addr });
            self.memory[addr] = self.calldata[src_index];
            self.memory_tags[addr] = io.Tag.FF;
        }
    }

    // fn processCast(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const op = &opcode.Cast;
    //     switch (op.bit_size) {
    //         .Integer => |int_size| {
    //             root.bn254_fr_normalize(@ptrCast(&self.memory[op.source]));
    //             const mask = (@as(u256, 1) << getBitSize(int_size)) - 1;
    //             self.memory[op.destination] = self.memory[op.source] & mask;
    //         },
    //         .Field => {
    //             self.memory[op.destination] = self.memory[op.source];
    //         },
    //     }
    //     self.pc += 1;
    // }

    // fn processCmov(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const mov = &opcode.ConditionalMov;
    //     self.memory[mov.destination] = self.memory[if (self.memory[mov.condition] != 0) mov.source_a else mov.source_b];
    //     self.pc += 1;
    // }

    // fn processStore(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const store = &opcode.Store;
    //     self.memory[@truncate(self.memory[store.destination_pointer])] = self.memory[store.source];
    //     self.pc += 1;
    // }

    // fn processLoad(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const load = &opcode.Load;
    //     self.memory[load.destination] = self.memory[@truncate(self.memory[load.source_pointer])];
    //     self.pc += 1;
    // }

    // fn processCall(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const call = &opcode.Call;
    //     self.callstack.append(self.pc + 1) catch unreachable;
    //     self.pc = call.location;
    // }

    // fn processReturn(self: *AztecVm, _: *AvmOpcode) void {
    //     self.pc = self.callstack.pop();
    // }

    // fn processJump(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const jmp = &opcode.Jump;
    //     self.pc = jmp.location;
    // }

    // fn processJumpIf(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const jmp = &opcode.JumpIf;
    //     self.pc = if (self.memory[jmp.condition] == 1) jmp.location else self.pc + 1;
    // }

    // fn processJumpIfNot(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const jmp = &opcode.JumpIfNot;
    //     self.pc = if (self.memory[jmp.condition] == 0) jmp.location else self.pc + 1;
    // }

    // fn processNot(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const not = &opcode.Not;
    //     self.memory[not.destination] = switch (not.bit_size) {
    //         .U0 => unreachable,
    //         .U1 => self.unaryNot(u1, not),
    //         .U8 => self.unaryNot(u8, not),
    //         .U16 => self.unaryNot(u16, not),
    //         .U32 => self.unaryNot(u32, not),
    //         .U64 => self.unaryNot(u64, not),
    //         .U128 => self.unaryNot(u128, not),
    //     };
    //     self.pc += 1;
    // }

    // fn processBinaryIntOp(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const int_op = &opcode.BinaryIntOp;
    //     self.memory[int_op.destination] = switch (int_op.bit_size) {
    //         .U0 => unreachable,
    //         .U1 => self.binaryIntOp(u1, opcode.BinaryIntOp),
    //         .U8 => self.binaryIntOp(u8, opcode.BinaryIntOp),
    //         .U16 => self.binaryIntOp(u16, opcode.BinaryIntOp),
    //         .U32 => self.binaryIntOp(u32, opcode.BinaryIntOp),
    //         .U64 => self.binaryIntOp(u64, opcode.BinaryIntOp),
    //         .U128 => self.binaryIntOp(u128, opcode.BinaryIntOp),
    //     };
    //     self.pc += 1;
    // }

    // fn processBinaryFieldOp(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const field_op = &opcode.BinaryFieldOp;
    //     const lhs = &self.memory[field_op.lhs];
    //     const rhs = &self.memory[field_op.rhs];
    //     const dest = &self.memory[field_op.destination];
    //     switch (field_op.op) {
    //         .Add => root.bn254_fr_add(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
    //         .Mul => root.bn254_fr_mul(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
    //         .Sub => root.bn254_fr_sub(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
    //         .Div => root.bn254_fr_div(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
    //         .Equals => root.bn254_fr_eq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
    //         .LessThan => root.bn254_fr_lt(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
    //         .LessThanEquals => root.bn254_fr_leq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
    //         else => unreachable,
    //     }
    //     self.pc += 1;
    // }

    // fn processBlackbox(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const blackbox_op = &opcode.BlackBox;
    //     const memory = self.memory;

    //     const idx = @intFromEnum(blackbox_op.*);
    //     self.counters[idx] += 1;

    //     switch (blackbox_op.*) {
    //         .Sha256Compression => |op| {
    //             blackbox.blackbox_sha256_compression(
    //                 @ptrCast(&memory[@truncate(memory[op.input.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.hash_values.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
    //             );
    //         },
    //         .Blake2s => |op| {
    //             blackbox.blackbox_blake2s(
    //                 @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
    //                 @truncate(memory[op.message.size]),
    //                 @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
    //             );
    //         },
    //         .Blake3 => |op| {
    //             blackbox.blackbox_blake3(
    //                 @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
    //                 @truncate(memory[op.message.size]),
    //                 @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
    //             );
    //         },
    //         .Keccakf1600 => |op| {
    //             blackbox.blackbox_keccak1600(
    //                 @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
    //                 @truncate(memory[op.message.size]),
    //                 @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
    //             );
    //         },
    //         .Poseidon2Permutation => |op| {
    //             blackbox.blackbox_poseidon2_permutation(
    //                 @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
    //                 @truncate(memory[op.message.size]),
    //             );
    //         },
    //         .PedersenCommitment => |op| {
    //             blackbox.blackbox_pedersen_commit(
    //                 @ptrCast(&memory[@truncate(memory[op.inputs.pointer])]),
    //                 @truncate(memory[op.inputs.size]),
    //                 @truncate(memory[op.domain_separator]),
    //                 @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
    //             );
    //         },
    //         .PedersenHash => |op| {
    //             blackbox.blackbox_pedersen_hash(
    //                 @ptrCast(&memory[@truncate(memory[op.inputs.pointer])]),
    //                 @truncate(memory[op.inputs.size]),
    //                 @truncate(memory[op.domain_separator]),
    //                 @ptrCast(&memory[op.output]),
    //             );
    //         },
    //         .ToRadix => |op| {
    //             blackbox.blackbox_to_radix(
    //                 @ptrCast(&memory[op.input]),
    //                 @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
    //                 op.output.size,
    //                 @truncate(memory[op.radix]),
    //             );
    //         },
    //         .AES128Encrypt => |op| {
    //             blackbox.blackbox_aes_encrypt(
    //                 @ptrCast(&memory[@truncate(memory[op.inputs.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.iv.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.key.pointer])]),
    //                 @truncate(memory[op.inputs.size]),
    //                 @ptrCast(&memory[@truncate(memory[op.outputs.pointer])]),
    //                 @ptrCast(&memory[op.outputs.size]),
    //             );
    //         },
    //         .EcdsaSecp256k1 => |op| {
    //             blackbox.blackbox_secp256k1_verify_signature(
    //                 @ptrCast(&memory[@truncate(memory[op.hashed_msg.pointer])]),
    //                 @truncate(memory[op.hashed_msg.size]),
    //                 @ptrCast(&memory[@truncate(memory[op.public_key_x.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.public_key_y.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.signature.pointer])]),
    //                 @ptrCast(&memory[op.result]),
    //             );
    //         },
    //         .EcdsaSecp256r1 => |op| {
    //             blackbox.blackbox_secp256r1_verify_signature(
    //                 @ptrCast(&memory[@truncate(memory[op.hashed_msg.pointer])]),
    //                 @truncate(memory[op.hashed_msg.size]),
    //                 @ptrCast(&memory[@truncate(memory[op.public_key_x.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.public_key_y.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.signature.pointer])]),
    //                 @ptrCast(&memory[op.result]),
    //             );
    //         },
    //         .SchnorrVerify => |op| {
    //             blackbox.blackbox_schnorr_verify_signature(
    //                 @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
    //                 @truncate(memory[op.message.size]),
    //                 @ptrCast(&memory[op.public_key_x]),
    //                 @ptrCast(&memory[op.public_key_y]),
    //                 @ptrCast(&memory[@truncate(memory[op.signature.pointer])]),
    //                 @ptrCast(&memory[op.result]),
    //             );
    //         },
    //         .MultiScalarMul => |op| {
    //             blackbox.blackbox_msm(
    //                 @ptrCast(&memory[@truncate(memory[op.points.pointer])]),
    //                 @truncate(memory[op.points.size]),
    //                 @ptrCast(&memory[@truncate(memory[op.scalars.pointer])]),
    //                 @ptrCast(&memory[@truncate(memory[op.outputs.pointer])]),
    //             );
    //         },
    //         .EmbeddedCurveAdd => |op| {
    //             blackbox.blackbox_ecc_add(
    //                 @ptrCast(&memory[op.input1_x]),
    //                 @ptrCast(&memory[op.input1_y]),
    //                 @ptrCast(&memory[op.input1_infinite]),
    //                 @ptrCast(&memory[op.input2_x]),
    //                 @ptrCast(&memory[op.input2_y]),
    //                 @ptrCast(&memory[op.input2_infinite]),
    //                 @ptrCast(&memory[@truncate(memory[op.result.pointer])]),
    //             );
    //         },
    //         else => {
    //             std.debug.print("Unimplemented: {}\n", .{blackbox_op});
    //             unreachable;
    //         },
    //     }
    //     self.pc += 1;
    // }

    // fn processForeignCall(self: *AztecVm, opcode: *AvmOpcode) void {
    //     const fc = &opcode.ForeignCall;
    //     if (std.mem.eql(u8, "print", fc.function)) {
    //         std.debug.print("print called\n", .{});
    //     } else {
    //         std.debug.print("Unimplemented: {s}\n", .{fc.function});
    //         unreachable;
    //     }
    //     self.pc += 1;
    // }

    // fn processStop(self: *AztecVm, _: *AvmOpcode) void {
    //     self.halted = true;
    // }

    // fn processTrap(self: *AztecVm, _: *AvmOpcode) void {
    //     self.halted = true;
    //     self.trapped = true;
    //     std.debug.print("Trap! (todo print revert_data)\n", .{});
    // }

    pub fn dumpMem(self: *AztecVm, n: usize, offset: usize) void {
        for (offset..offset + n) |i| {
            std.debug.print("{:0>3}: 0x{x:0>64}\n", .{ i, self.memory[i] });
        }
    }

    // pub fn dumpStats(self: *AztecVm) void {
    //     std.debug.print("Opcodes executed: {}\n", .{self.ops_executed});

    //     // Print the counters next to the enum variant names
    //     std.debug.print("Blackbox calls:\n", .{});
    //     inline for (@typeInfo(io.BlackBoxOp).Union.fields, 0..) |enumField, idx| {
    //         std.debug.print("  {s}: {}\n", .{ enumField.name, self.counters[idx] });
    //     }
    // }

    // fn binaryIntOp(self: *AztecVm, comptime int_type: type, op: anytype) int_type {
    //     const lhs: int_type = @truncate(self.memory[op.lhs]);
    //     const rhs: int_type = @truncate(self.memory[op.rhs]);
    //     const bit_size = @bitSizeOf(int_type);
    //     const r = switch (op.op) {
    //         .Add => lhs +% rhs,
    //         .Sub => lhs -% rhs,
    //         .Div => lhs / rhs,
    //         .Mul => lhs *% rhs,
    //         .And => lhs & rhs,
    //         .Or => lhs | rhs,
    //         .Xor => lhs ^ rhs,
    //         .Shl => if (rhs < bit_size) lhs << @truncate(rhs) else 0,
    //         .Shr => if (rhs < bit_size) lhs >> @truncate(rhs) else 0,
    //         .Equals => @intFromBool(lhs == rhs),
    //         .LessThan => @intFromBool(lhs < rhs),
    //         .LessThanEquals => @intFromBool(lhs <= rhs),
    //     };
    //     // std.debug.print("{} op {} = {}\n", .{ lhs, rhs, r });
    //     return r;
    // }

    // fn unaryNot(self: *AztecVm, comptime int_type: type, op: anytype) int_type {
    //     const rhs: int_type = @truncate(~self.memory[op.source]);
    //     return rhs;
    // }
};

fn getBitSize(int_size: io.Tag) u8 {
    return switch (int_size) {
        .UINT1 => 1,
        .UINT8 => 8,
        .UINT16 => 16,
        .UINT32 => 32,
        .UINT64 => 64,
        .UINT128 => 128,
        else => unreachable,
    };
}

fn getBitMask(int_size: io.Tag) u256 {
    return switch (int_size) {
        .UINT1 => 0x1,
        .UINT8 => 0xFF,
        .UINT16 => 0xFFFF,
        .UINT32 => 0xFFFFFFFF,
        .UINT64 => 0xFFFFFFFFFFFFFFFF,
        .UINT128 => 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
        .FF => 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
        else => unreachable,
    };
}
