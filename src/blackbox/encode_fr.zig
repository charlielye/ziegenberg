const Bn254Fr = @import("../bn254/fr.zig").Fr;

pub inline fn decode_fr(lhs: *Bn254Fr) Bn254Fr {
    if (lhs.*.limbs[3] >> 63 == 0) {
        // std.debug.print("converting {}\n", .{asU256.*});
        lhs.to_montgomery();
        lhs.*.limbs[3] |= 1 << 63;
    }
    var r = Bn254Fr{ .limbs = lhs.*.limbs };
    r.limbs[3] &= ~@as(u64, (1 << 63));
    return r;
}

pub inline fn encode_fr(f: *Bn254Fr) void {
    f.*.limbs[3] |= 1 << 63;
}
