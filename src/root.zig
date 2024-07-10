const std = @import("std");
pub const _ = @import("./bn254/bn254.zig");
const testing = std.testing;

test {
    @import("std").testing.refAllDecls(@This());
}
