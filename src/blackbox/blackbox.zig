const std = @import("std");
const decode_fr = @import("encode_fr.zig").decode_fr;
const encode_fr = @import("encode_fr.zig").encode_fr;
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const GrumpkinFq = @import("../grumpkin/fq.zig").Fq;
const get_msb = @import("../bitop/get_msb.zig").get_msb;
const encrypt_cbc = @import("../aes/encrypt_cbc.zig").encrypt_cbc;
const verify_signature = @import("ecdsa.zig").verify_signature;
const Poseidon2 = @import("../poseidon2/permutation.zig").Poseidon2;
const G1 = @import("../grumpkin/g1.zig").G1;
const pedersen = @import("../pedersen/pedersen.zig");

export fn blackbox_sha256(input: [*]const u256, length: usize, result: [*]u256) void {
    var message = std.ArrayList(u8).initCapacity(std.heap.page_allocator, length) catch unreachable;
    defer message.deinit();
    for (0..length) |i| {
        _ = message.append(@truncate(input[i])) catch unreachable;
    }
    var output: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message.items, &output, .{});
    for (0..32) |i| {
        result[i] = output[i];
    }
}

export fn blackbox_blake2s(input: [*]const u256, length: usize, result: [*]u256) void {
    var message = std.ArrayList(u8).initCapacity(std.heap.page_allocator, length) catch unreachable;
    defer message.deinit();
    for (0..length) |i| {
        _ = message.append(@truncate(input[i])) catch unreachable;
    }
    var output: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2s256.hash(message.items, &output, .{});
    for (0..32) |i| {
        result[i] = output[i];
    }
}

export fn blackbox_blake3(input: [*]const u256, length: usize, result: [*]u256) void {
    // TODO: Use some global memory to move allocs off VM path.
    var message = std.ArrayList(u8).initCapacity(std.heap.page_allocator, length) catch unreachable;
    defer message.deinit();
    for (0..length) |i| {
        _ = message.append(@truncate(input[i])) catch unreachable;
    }
    var output: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(message.items, &output, .{});
    for (0..32) |i| {
        result[i] = output[i];
    }
}

export fn blackbox_pedersen_hash(input: [*]Bn254Fr, size: usize, hash_index: u32, output: *Bn254Fr) void {
    // TODO: Use some global memory to move allocs off VM path.
    var frs = std.ArrayList(GrumpkinFq).initCapacity(std.heap.page_allocator, size) catch unreachable;
    defer frs.deinit();
    for (0..size) |i| {
        frs.append(decode_fr(&input[i])) catch unreachable;
    }

    // const acc = pedersen_commit(G1, frs.items, hash_index);
    // output.* = generators.length_generator.mul(G1.Fr.from_int(size)).add(acc).normalize().x;
    output.* = pedersen.hash(G1, frs.items, hash_index);
    encode_fr(&output.*);
}

export fn blackbox_pedersen_commit(input: [*]GrumpkinFq, size: usize, hash_index: u32, output: *struct { Bn254Fr, Bn254Fr }) void {
    // TODO: Use some global memory to move allocs off VM path.
    var frs = std.ArrayList(GrumpkinFq).initCapacity(std.heap.page_allocator, size) catch unreachable;
    defer frs.deinit();
    for (0..size) |i| {
        frs.append(decode_fr(&input[i])) catch unreachable;
    }

    const acc = pedersen.commit(G1, frs.items, hash_index);

    output.*.@"0" = acc.x;
    output.*.@"1" = acc.y;
    encode_fr(&output.*.@"0");
    encode_fr(&output.*.@"1");
}

export fn blackbox_poseidon2_permutation(input: [*]Bn254Fr, result: [*]Bn254Fr, _: usize) void {
    var frs: [4]Bn254Fr = undefined;
    for (0..4) |i| {
        frs[i] = decode_fr(&input[i]);
        // frs[i].print();
    }

    const r = Poseidon2.permutation(frs);

    for (0..4) |i| {
        result[i] = r[i];
        // result[i].print();
        encode_fr(&result[i]);
    }
    // std.debug.print("-\n", .{});
}

export fn blackbox_keccak1600(input: [*]const u256, _: usize, result: [*]u256) void {
    var state: [25]u64 = undefined;
    for (0..25) |i| {
        state[i] = @truncate(input[i]);
    }
    var hasher = std.crypto.core.keccak.KeccakF(1600){ .st = state };
    hasher.permute();
    for (0..25) |i| {
        result[i] = hasher.st[i];
    }
}

export fn blackbox_aes_encrypt(in: [*]const u256, iv: [*]const u256, key: [*]const u256, length: u64, result: [*]u256, r_size: *u256) void {
    const padded_length = (length + 15) & ~@as(u64, 15);
    const padding_length = padded_length - length;
    var input = std.ArrayList(u8).initCapacity(std.heap.page_allocator, padded_length) catch unreachable;
    for (0..length) |i| {
        input.append(@truncate(in[i])) catch unreachable;
    }
    input.appendNTimes(@truncate(padding_length), padding_length) catch unreachable;
    var iv_arr: [16]u8 = undefined;
    var key_arr: [16]u8 = undefined;
    for (0..16) |i| {
        iv_arr[i] = @truncate(iv[i]);
        key_arr[i] = @truncate(key[i]);
    }

    encrypt_cbc(input.items, &key_arr, &iv_arr);

    for (0..padded_length) |i| {
        result[i] = input.items[i];
    }
    r_size.* = padded_length;
}

export fn blackbox_secp256k1_verify_signature(hashed_message: [*]const u256, _: u64, pub_key_x: [*]const u256, pub_key_y: [*]const u256, sig: [*]const u256, result: *u256) void {
    verify_signature(std.crypto.ecc.Secp256k1, hashed_message, pub_key_x, pub_key_y, sig, result);
}

export fn blackbox_secp256r1_verify_signature(hashed_message: [*]const u256, _: u64, pub_key_x: [*]const u256, pub_key_y: [*]const u256, sig: [*]const u256, result: *u256) void {
    verify_signature(std.crypto.ecc.P256, hashed_message, pub_key_x, pub_key_y, sig, result);
}

export fn to_radix(input: *Bn254Fr, output: [*]u256, size: u64, radix: u64) void {
    var in = decode_fr(input).to_int();

    for (0..size) |i| {
        const quotient = in / radix;
        // const remainder = in % radix;
        // Might be faster? Optimiser might do the right thing.
        const remainder = in - (quotient * radix);
        // bb has a divmod function (ported below). Seems way less performant?
        // const quotient: u256, const remainder: u256 = divmod(in, radix_);
        output[i] = remainder;
        in = quotient;
    }
}

// const rdtsc = @import("../timer/rdtsc.zig").rdtsc;

// inline fn divmod(a: u256, b: u256) struct { u256, u256 } {
//     if ((a == 0) or (b == 0)) return .{ 0, 0 };
//     if (b == 1) return .{ a, 0 };
//     if (a == b) return .{ 1, 0 };
//     if (b > a) return .{ 0, a };

//     var quotient: u256 = 0;
//     var remainder = a;
//     const bit_difference = get_msb(@bitCast(a)) - get_msb(@bitCast(b));

//     var divisor = b << bit_difference;
//     var accumulator = @as(u256, 1) << bit_difference;

//     if (divisor > remainder) {
//         divisor >>= 1;
//         accumulator >>= 1;
//     }

//     while (remainder >= b) {
//         if (remainder >= divisor) {
//             remainder -= divisor;
//             quotient |= accumulator;
//         }
//         divisor >>= 1;
//         accumulator >>= 1;
//     }

//     return .{ quotient, remainder };
// }

// inline fn divmod_native(a: u256, b: u256) struct { u256, u256 } {
//     const quotient = a / b;
//     // const remainder = a - (quotient * b);
//     const remainder = a % b;

//     return .{ quotient, remainder };
// }

// test "bench divmod" {
//     const input = std.crypto.random.int(u256);
//     const radix: u256 = 2;

//     const num: usize = 1 << 20;
//     var t = try std.time.Timer.start();
//     const cycles = rdtsc();
//     var q: u256 = 0;
//     var r: u256 = 0;

//     for (0..num) |i| {
//         // divmod(input, radix);
//         // const quotient: u256, const remainder: u256 = divmod(input, radix);
//         // _ = divmod(input, radix);
//         const q1, const r1 = divmod(input + i, radix);
//         q += q1;
//         r += r1;
//     }

//     std.debug.print("{} {}\n", .{ q, r });
//     std.debug.print("time taken: {}ns\n", .{t.read()});
//     std.debug.print("cycles per divmod: {}\n", .{(rdtsc() - cycles) / num});
// }
