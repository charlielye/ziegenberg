const std = @import("std");
const math = std.math;
const builtin = @import("builtin");

const W = [64]u32{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
};

/// Copied and tweaked from std.crypto as round was not public.
pub fn round(b: *const [16]u32, ds: *[8]u32) void {
    var s: [64]u32 align(16) = undefined;
    for (0..16) |i| s[i] = b[i];

    if (!@inComptime()) {
        const V4u32 = @Vector(4, u32);
        switch (builtin.cpu.arch) {
            .aarch64 => if (builtin.zig_backend != .stage2_c and comptime std.Target.aarch64.featureSetHas(builtin.cpu.features, .sha2)) {
                var x: V4u32 = ds[0..4].*;
                var y: V4u32 = ds[4..8].*;
                const s_v = @as(*[16]V4u32, @ptrCast(&s));

                comptime var k: u8 = 0;
                inline while (k < 16) : (k += 1) {
                    if (k > 3) {
                        s_v[k] = asm (
                            \\sha256su0.4s %[w0_3], %[w4_7]
                            \\sha256su1.4s %[w0_3], %[w8_11], %[w12_15]
                            : [w0_3] "=w" (-> V4u32),
                            : [_] "0" (s_v[k - 4]),
                              [w4_7] "w" (s_v[k - 3]),
                              [w8_11] "w" (s_v[k - 2]),
                              [w12_15] "w" (s_v[k - 1]),
                        );
                    }

                    const w: V4u32 = s_v[k] +% @as(V4u32, W[4 * k ..][0..4].*);
                    asm volatile (
                        \\mov.4s v0, %[x]
                        \\sha256h.4s %[x], %[y], %[w]
                        \\sha256h2.4s %[y], v0, %[w]
                        : [x] "=w" (x),
                          [y] "=w" (y),
                        : [_] "0" (x),
                          [_] "1" (y),
                          [w] "w" (w),
                        : "v0"
                    );
                }

                ds[0..4].* = x +% @as(V4u32, ds[0..4].*);
                ds[4..8].* = y +% @as(V4u32, ds[4..8].*);
                return;
            },
            // C backend doesn't currently support passing vectors to inline asm.
            .x86_64 => if (builtin.zig_backend != .stage2_c and comptime std.Target.x86.featureSetHasAll(builtin.cpu.features, .{ .sha, .avx2 })) {
                var x: V4u32 = [_]u32{ ds[5], ds[4], ds[1], ds[0] };
                var y: V4u32 = [_]u32{ ds[7], ds[6], ds[3], ds[2] };
                const s_v = @as(*[16]V4u32, @ptrCast(&s));

                comptime var k: u8 = 0;
                inline while (k < 16) : (k += 1) {
                    if (k < 12) {
                        var tmp = s_v[k];
                        s_v[k + 4] = asm (
                            \\ sha256msg1 %[w4_7], %[tmp]
                            \\ vpalignr $0x4, %[w8_11], %[w12_15], %[result]
                            \\ paddd %[tmp], %[result]
                            \\ sha256msg2 %[w12_15], %[result]
                            : [tmp] "=&x" (tmp),
                              [result] "=&x" (-> V4u32),
                            : [_] "0" (tmp),
                              [w4_7] "x" (s_v[k + 1]),
                              [w8_11] "x" (s_v[k + 2]),
                              [w12_15] "x" (s_v[k + 3]),
                        );
                    }

                    const w: V4u32 = s_v[k] +% @as(V4u32, W[4 * k ..][0..4].*);
                    y = asm ("sha256rnds2 %[x], %[y]"
                        : [y] "=x" (-> V4u32),
                        : [_] "0" (y),
                          [x] "x" (x),
                          [_] "{xmm0}" (w),
                    );

                    x = asm ("sha256rnds2 %[y], %[x]"
                        : [x] "=x" (-> V4u32),
                        : [_] "0" (x),
                          [y] "x" (y),
                          [_] "{xmm0}" (@as(V4u32, @bitCast(@as(u128, @bitCast(w)) >> 64))),
                    );
                }

                ds[0] +%= x[3];
                ds[1] +%= x[2];
                ds[4] +%= x[1];
                ds[5] +%= x[0];
                ds[2] +%= y[3];
                ds[3] +%= y[2];
                ds[6] +%= y[1];
                ds[7] +%= y[0];
                return;
            },
            else => {},
        }
    }

    var i: usize = 16;
    while (i < 64) : (i += 1) {
        s[i] = s[i - 16] +% s[i - 7] +% (math.rotr(u32, s[i - 15], @as(u32, 7)) ^ math.rotr(u32, s[i - 15], @as(u32, 18)) ^ (s[i - 15] >> 3)) +% (math.rotr(u32, s[i - 2], @as(u32, 17)) ^ math.rotr(u32, s[i - 2], @as(u32, 19)) ^ (s[i - 2] >> 10));
    }

    var v: [8]u32 = ds.*;

    const round0 = comptime [_]RoundParam256{
        roundParam256(0, 1, 2, 3, 4, 5, 6, 7, 0),
        roundParam256(7, 0, 1, 2, 3, 4, 5, 6, 1),
        roundParam256(6, 7, 0, 1, 2, 3, 4, 5, 2),
        roundParam256(5, 6, 7, 0, 1, 2, 3, 4, 3),
        roundParam256(4, 5, 6, 7, 0, 1, 2, 3, 4),
        roundParam256(3, 4, 5, 6, 7, 0, 1, 2, 5),
        roundParam256(2, 3, 4, 5, 6, 7, 0, 1, 6),
        roundParam256(1, 2, 3, 4, 5, 6, 7, 0, 7),
        roundParam256(0, 1, 2, 3, 4, 5, 6, 7, 8),
        roundParam256(7, 0, 1, 2, 3, 4, 5, 6, 9),
        roundParam256(6, 7, 0, 1, 2, 3, 4, 5, 10),
        roundParam256(5, 6, 7, 0, 1, 2, 3, 4, 11),
        roundParam256(4, 5, 6, 7, 0, 1, 2, 3, 12),
        roundParam256(3, 4, 5, 6, 7, 0, 1, 2, 13),
        roundParam256(2, 3, 4, 5, 6, 7, 0, 1, 14),
        roundParam256(1, 2, 3, 4, 5, 6, 7, 0, 15),
        roundParam256(0, 1, 2, 3, 4, 5, 6, 7, 16),
        roundParam256(7, 0, 1, 2, 3, 4, 5, 6, 17),
        roundParam256(6, 7, 0, 1, 2, 3, 4, 5, 18),
        roundParam256(5, 6, 7, 0, 1, 2, 3, 4, 19),
        roundParam256(4, 5, 6, 7, 0, 1, 2, 3, 20),
        roundParam256(3, 4, 5, 6, 7, 0, 1, 2, 21),
        roundParam256(2, 3, 4, 5, 6, 7, 0, 1, 22),
        roundParam256(1, 2, 3, 4, 5, 6, 7, 0, 23),
        roundParam256(0, 1, 2, 3, 4, 5, 6, 7, 24),
        roundParam256(7, 0, 1, 2, 3, 4, 5, 6, 25),
        roundParam256(6, 7, 0, 1, 2, 3, 4, 5, 26),
        roundParam256(5, 6, 7, 0, 1, 2, 3, 4, 27),
        roundParam256(4, 5, 6, 7, 0, 1, 2, 3, 28),
        roundParam256(3, 4, 5, 6, 7, 0, 1, 2, 29),
        roundParam256(2, 3, 4, 5, 6, 7, 0, 1, 30),
        roundParam256(1, 2, 3, 4, 5, 6, 7, 0, 31),
        roundParam256(0, 1, 2, 3, 4, 5, 6, 7, 32),
        roundParam256(7, 0, 1, 2, 3, 4, 5, 6, 33),
        roundParam256(6, 7, 0, 1, 2, 3, 4, 5, 34),
        roundParam256(5, 6, 7, 0, 1, 2, 3, 4, 35),
        roundParam256(4, 5, 6, 7, 0, 1, 2, 3, 36),
        roundParam256(3, 4, 5, 6, 7, 0, 1, 2, 37),
        roundParam256(2, 3, 4, 5, 6, 7, 0, 1, 38),
        roundParam256(1, 2, 3, 4, 5, 6, 7, 0, 39),
        roundParam256(0, 1, 2, 3, 4, 5, 6, 7, 40),
        roundParam256(7, 0, 1, 2, 3, 4, 5, 6, 41),
        roundParam256(6, 7, 0, 1, 2, 3, 4, 5, 42),
        roundParam256(5, 6, 7, 0, 1, 2, 3, 4, 43),
        roundParam256(4, 5, 6, 7, 0, 1, 2, 3, 44),
        roundParam256(3, 4, 5, 6, 7, 0, 1, 2, 45),
        roundParam256(2, 3, 4, 5, 6, 7, 0, 1, 46),
        roundParam256(1, 2, 3, 4, 5, 6, 7, 0, 47),
        roundParam256(0, 1, 2, 3, 4, 5, 6, 7, 48),
        roundParam256(7, 0, 1, 2, 3, 4, 5, 6, 49),
        roundParam256(6, 7, 0, 1, 2, 3, 4, 5, 50),
        roundParam256(5, 6, 7, 0, 1, 2, 3, 4, 51),
        roundParam256(4, 5, 6, 7, 0, 1, 2, 3, 52),
        roundParam256(3, 4, 5, 6, 7, 0, 1, 2, 53),
        roundParam256(2, 3, 4, 5, 6, 7, 0, 1, 54),
        roundParam256(1, 2, 3, 4, 5, 6, 7, 0, 55),
        roundParam256(0, 1, 2, 3, 4, 5, 6, 7, 56),
        roundParam256(7, 0, 1, 2, 3, 4, 5, 6, 57),
        roundParam256(6, 7, 0, 1, 2, 3, 4, 5, 58),
        roundParam256(5, 6, 7, 0, 1, 2, 3, 4, 59),
        roundParam256(4, 5, 6, 7, 0, 1, 2, 3, 60),
        roundParam256(3, 4, 5, 6, 7, 0, 1, 2, 61),
        roundParam256(2, 3, 4, 5, 6, 7, 0, 1, 62),
        roundParam256(1, 2, 3, 4, 5, 6, 7, 0, 63),
    };
    inline for (round0) |r| {
        v[r.h] = v[r.h] +% (math.rotr(u32, v[r.e], @as(u32, 6)) ^ math.rotr(u32, v[r.e], @as(u32, 11)) ^ math.rotr(u32, v[r.e], @as(u32, 25))) +% (v[r.g] ^ (v[r.e] & (v[r.f] ^ v[r.g]))) +% W[r.i] +% s[r.i];

        v[r.d] = v[r.d] +% v[r.h];

        v[r.h] = v[r.h] +% (math.rotr(u32, v[r.a], @as(u32, 2)) ^ math.rotr(u32, v[r.a], @as(u32, 13)) ^ math.rotr(u32, v[r.a], @as(u32, 22))) +% ((v[r.a] & (v[r.b] | v[r.c])) | (v[r.b] & v[r.c]));
    }

    for (ds, v) |*dv, vv| dv.* +%= vv;
    // for (0..8) |idx| {
    //     ds[idx] +%= v[idx];
    // }
}

const RoundParam256 = struct {
    a: usize,
    b: usize,
    c: usize,
    d: usize,
    e: usize,
    f: usize,
    g: usize,
    h: usize,
    i: usize,
};

fn roundParam256(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize) RoundParam256 {
    return RoundParam256{
        .a = a,
        .b = b,
        .c = c,
        .d = d,
        .e = e,
        .f = f,
        .g = g,
        .h = h,
        .i = i,
    };
}
