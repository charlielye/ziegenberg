const std = @import("std");
const nargo_debug_info = @import("../nargo/debug_info.zig");
const BrilligVm = @import("brillig_vm.zig").BrilligVm;

pub const DebugMode = enum {
    none,
    trace,
    step_by_line,
};

pub const DebugContext = struct {
    allocator: std.mem.Allocator,
    debug_info: *const nargo_debug_info.DebugInfo,
    mode: DebugMode,
    last_line: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, mode: DebugMode, debug_info: *const nargo_debug_info.DebugInfo) DebugContext {
        return DebugContext{
            .allocator = allocator,
            .mode = mode,
            .debug_info = debug_info,
        };
    }

    pub fn afterOpcode(self: *DebugContext, pc: usize, opcode: anytype, ops_executed: u64) void {
        switch (self.mode) {
            .none => return,
            .trace => {
                const stdout = std.io.getStdOut().writer();
                stdout.print("{:0>4}: {:0>4}: {any}\n", .{ ops_executed, pc, opcode }) catch return;
            },
            .step_by_line => {
                const source_loc = self.debug_info.getSourceLocation(pc);
                const current_line = if (source_loc) |loc| loc.line else null;

                // Check if we've reached a new source line
                if (current_line != null and (self.last_line == null or current_line.? != self.last_line.?)) {
                    self.last_line = current_line;

                    // Show the source line
                    const stdout = std.io.getStdOut().writer();
                    stdout.print("\n", .{}) catch return;
                    self.debug_info.printSourceLocationWithOptions(pc, 0, false);
                }
            },
        }
    }
};
