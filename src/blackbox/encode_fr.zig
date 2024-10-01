pub inline fn decode_fr(lhs: anytype) @TypeOf(lhs.*) {
    if (lhs.*.limbs[3] >> 63 == 0) {
        // std.debug.print("converting {}\n", .{asU256.*});
        lhs.to_montgomery();
        lhs.*.limbs[3] |= 1 << 63;
    }
    var r = @TypeOf(lhs.*){ .limbs = lhs.*.limbs };
    r.limbs[3] &= ~@as(u64, (1 << 63));
    return r;
}

pub inline fn encode_fr(f: anytype) void {
    f.*.limbs[3] |= 1 << 63;
}
