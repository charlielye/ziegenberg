const std = @import("std");
const file_srs = @import("file_srs.zig");

pub const FileSrs = file_srs.FileSrs;
// This really slows down compilation times for some reason.
// pub const NetSrs = @import("net_srs.zig").NetSrs;

test {
    std.testing.refAllDecls(@This());
    _ = file_srs;
}
