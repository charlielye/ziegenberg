const std = @import("std");
usingnamespace @import("bn254/g1.zig");
usingnamespace @import("grumpkin/g1.zig");
usingnamespace @import("srs/package.zig");
usingnamespace @import("msm/naive.zig");
const testing = std.testing;

test {
    @import("std").testing.refAllDecls(@This());
}
