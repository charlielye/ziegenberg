const std = @import("std");
const decode_fr = @import("encode_fr.zig").decode_fr;
const encode_fr = @import("encode_fr.zig").encode_fr;
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const GrumpkinFr = @import("../grumpkin/fr.zig").Fr;
const GrumpkinFq = @import("../grumpkin/fq.zig").Fq;
const get_msb = @import("../bitop/get_msb.zig").get_msb;
const aes = @import("../aes/encrypt_cbc.zig");
const verify_signature = @import("ecdsa.zig").verify_signature;
const Poseidon2 = @import("../poseidon2/permutation.zig").Poseidon2;
const G1 = @import("../grumpkin/g1.zig").G1;
const pedersen = @import("../pedersen/pedersen.zig");
const sha256_compress = @import("sha256_compress.zig").round;
const msm = @import("../msm/naive.zig").msm;
const schnorr_verify_signature = @import("../schnorr/schnorr.zig").schnorr_verify_signature;

pub export fn blackbox_sha256_compression(input: [*]const u256, hash_values: [*]const u256, result: [*]u256) void {
    var in: [16]u32 = undefined;
    for (0..16) |i| {
        in[i] = @truncate(input[i]);
    }
    var hv: [8]u32 = undefined;
    for (0..8) |i| {
        hv[i] = @truncate(hash_values[i]);
    }
    sha256_compress(&in, &hv);
    for (0..8) |i| {
        result[i] = hv[i];
    }
}

pub export fn blackbox_blake2s(input: [*]const u256, length: usize, result: [*]u256) void {
    // TODO: Use some global memory to move allocs off VM path.
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

pub export fn blackbox_blake3(input: [*]const u256, length: usize, result: [*]u256) void {
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

// pub export fn blackbox_pedersen_hash(input: [*]Bn254Fr, size: usize, hash_index: u32, output: *Bn254Fr) void {
//     // TODO: Use some global memory to move allocs off VM path.
//     var frs = std.ArrayList(GrumpkinFr).initCapacity(std.heap.page_allocator, size) catch unreachable;
//     defer frs.deinit();
//     for (0..size) |i| {
//         // GrumpkinFr field > Bn254Fr field.
//         // Thus we can convert a Bn254Fr value safely to a GrumpkinFr.
//         frs.append(GrumpkinFr.from_int(decode_fr(&input[i]).to_int())) catch unreachable;
//     }

//     output.* = pedersen.hash(G1, frs.items, hash_index);
//     encode_fr(&output.*);
// }

// pub export fn blackbox_pedersen_commit(input: [*]Bn254Fr, size: usize, hash_index: u32, output: *struct { Bn254Fr, Bn254Fr }) void {
//     // TODO: Use some global memory to move allocs off VM path.
//     var frs = std.ArrayList(GrumpkinFr).initCapacity(std.heap.page_allocator, size) catch unreachable;
//     defer frs.deinit();
//     for (0..size) |i| {
//         // GrumpkinFr field > Bn254Fr field.
//         // Thus we can convert a Bn254Fr value safely to a GrumpkinFr.
//         frs.append(GrumpkinFr.from_int(decode_fr(&input[i]).to_int())) catch unreachable;
//     }

//     const acc = pedersen.commit(G1, frs.items, hash_index);

//     output.*.@"0" = acc.x;
//     output.*.@"1" = acc.y;
//     encode_fr(&output.*.@"0");
//     encode_fr(&output.*.@"1");
// }

pub export fn blackbox_poseidon2_permutation(input: [*]Bn254Fr, result: [*]Bn254Fr, _: usize) void {
    var frs: [4]Bn254Fr = undefined;
    for (0..4) |i| {
        frs[i] = decode_fr(&input[i]);
    }

    const r = Poseidon2.permutation(frs);

    for (0..4) |i| {
        result[i] = r[i];
        encode_fr(&result[i]);
    }
}

pub export fn blackbox_keccak1600(input: [*]const u256, _: usize, result: [*]u256) void {
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

pub export fn blackbox_aes_encrypt(
    in: [*]const u256,
    iv: [*]const u256,
    key: [*]const u256,
    length: usize,
    result: [*]u256,
    r_size: *u256,
) void {
    var input = std.ArrayList(u8).initCapacity(std.heap.page_allocator, length) catch unreachable;
    for (0..length) |i| {
        input.append(@intCast(in[i])) catch unreachable;
    }
    var iv_arr: [16]u8 = undefined;
    var key_arr: [16]u8 = undefined;
    for (0..16) |i| {
        iv_arr[i] = @intCast(iv[i]);
        key_arr[i] = @intCast(key[i]);
    }

    aes.padAndEncryptCbc(&input, &key_arr, &iv_arr) catch unreachable;

    for (0..input.items.len) |i| {
        result[i] = input.items[i];
    }
    r_size.* = input.items.len;
}

pub export fn blackbox_secp256k1_verify_signature(
    hashed_message: [*]const u256,
    _: u64,
    pub_key_x: [*]const u256,
    pub_key_y: [*]const u256,
    sig: [*]const u256,
    result: *u256,
) void {
    verify_signature(std.crypto.ecc.Secp256k1, hashed_message, pub_key_x, pub_key_y, sig, result);
}

pub export fn blackbox_secp256r1_verify_signature(
    hashed_message: [*]const u256,
    _: u64,
    pub_key_x: [*]const u256,
    pub_key_y: [*]const u256,
    sig: [*]const u256,
    result: *u256,
) void {
    verify_signature(std.crypto.ecc.P256, hashed_message, pub_key_x, pub_key_y, sig, result);
}

pub export fn blackbox_schnorr_verify_signature(
    message: [*]const u256,
    size: usize,
    pub_key_x: *Bn254Fr,
    pub_key_y: *Bn254Fr,
    sig: [*]const u256,
    result: *u256,
) void {
    var msg = std.ArrayList(u8).initCapacity(std.heap.page_allocator, size) catch unreachable;
    defer msg.deinit();
    for (0..size) |i| {
        msg.append(@truncate(message[i])) catch unreachable;
    }
    const pub_key = G1.Element.from_xy(decode_fr(pub_key_x), decode_fr(pub_key_y));
    var s: [32]u8 = undefined;
    var e: [32]u8 = undefined;
    for (0..32) |i| {
        s[i] = @truncate(sig[i]);
        e[i] = @truncate(sig[i + 32]);
    }
    const r = schnorr_verify_signature(G1, msg.items, pub_key, .{ .s = s, .e = e });
    result.* = @intFromBool(r);
}

const Point = struct {
    x: Bn254Fr,
    y: Bn254Fr,
    is_infinity: u256,
};

// Fq has to be split over 2 limbs as it doesn't fit in Fr.
const Scalar = struct {
    lo: Bn254Fr,
    hi: Bn254Fr,
};

// The Bn254Fr's here are actually GrumpkinFq's (same field).
pub export fn blackbox_ecc_add(x1: *Bn254Fr, y1: *Bn254Fr, in1: *u256, x2: *Bn254Fr, y2: *Bn254Fr, in2: *u256, output: *Point) void {
    const input1 = if (in1.* == 1) G1.Element.infinity else G1.Element.from_xy(decode_fr(x1), decode_fr(y1));
    const input2 = if (in2.* == 1) G1.Element.infinity else G1.Element.from_xy(decode_fr(x2), decode_fr(y2));
    const r = input1.add(input2).normalize();
    output.*.is_infinity = @intFromBool(r.is_infinity());
    output.*.x = r.x;
    output.*.y = r.y;
    encode_fr(&output.*.x);
    encode_fr(&output.*.y);
}

// This is an msm over grumpkin curve, hence the point coords are GrumpkinFq's, and the scalar field is GrumpkinFr's.
// A GrumpkinFq is a Bn254Fr, and a GrumpkinFr is a Bn254Fq.
// A Grumpkin coordinate point is therefore Noirs native field type.
// As a GrumpkinFr > Bn254Fr, scalars are split into two Bn254Fr's in Noir, and is reconstituted into the GrumpkinFr.
pub export fn blackbox_msm(points_: [*]Point, num_fields: usize, scalars_: [*]Scalar, output: *Point) void {
    const num_points = num_fields / 3;
    var points = std.ArrayList(G1.Element).initCapacity(std.heap.page_allocator, num_points) catch unreachable;
    var scalars = std.ArrayList(GrumpkinFr).initCapacity(std.heap.page_allocator, num_points) catch unreachable;

    for (0..num_points) |i| {
        const p = &points_[i];
        const x = decode_fr(&p.*.x);
        const y = decode_fr(&p.*.y);

        if (p.*.is_infinity == 1) {
            points.append(G1.Element.infinity) catch unreachable;
        } else {
            points.append(G1.Element.from_xy(x, y)) catch unreachable;
        }

        const shi = decode_fr(&scalars_[i].hi).to_int();
        const slo = decode_fr(&scalars_[i].lo).to_int();
        const s = slo | (shi << 128);
        scalars.append(GrumpkinFr.from_int(s)) catch unreachable;
    }

    const e = msm(G1, scalars.items, points.items).normalize();

    output.*.is_infinity = @intFromBool(e.is_infinity());
    output.*.x = e.x;
    output.*.y = e.y;
    encode_fr(&output.*.x);
    encode_fr(&output.*.y);
}

pub export fn blackbox_to_radix(input: *Bn254Fr, output: [*]u256, size: usize, radix: u64) void {
    var in = decode_fr(input).to_int();

    // std.io.getStdOut().writer().print("{} {} {}\n", .{ in, radix, size }) catch unreachable;
    for (0..size) |i| {
        // if (in == 0) {
        //     @memset(output[i..size], 0);
        //     return;
        // }
        const quotient = in / radix;
        // const remainder = in % radix;
        // Might be faster? Optimiser might do the right thing.
        const remainder = in - (quotient * radix);
        output[size - 1 - i] = remainder;
        in = quotient;
    }
}
