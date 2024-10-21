const std = @import("std");
const builtin = @import("builtin");
const deserializeOpcodes = @import("io.zig").deserializeOpcodes;
const AvmOpcode = @import("io.zig").AvmOpcode32;
const io = @import("io.zig");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const blackbox = @import("../blackbox/blackbox.zig");
const fieldOps = @import("../blackbox/field.zig");

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
    // const mem_size = 1024 * 1024 * 250;
    const mem_size = 1024 * 1024 * 32;
    memory: []align(4096) u256,
    memory_tags: []align(4096) io.Tag,
    calldata: []u256,
    callstack: std.ArrayList(usize),
    pc: usize = 0,
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
            .callstack = try std.ArrayList(usize).initCapacity(allocator, 1024),
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
        if (builtin.mode == .Debug) {
            @memset(vm.memory_tags, io.Tag.UNSET);
        }
        return vm;
    }

    pub fn deinit(self: *AztecVm, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
    }

    pub fn executeVm(self: *AztecVm, opcodes: []AvmOpcode, show_trace: bool) !void {
        while (!self.halted) {
            const opcode = &opcodes[self.pc];

            if (show_trace) {
                const stdout = std.io.getStdOut().writer();
                try stdout.print("{:0>4}: {:0>4}: {any}\n", .{ self.ops_executed, self.pc, opcode });
            }

            switch (opcode.*) {
                .SET8 => |op| self.processSet(op),
                .SET16 => |op| self.processSet(op),
                .SET32 => |op| self.processSet(op),
                .SET64 => |op| self.processSet(op),
                .SET128 => |op| self.processSet(op),
                .SETFF => |op| self.processSet(op),
                .MOV => |op| self.processMov(op),
                .CAST => |op| self.processCast(op),
                .CALLDATACOPY => |op| self.processCalldatacopy(op),
                .INTERNALCALL => |op| {
                    try self.callstack.append(self.pc);
                    self.pc = op.address - 1;
                },
                .INTERNALRETURN => self.pc = self.callstack.pop(),
                .EQ => |op| self.binaryOp(opcode, op),
                .LT => |op| self.binaryOp(opcode, op),
                .LTE => |op| self.binaryOp(opcode, op),
                .ADD => |op| self.binaryOp(opcode, op),
                .SUB => |op| self.binaryOp(opcode, op),
                .MUL => |op| self.binaryOp(opcode, op),
                .DIV => |op| self.binaryOp(opcode, op),
                .FDIV => |op| self.binaryOp(opcode, op),
                .AND => |op| self.binaryOp(opcode, op),
                .OR => |op| self.binaryOp(opcode, op),
                .SHL => |op| self.binaryOp(opcode, op),
                .SHR => |op| self.binaryOp(opcode, op),
                .XOR => |op| self.binaryOp(opcode, op),
                .NOT => |op| self.unaryOp(opcode, op),
                .JUMP => |op| self.pc = op.address - 1,
                .JUMPI => |o| {
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
                .GETENVVAR => |o| {
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
                    if (o.output_bits == 1) {
                        @memset(self.memory_tags[op.dst_slot .. op.dst_slot + op.num_limbs], io.Tag.U1);
                    } else {
                        @memset(self.memory_tags[op.dst_slot .. op.dst_slot + op.num_limbs], io.Tag.U8);
                    }
                },
                .SHA256COMPRESSION => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    blackbox.blackbox_sha256_compression(
                        @ptrCast(&self.memory[op.inputs_slot]),
                        @ptrCast(&self.memory[op.state_slot]),
                        @ptrCast(&self.memory[op.output_slot]),
                    );
                    @memset(self.memory_tags[op.output_slot .. op.output_slot + 16], io.Tag.U32);
                },
                .MSM => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    blackbox.blackbox_msm(
                        @ptrCast(&self.memory[op.points_slot]),
                        @truncate(self.memory[op.size_slot]),
                        @ptrCast(&self.memory[op.scalars_slot]),
                        @ptrCast(&self.memory[op.dst_slot]),
                    );
                    self.memory_tags[op.dst_slot] = io.Tag.FF;
                    self.memory_tags[op.dst_slot + 1] = io.Tag.FF;
                    self.memory_tags[op.dst_slot + 2] = io.Tag.U1;
                },
                .ECADD => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    blackbox.blackbox_ecc_add(
                        @ptrCast(&self.memory[op.lhs_x_slot]),
                        @ptrCast(&self.memory[op.lhs_y_slot]),
                        @ptrCast(&self.memory[op.lhs_inf_slot]),
                        @ptrCast(&self.memory[op.rhs_x_slot]),
                        @ptrCast(&self.memory[op.rhs_y_slot]),
                        @ptrCast(&self.memory[op.rhs_inf_slot]),
                        @ptrCast(&self.memory[op.dst_slot]),
                    );
                    self.memory_tags[op.dst_slot] = io.Tag.FF;
                    self.memory_tags[op.dst_slot + 1] = io.Tag.FF;
                    self.memory_tags[op.dst_slot + 2] = io.Tag.U1;
                },
                .KECCAKF1600 => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    blackbox.blackbox_keccak1600(
                        @ptrCast(&self.memory[op.msg_slot]),
                        @truncate(self.memory[op.size_slot]),
                        @ptrCast(&self.memory[op.dst_slot]),
                    );
                    @memset(self.memory_tags[op.dst_slot .. op.dst_slot + 25], io.Tag.U64);
                },
                .PEDERSEN => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    blackbox.blackbox_pedersen_hash(
                        @ptrCast(&self.memory[op.msg_slot]),
                        @truncate(self.memory[op.size_slot]),
                        @truncate(self.memory[op.index_slot]),
                        @ptrCast(&self.memory[op.dest_slot]),
                    );
                    self.memory_tags[op.dest_slot] = io.Tag.FF;
                },
                .PEDERSENCOMMITMENT => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    blackbox.blackbox_pedersen_commit(
                        @ptrCast(&self.memory[op.msg_slot]),
                        @truncate(self.memory[op.size_slot]),
                        @truncate(self.memory[op.index_slot]),
                        @ptrCast(&self.memory[op.dest_slot]),
                    );
                    @memset(self.memory_tags[op.dest_slot .. op.dest_slot + 2], io.Tag.FF);
                },
                .POSEIDON2 => |o| {
                    const op = self.derefOpcodeSlots(@TypeOf(o), o);
                    blackbox.blackbox_poseidon2_permutation(
                        @ptrCast(&self.memory[op.input_slot]),
                        @ptrCast(&self.memory[op.output_slot]),
                        0,
                    );
                    @memset(self.memory_tags[op.output_slot .. op.output_slot + 4], io.Tag.FF);
                },
                .REVERT => {
                    self.trap();
                },
                .NOOP => {},
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
        comptime var num_slot_operands: usize = 0;
        comptime for (@typeInfo(@TypeOf(opcode)).Struct.fields) |field| {
            if (std.mem.endsWith(u8, field.name, "_slot")) {
                num_slot_operands += 1;
            }
        };
        inline for (@typeInfo(@TypeOf(opcode)).Struct.fields) |field| {
            if (comptime std.mem.endsWith(u8, field.name, "_slot")) {
                const is_indirect = (opcode.indirect >> slot_field_index) & 0x1 == 1;
                const is_relative = (opcode.indirect >> (num_slot_operands + slot_field_index)) & 0x1 == 1;
                if (is_relative) {
                    // std.debug.print("deref relative {} to {}\n", .{ @field(opcode, field.name), self.memory[0] + @field(opcode, field.name) });
                    @field(opcode, field.name) = @truncate(self.memory[0] + @field(opcode, field.name));
                }
                if (is_indirect) {
                    // std.debug.print("deref indirect {} to {}\n", .{ @field(opcode, field.name), self.memory[@field(opcode, field.name)] });
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
        // std.io.getStdOut().writer().print("{} = {}\n", .{ op.dst_slot, op.tag }) catch unreachable;
        // std.debug.print("({}) set slot {} = {}\n", .{ op.tag, op.dst_slot, op.value });
    }

    fn processCast(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        if (self.memory_tags[op.op1_slot] == .FF) {
            fieldOps.bn254_fr_normalize(@ptrCast(&self.memory[op.op1_slot]));
            // std.debug.print("dest: {}\n", .{self.memory[op.op1_slot]});
        }
        const mask = getBitMask(op.tag);
        self.memory[op.op2_slot] = self.memory[op.op1_slot] & mask;
        self.memory_tags[op.op2_slot] = op.tag;
        // std.io.getStdOut().writer().print("{} = {}\n", .{ op.op2_slot, op.tag }) catch unreachable;
    }

    fn processCalldatacopy(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        const size: usize = @truncate(self.memory[op.size_slot]);
        const start_slot: usize = @truncate(self.memory[op.start_slot]);
        // std.debug.print("cdc {} {}\n", .{ size, start_slot });
        if (self.calldata.len < size) {
            self.trap();
            return;
        }
        for (0..size) |i| {
            const addr = op.dst_slot + i;
            const src_index = start_slot + i;
            // std.debug.print("copy {} to slot {}\n", .{ self.calldata[src_index], addr });
            self.memory[addr] = self.calldata[src_index];
            self.memory_tags[addr] = io.Tag.FF;
            // std.io.getStdOut().writer().print("{} = {}\n", .{ addr, io.Tag.FF }) catch unreachable;
        }
    }

    fn processMov(self: *AztecVm, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        // std.io.getStdOut().writer().print("{any} tag: {} value: {}\n", .{
        //     op,
        //     self.memory_tags[op.src_slot],
        //     self.memory[op.src_slot],
        // }) catch unreachable;
        std.debug.assert(self.memory_tags[op.src_slot] != io.Tag.UNSET);
        self.memory[op.dst_slot] = self.memory[op.src_slot];
        self.memory_tags[op.dst_slot] = self.memory_tags[op.src_slot];
        // std.debug.print("({}) mov slot {} = {} (value: {})\n", .{
        //     self.memory_tags[op.src_slot],
        //     op.src_slot,
        //     op.dst_slot,
        //     self.memory[op.src_slot],
        // });
    }

    fn unaryOp(self: *AztecVm, opcode_union: *AvmOpcode, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        std.debug.assert(self.memory_tags[op.op1_slot] != io.Tag.UNSET);
        // const stdout = std.io.getStdOut().writer();
        // stdout.print("({}) op {} = {}\n", .{ self.memory_tags[op.op1_slot], op.op1_slot, op.op2_slot }) catch unreachable;
        switch (self.memory_tags[op.op1_slot]) {
            .U1 => self.unaryIntOp(u1, opcode_union, op),
            .U8 => self.unaryIntOp(u8, opcode_union, op),
            .U16 => self.unaryIntOp(u16, opcode_union, op),
            .U32 => self.unaryIntOp(u32, opcode_union, op),
            .U64 => self.unaryIntOp(u64, opcode_union, op),
            .U128 => self.unaryIntOp(u128, opcode_union, op),
            .UNSET => unreachable,
            else => unreachable,
        }
        self.memory_tags[op.op2_slot] = self.memory_tags[op.op1_slot];
        // std.io.getStdOut().writer().print("{} from {} = {}\n", .{ op.op2_slot, op.op1_slot, self.memory_tags[op.op2_slot] }) catch unreachable;
    }

    fn unaryIntOp(self: *AztecVm, comptime int_type: type, opcode_union: *AvmOpcode, opcode: anytype) void {
        const lhs: int_type = @truncate(self.memory[opcode.op1_slot]);
        const r: int_type = switch (opcode_union.*) {
            .NOT => @truncate(~lhs),
            else => unreachable,
        };
        self.memory[opcode.op2_slot] = r;
        // std.io.getStdOut().writer().print("({}) op {} = {}\n", .{ int_type, lhs, r }) catch unreachable;
    }

    fn binaryOp(self: *AztecVm, opcode_union: *AvmOpcode, opcode: anytype) void {
        const op = self.derefOpcodeSlots(@TypeOf(opcode), opcode);
        // std.io.getStdOut().writer().print("{} = {}({}) op {}({})\n", .{
        //     op.op3_slot,
        //     self.memory_tags[op.op1_slot],
        //     op.op1_slot,
        //     self.memory_tags[op.op2_slot],
        //     op.op2_slot,
        // }) catch unreachable;
        std.debug.assert(self.memory_tags[op.op1_slot] != io.Tag.UNSET);
        std.debug.assert(self.memory_tags[op.op2_slot] != io.Tag.UNSET);
        std.debug.assert(self.memory_tags[op.op1_slot] == self.memory_tags[op.op2_slot]);
        switch (self.memory_tags[op.op1_slot]) {
            .FF => self.binaryFieldOp(opcode_union, op),
            .U1 => self.binaryIntOp(u1, opcode_union, op),
            .U8 => self.binaryIntOp(u8, opcode_union, op),
            .U16 => self.binaryIntOp(u16, opcode_union, op),
            .U32 => self.binaryIntOp(u32, opcode_union, op),
            .U64 => self.binaryIntOp(u64, opcode_union, op),
            .U128 => self.binaryIntOp(u128, opcode_union, op),
            .UNSET => unreachable,
        }
        self.memory_tags[op.op3_slot] = switch (opcode_union.*) {
            .EQ, .LT, .LTE => io.Tag.U1,
            else => self.memory_tags[op.op1_slot],
        };
    }

    fn binaryFieldOp(self: *AztecVm, opcode_union: *AvmOpcode, opcode: anytype) void {
        const lhs = &self.memory[opcode.op1_slot];
        const rhs = &self.memory[opcode.op2_slot];
        const dest = &self.memory[opcode.op3_slot];
        switch (opcode_union.*) {
            .ADD => fieldOps.bn254_fr_add(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .MUL => fieldOps.bn254_fr_mul(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .SUB => fieldOps.bn254_fr_sub(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .FDIV => if (!fieldOps.bn254_fr_div(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest))) self.trap(),
            .EQ => fieldOps.bn254_fr_eq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .LT => fieldOps.bn254_fr_lt(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            .LTE => fieldOps.bn254_fr_leq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
            else => unreachable,
        }
        // std.debug.print("(ff) {} op {} = {}\n", .{ lhs.*, rhs.*, dest.* });
    }

    fn binaryIntOp(self: *AztecVm, comptime int_type: type, opcode_union: *AvmOpcode, opcode: anytype) void {
        const lhs: int_type = @truncate(self.memory[opcode.op1_slot]);
        const rhs: int_type = @truncate(self.memory[opcode.op2_slot]);
        const bit_size = @bitSizeOf(int_type);
        const r: int_type = switch (opcode_union.*) {
            .ADD => lhs +% rhs,
            .SUB => lhs -% rhs,
            .DIV => if (rhs != 0) lhs / rhs else blk: {
                self.trap();
                break :blk 0;
            },
            .MUL => lhs *% rhs,
            .AND => lhs & rhs,
            .OR => lhs | rhs,
            .XOR => lhs ^ rhs,
            .SHL => if (rhs < bit_size) lhs << @truncate(rhs) else 0,
            .SHR => if (rhs < bit_size) lhs >> @truncate(rhs) else 0,
            .EQ => @intFromBool(lhs == rhs),
            .LT => @intFromBool(lhs < rhs),
            .LTE => @intFromBool(lhs <= rhs),
            else => unreachable,
        };
        self.memory[opcode.op3_slot] = r;
        // std.io.getStdOut().writer().print("({}) {} op {} = {}\n", .{ int_type, lhs, rhs, r }) catch unreachable;
    }

    pub fn dumpMem(self: *AztecVm, n: usize, offset: usize) void {
        for (offset..offset + n) |i| {
            std.debug.print("{:0>3}: 0x{x:0>64}\n", .{ i, self.memory[i] });
        }
    }

    fn trap(self: *AztecVm) void {
        self.trapped = true;
        self.halted = true;
    }
};

fn getBitMask(int_size: io.Tag) u256 {
    return switch (int_size) {
        .U1 => 0x1,
        .U8 => 0xFF,
        .U16 => 0xFFFF,
        .U32 => 0xFFFFFFFF,
        .U64 => 0xFFFFFFFFFFFFFFFF,
        .U128 => 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
        .FF => 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
        .UNSET => unreachable,
    };
}
