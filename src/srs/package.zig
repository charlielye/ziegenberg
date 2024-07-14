pub const NetSrs = @import("net_srs.zig").NetSrs;

test {
    @import("std").testing.refAllDecls(@This());
}
