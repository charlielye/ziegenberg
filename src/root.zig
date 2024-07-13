const std = @import("std");
pub const _ = @import("./bn254/g1.zig");
const testing = std.testing;

test {
    @import("std").testing.refAllDecls(@This());
}
