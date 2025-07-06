const std = @import("std");
const Fr = @import("../bn254/fr.zig").Fr;
const Poseidon2Sponge = @import("./sponge.zig").Poseidon2Sponge;
const rdtsc = @import("../timer/rdtsc.zig").rdtsc;

pub fn hash(input: []const Fr) Fr {
    return Poseidon2Sponge.hash_fixed_length(1, input)[0];
}

/// Hashes bytes by chunking into 31 bytes.
pub fn hashBytes(input: []const u8) Fr {
    const num_fields = input.len / 31 + (@intFromBool(input.len % 31 != 0));
    std.debug.assert(num_fields <= 128);
    var input_fields: [128]Fr = undefined;

    for (input_fields[0..num_fields], 0..) |*f, i| {
        var buf: [32]u8 = .{0} ** 32;
        const chunk_len = @min(31, input.len - (31 * i));
        const chunk = input[i * 31 .. i * 31 + chunk_len];
        for (chunk, 0..) |b, j| buf[31 - j] = b;
        f.* = Fr.from_buf(buf);
    }
    // std.debug.print("{x}\n", .{input_fields[0..num_fields]});

    return hash(input_fields[0..num_fields]);
}

test "poseidon2 basic test" {
    const a = Fr.random();
    const b = Fr.random();
    const c = Fr.random();
    const d = Fr.random();

    const input1 = &[_]Fr{ a, b, c, d };
    const input2 = &[_]Fr{ d, c, b, a };

    const r0 = hash(input1);
    const r1 = hash(input1);
    const r2 = hash(input2);

    try std.testing.expect(r0.eql(r1));
    try std.testing.expect(!r0.eql(r2));
}

// N.B. these hardcoded values were extracted from the algorithm being tested. These are NOT independent test vectors!
test "poseidon2 hash consistency" {
    const a = Fr.from_int(0x9a807b615c4d3e2fa0b1c2d3e4f56789fedcba9876543210abcdef0123456789);
    const b = Fr.from_int(0x9a807b615c4d3e2fa0b1c2d3e4f56789fedcba9876543210abcdef0123456789);
    const c = Fr.from_int(0x9a807b615c4d3e2fa0b1c2d3e4f56789fedcba9876543210abcdef0123456789);
    const d = Fr.from_int(0x9a807b615c4d3e2fa0b1c2d3e4f56789fedcba9876543210abcdef0123456789);

    const input = &[_]Fr{ a, b, c, d };
    const result = hash(input);

    const expected = Fr.from_int(0x2f43a0f83b51a6f5fc839dea0ecec74947637802a579fa9841930a25a0bcec11);

    try std.testing.expect(result.eql(expected));
}

test "hash bytes" {
    const h = hashBytes("i would like to hash somewhere between 32 and 64 bytes");
    std.debug.print("{x}\n", .{h});
}

test "poseidon2 bench" {
    const num_hashes = 1 << 13;
    std.debug.print("num hashes: {}\n", .{num_hashes});
    var total_time: u64 = 0;
    var total_clocks: u64 = 0;

    var a = Fr.random();
    const b = Fr.random();

    var t = try std.time.Timer.start();
    const before = rdtsc();
    for (0..num_hashes) |_| {
        a = hash(&[_]Fr{ a, b });
    }
    total_clocks += rdtsc() - before;
    total_time += t.read();

    // acc.print();
    std.debug.print("time per hash: {}us\n", .{total_time / num_hashes / 1_000});
    std.debug.print("cycles per hash: {}\n", .{total_clocks / num_hashes});
}
