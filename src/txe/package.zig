const std = @import("std");
const txe = @import("./txe.zig");

pub const Txe = txe.Txe;

test {
    std.testing.refAllDecls(@This());
    _ = txe;
}
