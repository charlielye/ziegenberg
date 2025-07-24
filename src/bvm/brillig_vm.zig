const std = @import("std");
const io = @import("io.zig");
const F = @import("../bn254/fr.zig").Fr;
const fieldOps = @import("../blackbox/field.zig");
const blackbox = @import("../blackbox/blackbox.zig");
const rdtsc = @import("../timer/rdtsc.zig").rdtsc;
const Memory = @import("memory.zig").Memory;
const DebugContext = @import("debug_context.zig").DebugContext;
const BrilligOpcode = io.BrilligOpcode;

extern fn mlock(addr: ?*u8, len: usize) callconv(.C) i32;

const ExecuteOptions = struct {
    // Sample rate for opcode performance measurement.
    sample_rate: u64 = 0,
    debug_ctx: ?*DebugContext = null,
};

pub const ErrorContext = struct {
    pc: usize,
    callstack: []const usize,
    ops_executed: u64,
    return_data: []const u256,
};

pub fn BrilligVm(ForeignCallDispatcher: type) type {
    return struct {
        const Self = @This();
        const mem_size = 1024 * 1024 * 8;
        // const mem_size = 1024 * 1024 * 32;
        const jump_table = [_]*const fn (*Self, *BrilligOpcode) anyerror!void{
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
        allocator: std.mem.Allocator,
        mem: Memory,

        calldata: []u256,
        callstack: std.ArrayList(usize),
        pc: usize = 0,
        halted: bool = false,
        trapped: bool = false,
        return_data: []align(32) u256,
        ops_executed: u64 = 0,
        blackbox_counters: [@typeInfo(io.BlackBoxOp).@"union".fields.len]u64,
        opcode_counters: [@typeInfo(io.BrilligOpcode).@"union".fields.len]u64,
        opcode_time: [@typeInfo(io.BrilligOpcode).@"union".fields.len]u64,
        time_taken: u64 = 0,
        // TODO: Hardcoded in for now. But this needs to be passed into each brillig vm instance.
        fc_handler: *ForeignCallDispatcher,

        pub fn init(allocator: std.mem.Allocator, calldata: []u256, fc_handler: *ForeignCallDispatcher) !@This() {
            const vm = @This(){
                .allocator = allocator,
                .mem = try Memory.init(allocator, mem_size),
                .calldata = calldata,
                .callstack = try std.ArrayList(usize).initCapacity(allocator, 1024),
                .blackbox_counters = std.mem.zeroes([@typeInfo(io.BlackBoxOp).@"union".fields.len]u64),
                .opcode_counters = std.mem.zeroes([@typeInfo(io.BrilligOpcode).@"union".fields.len]u64),
                .opcode_time = std.mem.zeroes([@typeInfo(io.BrilligOpcode).@"union".fields.len]u64),
                .return_data = &.{},
                .fc_handler = fc_handler,
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

        pub fn deinit(self: *Self) void {
            self.mem.deinit();
        }

        pub fn getErrorContext(self: *const Self, allocator: std.mem.Allocator) !ErrorContext {
            return ErrorContext{
                .pc = self.pc,
                .callstack = try allocator.dupe(usize, self.callstack.items),
                .ops_executed = self.ops_executed,
                .return_data = try allocator.dupe(u256, self.return_data),
            };
        }

        pub fn executeVm(self: *Self, opcodes: []BrilligOpcode, options: ExecuteOptions) !void {
            var t = try std.time.Timer.start();

            while (!self.halted) {
                const current_pc = self.pc;
                const opcode = &opcodes[current_pc];

                const i = @intFromEnum(opcode.*);
                if (i > Self.jump_table.len - 1) {
                    return error.UnknownOpcode;
                }

                // Take a timing sample every 1000th.
                const idx = @intFromEnum(opcode.*);
                var before: u64 = 0;
                if (options.sample_rate > 0 and self.ops_executed % options.sample_rate == 0) {
                    before = rdtsc();
                }

                // Execute opcode.
                Self.jump_table[i](self, opcode) catch |err| {
                    // Notify debug context about the error before propagating
                    if (options.debug_ctx) |ctx| {
                        ctx.onError(current_pc, self);
                    }
                    return err;
                };

                if (options.sample_rate > 0 and self.ops_executed % options.sample_rate == 0) {
                    self.opcode_time[idx] += rdtsc() - before;
                }
                self.opcode_counters[idx] += 1;
                self.ops_executed += 1;

                // Call debug hook if provided
                if (options.debug_ctx) |ctx| {
                    if (!ctx.afterOpcode(self.pc, opcode.*, self.ops_executed, self)) {
                        // Debug context requested termination
                        return error.DebuggerTerminated;
                    }
                }
            }

            self.time_taken = t.read();

            if (self.trapped) {
                return error.Trapped;
            }
        }

        fn processConst(self: *Self, opcode: *BrilligOpcode) !void {
            const op = &opcode.Const;
            // TODO: Move to deserialize time. Convert to montgomery if a field so it happens just once.
            if (op.bit_size == io.BitSize.Field and (op.value & (1 << 255)) == 0) {
                op.value = @as(u256, @bitCast(F.from_int(op.value).limbs)) | (1 << 255);
            }
            self.mem.setSlot(op.destination, op.value);
            self.pc += 1;
            // std.debug.print("({}) set slot {} = {}\n", .{
            //     op.bit_size,
            //     op.destination.resolve(self.memory),
            //     op.value,
            // });
        }

        fn processIndirectConst(self: *Self, opcode: *BrilligOpcode) !void {
            const op = &opcode.IndirectConst;
            const dest_ptr_index = self.mem.resolveSlot(op.destination_pointer);
            const dest_address = self.mem.getSlotAtIndex(dest_ptr_index);
            // TODO: Move to deserialize time. Convert to montgomery if a field so it happens just once.
            if (op.bit_size == io.BitSize.Field and (op.value & (1 << 255)) == 0) {
                op.value = @as(u256, @bitCast(F.from_int(op.value).limbs)) | (1 << 255);
            }
            self.mem.setSlotAtIndex(@truncate(dest_address), op.value);
            self.pc += 1;
            // std.debug.print("({}) set slot {} = {}\n", .{
            //     op.bit_size,
            //     dest_address,
            //     op.value,
            // });
        }

        fn processCalldatacopy(self: *Self, opcode: *BrilligOpcode) !void {
            const op = &opcode.CalldataCopy;
            const size: usize = @truncate(self.mem.getSlot(op.size_address));
            const offset: usize = @truncate(self.mem.getSlot(op.offset_address));
            if (self.calldata.len < size) {
                self.trap();
                return;
            }
            for (0..size) |i| {
                const addr = self.mem.resolveSlot(op.destination_address) + i;
                const src_index = offset + i;
                // std.debug.print("copy {} to slot {}\n", .{ calldata[src_index], addr });
                self.mem.setSlotAtIndex(addr, self.calldata[src_index]);
            }
            self.pc += 1;
        }

        fn processCast(self: *Self, opcode: *BrilligOpcode) !void {
            const op = &opcode.Cast;
            switch (op.bit_size) {
                .Integer => |int_size| {
                    fieldOps.bn254_fr_normalize(@ptrCast(self.mem.getSlotAddr(op.source)));
                    const mask = (@as(u256, 1) << getBitSize(int_size)) - 1;
                    self.mem.setSlot(op.destination, self.mem.getSlot(op.source) & mask);
                },
                .Field => {
                    self.mem.setSlot(op.destination, self.mem.getSlot(op.source));
                },
            }
            self.pc += 1;
        }

        fn processMov(self: *Self, opcode: *BrilligOpcode) !void {
            const mov = &opcode.Mov;
            self.mem.setSlot(mov.destination, self.mem.getSlot(mov.source));
            self.pc += 1;
            // std.io.getStdOut().writer().print("mov slot {} = {} (value: {})\n", .{
            //     mov.source.resolve(self.memory),
            //     mov.destination.resolve(self.memory),
            //     self.getSlot(mov.source),
            // }) catch unreachable;
        }

        fn processCmov(self: *Self, opcode: *BrilligOpcode) !void {
            const mov = &opcode.ConditionalMov;
            self.mem.setSlot(
                mov.destination,
                if (self.mem.getSlot(mov.condition) != 0) self.mem.getSlot(mov.source_a) else self.mem.getSlot(mov.source_b),
            );
            self.pc += 1;
        }

        fn processStore(self: *Self, opcode: *BrilligOpcode) !void {
            const store = &opcode.Store;
            self.mem.setSlotAtIndex(@truncate(self.mem.getSlot(store.destination_pointer)), self.mem.getSlot(store.source));
            self.pc += 1;
        }

        fn processLoad(self: *Self, opcode: *BrilligOpcode) !void {
            const load = &opcode.Load;
            self.mem.setSlot(load.destination, self.mem.getIndirectSlot(load.source_pointer));
            self.pc += 1;
            // std.io.getStdOut().writer().print("load slot {} = {} (value: {})\n", .{
            //     load.destination.resolve(self.memory),
            //     self.memory[load.source_pointer.resolve(self.memory)],
            //     self.memory[@truncate(self.memory[load.source_pointer.resolve(self.memory)])],
            // }) catch unreachable;
        }

        fn processCall(self: *Self, opcode: *BrilligOpcode) !void {
            const call = &opcode.Call;
            self.callstack.append(self.pc + 1) catch unreachable;
            self.pc = @truncate(call.location);
        }

        fn processReturn(self: *Self, _: *BrilligOpcode) !void {
            self.pc = self.callstack.pop() orelse unreachable;
        }

        fn processJump(self: *Self, opcode: *BrilligOpcode) !void {
            const jmp = &opcode.Jump;
            self.pc = @truncate(jmp.location);
        }

        fn processJumpIf(self: *Self, opcode: *BrilligOpcode) !void {
            const jmp = &opcode.JumpIf;
            self.pc = if (self.mem.getSlot(jmp.condition) == 1) @truncate(jmp.location) else self.pc + 1;
        }

        fn processJumpIfNot(self: *Self, opcode: *BrilligOpcode) !void {
            const jmp = &opcode.JumpIfNot;
            self.pc = if (self.mem.getSlot(jmp.condition) == 0) @truncate(jmp.location) else self.pc + 1;
        }

        fn processNot(self: *Self, opcode: *BrilligOpcode) !void {
            const not = &opcode.Not;
            // std.io.getStdOut().writer().print("{} = ", .{self.getSlot(not.source)}) catch unreachable;
            self.mem.setSlot(not.destination, switch (not.bit_size) {
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

        fn processBinaryIntOp(self: *Self, opcode: *BrilligOpcode) !void {
            const int_op = &opcode.BinaryIntOp;
            self.mem.setSlot(int_op.destination, switch (int_op.bit_size) {
                .U1 => self.binaryIntOp(u1, opcode.BinaryIntOp),
                .U8 => self.binaryIntOp(u8, opcode.BinaryIntOp),
                .U16 => self.binaryIntOp(u16, opcode.BinaryIntOp),
                .U32 => self.binaryIntOp(u32, opcode.BinaryIntOp),
                .U64 => self.binaryIntOp(u64, opcode.BinaryIntOp),
                .U128 => self.binaryIntOp(u128, opcode.BinaryIntOp),
            });
            self.pc += 1;
        }

        fn processBinaryFieldOp(self: *Self, opcode: *BrilligOpcode) !void {
            const field_op = &opcode.BinaryFieldOp;
            const lhs = self.mem.getSlotAddr(field_op.lhs);
            const rhs = self.mem.getSlotAddr(field_op.rhs);
            const dest = self.mem.getSlotAddr(field_op.destination);
            switch (field_op.op) {
                .Add => fieldOps.bn254_fr_add(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
                .Mul => fieldOps.bn254_fr_mul(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
                .Sub => fieldOps.bn254_fr_sub(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
                .Div => if (!fieldOps.bn254_fr_div(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest))) self.trap(),
                .Equals => fieldOps.bn254_fr_eq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
                .LessThan => fieldOps.bn254_fr_lt(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
                .LessThanEquals => fieldOps.bn254_fr_leq(@ptrCast(lhs), @ptrCast(rhs), @ptrCast(dest)),
                .IntegerDiv => {
                    fieldOps.bn254_fr_normalize(@ptrCast(lhs));
                    fieldOps.bn254_fr_normalize(@ptrCast(rhs));
                    dest.* = lhs.* / rhs.*;
                },
            }
            self.pc += 1;
        }

        fn processBlackbox(self: *Self, opcode: *BrilligOpcode) !void {
            const blackbox_op = &opcode.BlackBox;

            const idx = @intFromEnum(blackbox_op.*);
            self.blackbox_counters[idx] += 1;

            switch (blackbox_op.*) {
                .Sha256Compression => |op| {
                    blackbox.blackbox_sha256_compression(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.input.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.hash_values.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.output.pointer)),
                    );
                },
                .Blake2s => |op| {
                    blackbox.blackbox_blake2s(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.message.pointer)),
                        @truncate(self.mem.getSlot(op.message.size)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.output.pointer)),
                    );
                },
                .Blake3 => |op| {
                    blackbox.blackbox_blake3(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.message.pointer)),
                        @truncate(self.mem.getSlot(op.message.size)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.output.pointer)),
                    );
                },
                .Keccakf1600 => |op| {
                    blackbox.blackbox_keccak1600(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.message.pointer)),
                        @truncate(self.mem.getSlotAtIndex(op.message.size)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.output.pointer)),
                    );
                },
                .Poseidon2Permutation => |op| {
                    blackbox.blackbox_poseidon2_permutation(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.message.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.output.pointer)),
                        @truncate(self.mem.getSlot(op.message.size)),
                    );
                },
                .ToRadix => |op| {
                    blackbox.blackbox_to_radix(
                        @ptrCast(self.mem.getSlotAddr(op.input)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.output_pointer)),
                        @truncate(self.mem.getSlot(op.num_limbs)),
                        @truncate(self.mem.getSlot(op.radix)),
                    );
                },
                .AES128Encrypt => |op| {
                    blackbox.blackbox_aes_encrypt(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.inputs.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.iv.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.key.pointer)),
                        @truncate(self.mem.getSlot(op.inputs.size)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.outputs.pointer)),
                        @ptrCast(self.mem.getSlotAddr(op.outputs.size)),
                    );
                },
                .EcdsaSecp256k1 => |op| {
                    blackbox.blackbox_secp256k1_verify_signature(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.hashed_msg.pointer)),
                        @truncate(self.mem.getSlot(op.hashed_msg.size)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.public_key_x.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.public_key_y.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.signature.pointer)),
                        @ptrCast(self.mem.getSlotAddr(op.result)),
                    );
                },
                .EcdsaSecp256r1 => |op| {
                    blackbox.blackbox_secp256r1_verify_signature(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.hashed_msg.pointer)),
                        @truncate(self.mem.getSlot(op.hashed_msg.size)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.public_key_x.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.public_key_y.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.signature.pointer)),
                        @ptrCast(self.mem.getSlotAddr(op.result)),
                    );
                },
                // .SchnorrVerify => |op| {
                //     blackbox.blackbox_schnorr_verify_signature(
                //         @ptrCast(self.mem.getIndirectSlotAddr(op.message.pointer)),
                //         @truncate(self.mem.getSlot(op.message.size)),
                //         @ptrCast(self.mem.getSlotAddr(op.public_key_x)),
                //         @ptrCast(self.mem.getSlotAddr(op.public_key_y)),
                //         @ptrCast(self.mem.getIndirectSlotAddr(op.signature.pointer)),
                //         @ptrCast(self.mem.getSlotAddr(op.result)),
                //     );
                // },
                .MultiScalarMul => |op| {
                    blackbox.blackbox_msm(
                        @ptrCast(self.mem.getIndirectSlotAddr(op.points.pointer)),
                        @truncate(self.mem.getSlot(op.points.size)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.scalars.pointer)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.outputs.pointer)),
                    );
                },
                .EmbeddedCurveAdd => |op| {
                    blackbox.blackbox_ecc_add(
                        @ptrCast(self.mem.getSlotAddr(op.input1_x)),
                        @ptrCast(self.mem.getSlotAddr(op.input1_y)),
                        @ptrCast(self.mem.getSlotAddr(op.input1_infinite)),
                        @ptrCast(self.mem.getSlotAddr(op.input2_x)),
                        @ptrCast(self.mem.getSlotAddr(op.input2_y)),
                        @ptrCast(self.mem.getSlotAddr(op.input2_infinite)),
                        @ptrCast(self.mem.getIndirectSlotAddr(op.result.pointer)),
                    );
                },
                else => {
                    std.debug.print("Unimplemented: {}\n", .{blackbox_op});
                    unreachable;
                },
            }
            self.pc += 1;
        }

        fn processForeignCall(self: *Self, opcode: *BrilligOpcode) !void {
            const fc = &opcode.ForeignCall;
            self.fc_handler.handleForeignCall(&self.mem, fc) catch |err| {
                std.debug.print("Foreign call '{s}' failed with error: {}\n", .{ fc.function, err });
                return err;
            };
            self.pc += 1;
        }

        fn processStop(self: *Self, opcode: *BrilligOpcode) !void {
            const op = &opcode.Stop;
            self.halted = true;
            const slot: usize = @intCast(self.mem.getSlot(op.return_data.pointer));
            const size: usize = @intCast(self.mem.getSlot(op.return_data.size));
            self.return_data = self.mem.memory[slot .. slot + size];
            for (self.return_data) |*v| fieldOps.bn254_fr_normalize(@ptrCast(v));
        }

        fn processTrap(self: *Self, opcode: *BrilligOpcode) !void {
            const op = &opcode.Trap;
            self.trap();
            const slot = self.mem.resolveSlot(op.revert_data.pointer);
            const size = self.mem.resolveSlot(op.revert_data.size);
            self.return_data = self.mem.memory[slot .. slot + size];
            for (self.return_data) |*v| fieldOps.bn254_fr_normalize(@ptrCast(v));
            std.debug.print("Trap! PC: {}, Ops executed: {}\n", .{ self.pc, self.ops_executed });
            std.debug.print("Callstack depth: {}\n", .{self.callstack.items.len});
            if (self.callstack.items.len > 0) {
                std.debug.print("Callstack: ", .{});
                for (self.callstack.items) |addr| {
                    std.debug.print("{} ", .{addr});
                }
                std.debug.print("\n", .{});
            }
        }

        pub fn dumpStats(self: *Self) void {
            std.debug.print("Time taken: {}us\n", .{self.time_taken / 1000});
            std.debug.print("Opcodes executed: {}\n", .{self.ops_executed});
            std.debug.print("Max slot set: {}\n", .{self.mem.max_slot_set});

            var total_cycles: u64 = 0;
            for (self.opcode_time) |x| total_cycles += x;

            std.debug.print("Opcode hit / time:\n", .{});
            inline for (@typeInfo(io.BrilligOpcode).@"union".fields, 0..) |enumField, idx| {
                std.debug.print("  {s}: {} / {d:.2}%\n", .{
                    enumField.name,
                    self.opcode_counters[idx],
                    @as(f64, @floatFromInt(self.opcode_time[idx] * 100)) / @as(f64, @floatFromInt(total_cycles)),
                });
            }

            std.debug.print("Blackbox calls:\n", .{});
            inline for (@typeInfo(io.BlackBoxOp).@"union".fields, 0..) |enumField, idx| {
                std.debug.print("  {s}: {}\n", .{ enumField.name, self.blackbox_counters[idx] });
            }
        }

        fn binaryIntOp(self: *Self, comptime int_type: type, op: anytype) int_type {
            const lhs: int_type = @truncate(self.mem.getSlot(op.lhs));
            const rhs: int_type = @truncate(self.mem.getSlot(op.rhs));
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

        inline fn unaryNot(self: *Self, comptime int_type: type, op: anytype) int_type {
            return @truncate(~self.mem.getSlot(op.source));
        }

        inline fn trap(self: *Self) void {
            self.trapped = true;
            self.halted = true;
        }
    };
}

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
