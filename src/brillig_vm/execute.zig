const std = @import("std");
const deserializeOpcodes = @import("io.zig").deserializeOpcodes;
const BrilligOpcode = @import("io.zig").BrilligOpcode;
const io = @import("io.zig");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const root = @import("../root.zig");
const blackbox = @import("../blackbox/blackbox.zig");

pub fn execute(file_path: []u8, calldata_path: []u8) !void {
    var allocator = std.heap.page_allocator;

    var serialized_data: []u8 = undefined;
    if (std.mem.eql(u8, file_path, "-")) {
        const stdin = std.io.getStdIn();
        serialized_data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    } else {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        serialized_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    }
    defer allocator.free(serialized_data);

    // Temp hack to locate start of brillig.
    // Assume first opcode is always the same.
    const find = @byteSwap(@as(u256, 0x0800000002000000000000000100000004000000400000000000000030303030));
    var start: usize = 0;
    for (0..serialized_data.len) |i| {
        if (@as(*align(1) u256, @ptrCast(&serialized_data[i])).* == find) {
            // Jump back 8 bytes to include the opcode count.
            start = i - 8;
            break;
        }
    }

    if (start == 0) {
        // std.debug.print("Failed to find first opcode.\n", .{});
        return error.FirstOpcodeNotFound;
    }

    const opcodes = deserializeOpcodes(serialized_data[start..]) catch |err| {
        // std.debug.print("Deserialization failed.\n", .{});
        return err;
    };

    // for (opcodes) |elem| {
    //     std.debug.print("{any}\n", .{elem});
    // }

    // Load calldata.
    const file = try std.fs.cwd().openFile(calldata_path, .{});
    defer file.close();
    const calldata_bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(calldata_bytes);
    // Alignment cast here will probably break things. Just a hack.
    const calldata: []u256 = @alignCast(std.mem.bytesAsSlice(u256, calldata_bytes)); //@ptrCast(calldata_bytes);
    for (0..calldata.len) |i| {
        calldata[i] = @byteSwap(calldata[i]);
    }

    var brillig_vm = try BrilligVm.init(allocator);
    try brillig_vm.execute_vm(opcodes, calldata);
    brillig_vm.dumpMem(10);
    defer brillig_vm.deinit(allocator);
}

const BrilligVm = struct {
    const mem_size = 1024 * 1024 * 8;
    memory: []align(32) u256,
    callstack: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) !BrilligVm {
        const vm = BrilligVm{
            .memory = try allocator.alignedAlloc(u256, 32, mem_size),
            .callstack = try std.ArrayList(u64).initCapacity(allocator, 1024),
        };
        @memset(vm.memory, 0);
        return vm;
    }

    pub fn deinit(self: *BrilligVm, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
    }

    pub fn execute_vm(self: *BrilligVm, opcodes: []BrilligOpcode, calldata: []u256) !void {
        const memory = self.memory;
        var pc: u64 = 0;

        while (true) {
            const opcode = opcodes[pc];
            // std.debug.print("{}: {any}\n", .{ pc, opcode });
            switch (opcode) {
                .Const => |const_opcode| {
                    const dest_index = const_opcode.destination;
                    memory[dest_index] = try std.fmt.parseInt(u256, const_opcode.value, 16);
                    pc += 1;
                },
                .IndirectConst => |indirect_const| {
                    const dest_ptr_index = indirect_const.destination_pointer;
                    const dest_address = memory[dest_ptr_index];
                    memory[@truncate(dest_address)] = try std.fmt.parseInt(u256, indirect_const.value, 16);
                    pc += 1;
                },
                .CalldataCopy => |cdc| {
                    const size: u64 = @truncate(memory[cdc.size_address]);
                    const offset: u64 = @truncate(memory[cdc.offset_address]);
                    for (0..size) |i| {
                        const addr = cdc.destination_address + i;
                        const src_index = offset + i;
                        // std.debug.print("copy {} to slot {}\n", .{ calldata[src_index], addr });
                        memory[addr] = calldata[src_index];
                    }
                    pc += 1;
                },
                .Cast => |cast| {
                    // std.debug.print("source {}\n", .{memory[cast.source]});
                    switch (cast.bit_size) {
                        .Integer => |int_size| {
                            root.bn254_fr_normalize(@ptrCast(&memory[cast.source]));
                            // std.debug.print("source normalized {} size {}\n", .{ memory[cast.source], @intFromEnum(int_size) });
                            const mask = (@as(u256, 1) << getBitSize(int_size)) - 1;
                            memory[cast.destination] = memory[cast.source] & mask;
                        },
                        .Field => {
                            memory[cast.destination] = memory[cast.source];
                        },
                    }
                    // std.debug.print("cast dest {}\n", .{memory[cast.destination]});
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
                    // std.debug.print("bio op {} dest {}\n", .{ int_op.op, memory[int_op.destination] });
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
                        .Sha256 => |op| {
                            blackbox.blackbox_sha256(
                                @ptrCast(&memory[@truncate(memory[op.message.pointer])]),
                                @truncate(memory[op.message.size]),
                                @ptrCast(&memory[@truncate(memory[op.output.pointer])]),
                            );
                        },
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
                                op.radix,
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
                                op.hashed_msg.size,
                                @ptrCast(&memory[@truncate(memory[op.public_key_x.pointer])]),
                                @ptrCast(&memory[@truncate(memory[op.public_key_y.pointer])]),
                                @ptrCast(&memory[@truncate(memory[op.signature.pointer])]),
                                @ptrCast(&memory[op.result]),
                            );
                        },
                        .EcdsaSecp256r1 => |op| {
                            blackbox.blackbox_secp256r1_verify_signature(
                                @ptrCast(&memory[@truncate(memory[op.hashed_msg.pointer])]),
                                op.hashed_msg.size,
                                @ptrCast(&memory[@truncate(memory[op.public_key_x.pointer])]),
                                @ptrCast(&memory[@truncate(memory[op.public_key_y.pointer])]),
                                @ptrCast(&memory[@truncate(memory[op.signature.pointer])]),
                                @ptrCast(&memory[op.result]),
                            );
                        },
                        else => {
                            std.debug.print("Unimplemented: {}\n", .{opcodes[pc]});
                            unreachable;
                        },
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
                else => {
                    std.debug.print("Unimplemented: {}\n", .{opcodes[pc]});
                    unreachable;
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
            .Add => lhs + rhs,
            .Sub => lhs -% rhs,
            .Div => lhs / rhs,
            .Mul => lhs * rhs,
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
};

fn getBitSize(int_size: io.IntegerBitSize) u8 {
    return switch (int_size) {
        .U0 => 0,
        .U1 => 1,
        .U8 => 8,
        .U16 => 16,
        .U32 => 32,
        .U64 => 64,
        .U128 => 128,
    };
}
