const std = @import("std");
// const disassemble = @import("./disassemble.zig");
// const execute = @import("./execute.zig");
pub const io = @import("io.zig");
pub const brillig_vm = @import("brillig_vm.zig");
pub const memory = @import("memory.zig");
pub const foreign_call = @import("foreign_call/package.zig");

pub const BrilligVm = brillig_vm.BrilligVm;

test {
    std.testing.refAllDecls(@This());
    _ = io;
    _ = brillig_vm;
    _ = memory;
}
