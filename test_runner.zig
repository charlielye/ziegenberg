const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var args = std.process.args();
    const filterName = if (args.skip()) args.next() else null;
    for (builtin.test_functions) |t| {
        if (filterName != null and !std.mem.eql(u8, t.name, filterName.?)) {
            continue;
        }
        if (filterName == null and std.mem.containsAtLeast(u8, t.name, 1, ".SKIP_")) {
            continue;
        }
        try t.func();
    }
}
