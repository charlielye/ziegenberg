const std = @import("std");
const deserializeOpcodes = @import("io.zig").deserializeOpcodes;
const BrilligOpcode = @import("io.zig").BrilligOpcode;
const BitSize = @import("io.zig").BitSize;
const io = @import("io.zig");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const root = @import("../root.zig");
const blackbox = @import("../blackbox/blackbox.zig");

pub fn execute(file_path: []const u8, calldata_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var serialized_data: []u8 = undefined;
    if (std.mem.eql(u8, file_path, "-")) {
        const stdin = std.io.getStdIn();
        serialized_data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    } else {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        serialized_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    }

    // Temp hack to locate start of brillig.
    // Assume first opcode is always the same.
    const find: [32]u8 = @bitCast(@byteSwap(@as(u256, 0x0900000002000000000000000100000004000000400000000000000030303030)));
    const start = std.mem.indexOf(u8, serialized_data, find[0..]) orelse return error.FirstOpcodeNotFound;
    std.debug.print("First opcode found at: {x}\n", .{start});

    // Jump back 8 bytes to include the opcode count.
    const opcodes = try deserializeOpcodes(allocator, serialized_data[start - 8 ..]);
    std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    // for (opcodes) |elem| {
    //     std.debug.print("{any}\n", .{elem});
    // }

    var calldata: []u256 = &[_]u256{};
    if (calldata_path) |path| {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        const calldata_bytes = try f.readToEndAlloc(allocator, std.math.maxInt(usize));
        // Alignment cast here will probably break things. Just a hack.
        calldata = @alignCast(std.mem.bytesAsSlice(u256, calldata_bytes));
        for (0..calldata.len) |i| {
            calldata[i] = @byteSwap(calldata[i]);
        }
    }
    std.debug.print("Calldata consists of {} elements.\n", .{calldata.len});

    var t = try std.time.Timer.start();
    var brillig_vm = try BrilligVm.init(allocator);
    defer brillig_vm.deinit(allocator);
    std.debug.print("Executing...\n", .{});
    const result = brillig_vm.execute_vm(opcodes, calldata);
    std.debug.print("time taken: {}us\n", .{t.read() / 1000});
    return result;
}

const BrilligVm = struct {
    const mem_size = 1024 * 1024 * 1024;
    memory: []align(32) u256,
    callstack: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) !BrilligVm {
        const vm = BrilligVm{
            .memory = try allocator.alignedAlloc(u256, 32, mem_size),
            .callstack = try std.ArrayList(u64).initCapacity(allocator, 1024),
        };
        // @memset(vm.memory, 0);
        return vm;
    }

    pub fn deinit(self: *BrilligVm, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
    }

    pub fn execute_vm(self: *BrilligVm, opcodes: []BrilligOpcode, calldata: []u256) !void {
        const memory = self.memory;
        var pc: u64 = 0;

        while (true) {
            const opcode = &opcodes[pc];
            // std.debug.print("{}: {any}\n", .{ pc, opcode });
            switch (opcode.*) {
                .Const => |*const_opcode| {
                    const dest_index = const_opcode.destination;
                    // TODO: Move to deserialize time. Convert to montgomery if a field so it happens just once.
                    if (const_opcode.bit_size == BitSize.Field and (const_opcode.value & (1 << 255)) == 0) {
                        const_opcode.value = @as(u256, @bitCast(Bn254Fr.from_int(const_opcode.value).limbs)) | (1 << 255);
                    }
                    memory[dest_index] = const_opcode.value;
                    pc += 1;
                },
                .IndirectConst => |*indirect_const| {
                    const dest_ptr_index = indirect_const.destination_pointer;
                    const dest_address = memory[dest_ptr_index];
                    // TODO: Move to deserialize time. Convert to montgomery if a field so it happens just once.
                    if (indirect_const.bit_size == BitSize.Field and (indirect_const.value & (1 << 255)) == 0) {
                        indirect_const.value = @as(u256, @bitCast(Bn254Fr.from_int(indirect_const.value).limbs)) | (1 << 255);
                    }
                    memory[@truncate(dest_address)] = indirect_const.value;
                    pc += 1;
                },
                .CalldataCopy => |cdc| {
                    const size: u64 = @truncate(memory[cdc.size_address]);
                    const offset: u64 = @truncate(memory[cdc.offset_address]);
                    if (calldata.len < size) {
                        return error.MissingCalldata;
                    }
                    for (0..size) |i| {
                        const addr = cdc.destination_address + i;
                        const src_index = offset + i;
                        // std.debug.print("copy {} to slot {}\n", .{ calldata[src_index], addr });
                        memory[addr] = calldata[src_index];
                    }
                    pc += 1;
                },
                .Cast => |cast| {
                    switch (cast.bit_size) {
                        .Integer => |int_size| {
                            root.bn254_fr_normalize(@ptrCast(&memory[cast.source]));
                            const mask = (@as(u256, 1) << getBitSize(int_size)) - 1;
                            memory[cast.destination] = memory[cast.source] & mask;
                        },
                        .Field => {
                            memory[cast.destination] = memory[cast.source];
                        },
                    }
                    pc += 1;
                },
                .Mov => |mov| {
                    memory[mov.destination] = memory[mov.source];
                    pc += 1;
                },
                .ConditionalMov => |mov| {
                    memory[mov.destination] = memory[if (memory[mov.condition] != 0) mov.source_a else mov.source_b];
                    pc += 1;
                },
                .Store => |store| {
                    memory[@truncate(memory[store.destination_pointer])] = memory[store.source];
                    pc += 1;
                },
                .Load => |load| {
                    memory[load.destination] = memory[@truncate(memory[load.source_pointer])];
                    pc += 1;
                },
                .Call => |call| {
                    try self.callstack.append(pc + 1);
                    pc = call.location;
                },
                .Return => {
                    pc = self.callstack.pop();
                },
                .Jump => |jmp| {
                    pc = jmp.location;
                },
                .JumpIf => |jmp| {
                    pc = if (memory[jmp.condition] == 1) jmp.location else pc + 1;
                },
                .JumpIfNot => |jmp| {
                    pc = if (memory[jmp.condition] == 0) jmp.location else pc + 1;
                },
                .Not => |not| {
                    memory[not.destination] = switch (not.bit_size) {
                        .U0 => unreachable,
                        .U1 => self.unaryNot(u1, not),
                        .U8 => self.unaryNot(u8, not),
                        .U16 => self.unaryNot(u16, not),
                        .U32 => self.unaryNot(u32, not),
                        .U64 => self.unaryNot(u64, not),
                        .U128 => self.unaryNot(u128, not),
                    };
                    pc += 1;
                },
                .BinaryIntOp => |int_op| {
                    memory[int_op.destination] = switch (int_op.bit_size) {
                        .U0 => unreachable,
                        .U1 => self.binaryIntOp(u1, opcode.BinaryIntOp),
                        .U8 => self.binaryIntOp(u8, opcode.BinaryIntOp),
                        .U16 => self.binaryIntOp(u16, opcode.BinaryIntOp),
                        .U32 => self.binaryIntOp(u32, opcode.BinaryIntOp),
                        .U64 => self.binaryIntOp(u64, opcode.BinaryIntOp),
                        .U128 => self.binaryIntOp(u128, opcode.BinaryIntOp),
                    };
                    pc += 1;
                },
                .BinaryFieldOp => |field_op| {
                    const lhs = &memory[field_op.lhs];
                    const rhs = &memory[field_op.rhs];
                    const dest = &memory[field_op.destination];
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
                    pc += 1;
                },
                .BlackBox => |blackbox_op| {
                    switch (blackbox_op) {
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
                            std.debug.print("Unimplemented: {}\n", .{opcodes[pc]});
                            unreachable;
                        },
                    }
                    pc += 1;
                },
                .ForeignCall => |fc| {
                    if (std.mem.eql(u8, "print", fc.function)) {
                        std.debug.print("print called\n", .{});
                    } else {
                        std.debug.print("Unimplemented: {s}\n", .{fc.function});
                        unreachable;
                    }
                    pc += 1;
                },
                .Stop => {
                    return;
                },
                .Trap => {
                    std.debug.print("Trap! (todo print revert_data)\n", .{});
                    return error.Trapped;
                },
            }
        }
    }

    pub fn dumpMem(self: *BrilligVm, n: usize) void {
        for (0..n) |i| {
            std.debug.print("{:0>3}: 0x{x:0>64}\n", .{ i, self.memory[i] });
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
