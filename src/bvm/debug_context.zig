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
    debug_info: ?*const nargo_debug_info.DebugInfo = null,
    mode: DebugMode,
    last_line: ?u32 = null,
    artifact_path: []const u8 = "",
    function_name: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, mode: DebugMode) DebugContext {
        return DebugContext{
            .allocator = allocator,
            .mode = mode,
        };
    }

    pub fn deinit(self: *DebugContext) void {
        // Debug info is now owned by the artifact/contract, not by us
        _ = self;
    }

    pub fn afterOpcode(self: *DebugContext, pc: usize, opcode: anytype, ops_executed: u64) void {
        switch (self.mode) {
            .none => return,
            .trace => {
                const stdout = std.io.getStdOut().writer();
                stdout.print("{:0>4}: {:0>4}: {any}\n", .{ ops_executed, pc, opcode }) catch return;
            },
            .step_by_line => {
                if (self.debug_info) |info| {
                    const source_loc = info.getSourceLocation(pc);
                    const current_line = if (source_loc) |loc| loc.line else null;

                    // Debug output for first few ops and periodically
                    if (ops_executed < 5 or ops_executed % 100 == 0) {
                        const stdout = std.io.getStdOut().writer();
                        stdout.print("\n[Debug: ops={}, PC={}, has_line={}, pc_mappings={}, artifact_path={s}, function_name={s}]\n", .{
                            ops_executed,
                            pc,
                            current_line != null,
                            info.pc_to_location_idx.count(),
                            self.artifact_path,
                            self.function_name,
                        }) catch return;
                    }

                    // Check if we've reached a new source line
                    if (current_line != null and (self.last_line == null or current_line.? != self.last_line.?)) {
                        self.last_line = current_line;

                        // Show the source line
                        const stdout = std.io.getStdOut().writer();
                        stdout.print("\n", .{}) catch return;
                        info.printSourceLocation(pc, 0);
                    }
                } else {
                    const stdout = std.io.getStdOut().writer();
                    if (ops_executed == 1) {
                        stdout.print("\n[Debug: No parsed_info available for artifact_path={s}, function_name={s}]\n", .{
                            self.artifact_path,
                            self.function_name,
                        }) catch return;
                    }
                }
            },
        }
    }
};
