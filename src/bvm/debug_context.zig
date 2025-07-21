const std = @import("std");
const debug_info = @import("debug_info.zig");
const BrilligVm = @import("brillig_vm.zig").BrilligVm;

pub const DebugMode = enum {
    none,
    trace,
    step_by_line,
};

pub const DebugContext = struct {
    allocator: std.mem.Allocator,
    parsed_info: ?debug_info.ParsedDebugInfo = null,
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
        if (self.parsed_info) |*info| {
            info.deinit();
        }
    }

    pub fn loadDebugSymbols(self: *DebugContext, artifact_path: []const u8, function_name: []const u8) !void {
        self.artifact_path = artifact_path;
        self.function_name = function_name;

        // Load the artifact file
        const file = try std.fs.cwd().openFile(artifact_path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024);
        defer self.allocator.free(contents);

        var parsed_json = try std.json.parseFromSlice(std.json.Value, self.allocator, contents, .{});
        defer parsed_json.deinit();

        // Parse debug info once for efficient lookup
        self.parsed_info = try debug_info.parseDebugInfo(self.allocator, &parsed_json.value, function_name);
    }

    pub fn afterOpcode(self: *DebugContext, pc: usize, opcode: anytype, ops_executed: u64) void {
        switch (self.mode) {
            .none => return,
            .trace => {
                const stdout = std.io.getStdOut().writer();
                stdout.print("{:0>4}: {:0>4}: {any}\n", .{ ops_executed, pc, opcode }) catch return;
            },
            .step_by_line => {
                if (self.parsed_info) |*info| {
                    const current_line = info.getLineForPC(pc);

                    // Debug output for first few ops and periodically
                    if (ops_executed < 5 or ops_executed % 100 == 0) {
                        const stdout = std.io.getStdOut().writer();
                        stdout.print("\n[Debug: ops={}, PC={}, has_line={}, parsed_info.count={}, artifact_path={s}, function_name={s}]\n", .{
                            ops_executed,
                            pc,
                            current_line != null,
                            info.pc_to_location.count(),
                            self.artifact_path,
                            self.function_name,
                        }) catch return;
                    }

                    // Check if we've reached a new source line
                    if (current_line != null and (self.last_line == null or current_line.? != self.last_line.?)) {
                        self.last_line = current_line;

                        // Show the source line
                        if (info.getSourceInfoForPC(pc)) |source_info| {
                            const stdout = std.io.getStdOut().writer();
                            stdout.print("\n  {s}:{}:{}\n", .{ source_info.file_path, source_info.line_number, source_info.column }) catch return;
                            stdout.print("  {s}\n", .{source_info.source_line}) catch return;

                            // Show column indicator
                            stdout.print("  ", .{}) catch return;
                            var i: usize = 0;
                            while (i < source_info.column - 1) : (i += 1) {
                                stdout.print(" ", .{}) catch return;
                            }
                            stdout.print("^\n", .{}) catch return;
                        }
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

    pub fn handleTrap(self: *DebugContext, _: ?*BrilligVm, error_ctx: *const debug_info.ErrorContext) void {
        if (self.parsed_info == null) {
            // If we don't have parsed info, fall back to the old method
            debug_info.lookupSourceLocation(self.allocator, self.artifact_path, self.function_name, error_ctx.pc) catch |err| {
                std.debug.print("  Could not resolve source location: {}\n", .{err});
            };
        } else {
            // Use the pre-parsed info for efficiency
            if (self.parsed_info.?.getSourceInfoForPC(error_ctx.pc)) |source_info| {
                std.debug.print("  {s}:{}:{}\n", .{ source_info.file_path, source_info.line_number, source_info.column });
                std.debug.print(">>> {}: {s}\n", .{ source_info.line_number, source_info.source_line });

                // Show column indicator
                if (source_info.column > 0) {
                    std.debug.print("    ", .{});
                    var i: usize = 0;
                    const line_digits = std.fmt.count("{}", .{source_info.line_number});
                    while (i < source_info.column + line_digits + 1) : (i += 1) {
                        std.debug.print(" ", .{});
                    }
                    std.debug.print("^\n", .{});
                }
            } else {
                std.debug.print("  PC {} not found in debug symbols\n", .{error_ctx.pc});
            }
        }
    }
};
