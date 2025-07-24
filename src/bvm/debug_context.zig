const std = @import("std");
const nargo_debug_info = @import("../nargo/debug_info.zig");
const BrilligVm = @import("brillig_vm.zig").BrilligVm;
const dap = @import("../debugger/dap.zig");

pub const DebugMode = enum {
    none,
    trace,
    step_by_line,
    dap,
};

pub const ExecutionState = enum {
    running,
    paused,
    step_over,
    step_into,
    step_out,
    terminated,
};

pub const VmInfo = struct {
    pc: usize,
    callstack: []const usize,
    debug_info: *const nargo_debug_info.DebugInfo,
    // Track if we're stepping out of this VM
    stepping_out: bool = false,
    // Validated breakpoints for this specific VM
    validated_breakpoints: std.StringHashMap(std.ArrayList(u32)),
};

// Breakpoint information stored per file
pub const FileBreakpoints = struct {
    file_path: []const u8,
    lines: std.ArrayList(u32),
};

pub const DebugContext = struct {
    allocator: std.mem.Allocator,
    mode: DebugMode,
    last_line: ?u32 = null,

    // DAP-specific fields
    dap_protocol: ?*dap.DapProtocol = null,
    execution_state: ExecutionState = .paused,
    current_thread_id: u32 = 1,

    // Step out tracking
    step_out_target_depth: ?usize = null,

    // Stack of Brillig VMs (CVM → BVM → CVM → BVM pattern)
    vm_info_stack: std.ArrayList(VmInfo),

    // Requested breakpoints from the client: map from file path to list of line numbers
    requested_breakpoints: std.StringHashMap(std.ArrayList(u32)),

    // Breakpoint ID counter for generating unique IDs
    next_breakpoint_id: u32 = 1,
    // Map from file path + line to breakpoint ID for stable IDs
    breakpoint_id_map: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator, mode: DebugMode) !DebugContext {
        var ctx = DebugContext{
            .allocator = allocator,
            .mode = mode,
            .vm_info_stack = std.ArrayList(VmInfo).init(allocator),
            .requested_breakpoints = std.StringHashMap(std.ArrayList(u32)).init(allocator),
            .breakpoint_id_map = std.StringHashMap(u32).init(allocator),
        };

        // Initialize DAP if in DAP mode
        if (mode == .dap) {
            try ctx.initDap();
        }

        return ctx;
    }

    pub fn deinit(self: *DebugContext) void {
        if (self.dap_protocol) |protocol| {
            protocol.deinit();
            self.allocator.destroy(protocol);
        }

        // Clean up VM stack and their validated breakpoints
        for (self.vm_info_stack.items) |*vm_info| {
            var iter = vm_info.validated_breakpoints.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            vm_info.validated_breakpoints.deinit();
        }
        self.vm_info_stack.deinit();

        // Clean up requested breakpoints
        var iter = self.requested_breakpoints.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.requested_breakpoints.deinit();

        // Clean up breakpoint ID map
        var id_iter = self.breakpoint_id_map.iterator();
        while (id_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.breakpoint_id_map.deinit();
    }

    pub fn onVmEnter(self: *DebugContext, debug_info: *const nargo_debug_info.DebugInfo) void {
        // When entering a new Brillig VM, push it onto the stack
        var vm_info = VmInfo{
            .pc = 0,
            .callstack = &.{},
            .debug_info = debug_info,
            .validated_breakpoints = std.StringHashMap(std.ArrayList(u32)).init(self.allocator),
        };

        // Validate requested breakpoints for this VM
        self.validateBreakpointsForVm(&vm_info) catch {};

        self.vm_info_stack.append(vm_info) catch unreachable;

        // Send DAP event to update breakpoints if we have a protocol
        if (self.dap_protocol != null and self.vm_info_stack.items.len == 1) {
            // Only send update for the first VM to avoid spam
            self.sendBreakpointUpdate() catch {};
            self.sendBreakpointUpdate() catch {};
        }
    }

    pub fn onVmExit(self: *DebugContext) void {
        var current_vm = self.vm_info_stack.pop() orelse return;

        // Clean up validated breakpoints for this VM
        var iter = current_vm.validated_breakpoints.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        current_vm.validated_breakpoints.deinit();

        // If we were stepping out of this VM and there's a parent VM
        if (current_vm.stepping_out and self.vm_info_stack.items.len > 0) {
            // Mark that we should pause when the parent VM resumes
            self.execution_state = .paused;
            self.step_out_target_depth = null;
        }

        // Send DAP event to restore parent VM's breakpoints if applicable
        if (self.dap_protocol != null and self.vm_info_stack.items.len > 0) {
            self.sendBreakpointUpdate() catch {};
        }
    }

    pub fn afterOpcode(self: *DebugContext, pc: usize, opcode: anytype, ops_executed: u64, vm: anytype) void {
        const debug_info = self.vm_info_stack.items[self.vm_info_stack.items.len - 1].debug_info;

        switch (self.mode) {
            .none => return,
            .trace => {
                const stdout = std.io.getStdOut().writer();
                stdout.print("{:0>4}: {:0>4}: {any}\n", .{ ops_executed, pc, opcode }) catch return;
            },
            .step_by_line => {
                const source_loc = debug_info.getSourceLocation(pc);
                const current_line = if (source_loc) |loc| loc.line else null;

                // Check if we've reached a new source line
                if (current_line != null and (self.last_line == null or current_line.? != self.last_line.?)) {
                    self.last_line = current_line;

                    // Show the source line
                    const stdout = std.io.getStdOut().writer();
                    stdout.print("\n", .{}) catch return;
                    debug_info.printSourceLocationWithOptions(pc, 0, false);
                }
            },
            .dap => self.handleDapMode(pc, ops_executed, vm),
        }
    }

    fn initDap(self: *DebugContext) !void {
        self.dap_protocol = try self.allocator.create(dap.DapProtocol);
        self.dap_protocol.?.* = dap.DapProtocol.init(self.allocator);

        // Handle DAP initialization sequence
        try self.handleDapInitialization();
    }

    fn handleDapInitialization(self: *DebugContext) !void {
        const protocol = self.dap_protocol.?;

        // Wait for initialize request
        const init_msg = try protocol.readMessage(self.allocator);
        defer init_msg.deinit();

        const obj = init_msg.value.object;
        const req_type = obj.get("type").?.string;
        if (!std.mem.eql(u8, req_type, "request")) return error.UnexpectedMessage;

        const command = obj.get("command").?.string;
        if (!std.mem.eql(u8, command, "initialize")) return error.UnexpectedCommand;

        const seq: u32 = @intCast(obj.get("seq").?.integer);

        // Send initialize response with capabilities
        const capabilities = dap.Capabilities{};
        try protocol.sendResponse(seq, "initialize", true, capabilities);

        // Send initialized event
        try protocol.sendEvent("initialized", .{});

        // Handle initial DAP requests until we get configurationDone
        while (true) {
            const msg = try protocol.readMessage(self.allocator);
            defer msg.deinit();

            const msg_obj = msg.value.object;
            const msg_type = msg_obj.get("type").?.string;
            if (!std.mem.eql(u8, msg_type, "request")) continue;

            const cmd_seq: u32 = @intCast(msg_obj.get("seq").?.integer);
            const cmd = msg_obj.get("command").?.string;

            if (std.mem.eql(u8, cmd, "launch") or std.mem.eql(u8, cmd, "attach")) {
                // Send response
                try protocol.sendResponse(cmd_seq, cmd, true, .{});
            } else if (std.mem.eql(u8, cmd, "setBreakpoints")) {
                // Parse the request arguments
                const args = msg_obj.get("arguments") orelse return error.NoArguments;
                const source = args.object.get("source") orelse return error.NoSource;
                const path = source.object.get("path") orelse return error.NoPath;
                const source_breakpoints = args.object.get("breakpoints") orelse return error.NoBreakpoints;

                // During initialization, we might not have debug info yet, so just accept the breakpoints
                if (self.vm_info_stack.items.len == 0) {
                    // Store requested breakpoints for later validation
                    var line_list = std.ArrayList(u32).init(self.allocator);
                    for (source_breakpoints.array.items) |bp| {
                        const line = bp.object.get("line") orelse continue;
                        try line_list.append(@intCast(line.integer));
                    }
                    try self.requested_breakpoints.put(path.string, line_list);

                    // Return simple verified response
                    var verified = try self.allocator.alloc(dap.Breakpoint, source_breakpoints.array.items.len);
                    for (source_breakpoints.array.items, 0..) |bp, i| {
                        const line = bp.object.get("line") orelse continue;
                        const line_num: u32 = @intCast(line.integer);
                        // Get or create a stable ID for this breakpoint
                        const bp_id = try self.getOrCreateBreakpointId(path.string, line_num);
                        verified[i] = .{
                            .id = bp_id,
                            .verified = true,
                            .line = line_num,
                            .source = .{ .path = path.string },
                        };
                    }
                    const response = .{ .breakpoints = verified };
                    try protocol.sendResponse(cmd_seq, cmd, true, response);
                    self.allocator.free(verified);
                } else {
                    // Set breakpoints with line adjustment
                    const verified_breakpoints = try self.setBreakpoints(path.string, source_breakpoints.array.items);
                    defer self.allocator.free(verified_breakpoints);

                    const response = .{ .breakpoints = verified_breakpoints };
                    try protocol.sendResponse(cmd_seq, cmd, true, response);
                }
            } else if (std.mem.eql(u8, cmd, "threads")) {
                const threads = .{ .threads = &[_]dap.Thread{.{ .id = 1, .name = "main" }} };
                try protocol.sendResponse(cmd_seq, cmd, true, threads);
            } else if (std.mem.eql(u8, cmd, "configurationDone")) {
                try protocol.sendResponse(cmd_seq, cmd, true, .{});
                // Send stopped event for entry after configuration is done
                try self.sendStoppedEvent("entry", 0);
                break;
            } else if (std.mem.eql(u8, cmd, "disconnect")) {
                self.execution_state = .terminated;
                try protocol.sendResponse(cmd_seq, cmd, true, .{});
                return;
            } else {
                // Unknown command during initialization
                try protocol.sendResponse(cmd_seq, cmd, false, .{ .message = "Command not supported during initialization" });
            }
        }
    }

    fn handleDapMode(self: *DebugContext, pc: usize, ops_executed: u64, vm: anytype) void {
        _ = ops_executed;

        const debug_info = self.vm_info_stack.items[self.vm_info_stack.items.len - 1].debug_info;
        const source_loc = debug_info.getSourceLocation(pc);
        const current_line = if (source_loc) |loc| loc.line else null;

        // For step out, check if we've returned to the target depth
        if (self.execution_state == .step_out) {
            if (self.step_out_target_depth) |target_depth| {
                const current_depth = vm.callstack.items.len;
                if (current_depth <= target_depth) {
                    // We've stepped out - update the current line so VSCode knows where we are
                    if (current_line) |line| {
                        self.last_line = line;
                    }
                    self.execution_state = .paused;
                    self.step_out_target_depth = null;
                    self.sendStoppedEvent("step", pc) catch {};
                    self.waitForDapCommands(pc, vm);
                }
            }
            return; // Don't check for new lines during step out
        }

        // Check if we've reached a new source line
        if (current_line != null and (self.last_line == null or current_line.? != self.last_line.?)) {
            self.last_line = current_line;

            switch (self.execution_state) {
                .running => {
                    // Check for breakpoints
                    if (self.checkBreakpoint(source_loc)) {
                        self.execution_state = .paused;
                        self.sendStoppedEvent("breakpoint", pc) catch {};
                        self.waitForDapCommands(pc, vm);
                    }
                },
                .paused => {
                    self.waitForDapCommands(pc, vm);
                },
                .step_over, .step_into => {
                    self.execution_state = .paused;
                    self.sendStoppedEvent("step", pc) catch {};
                    self.waitForDapCommands(pc, vm);
                },
                .step_out => unreachable, // Handled above
                .terminated => {},
            }
        }
    }

    fn waitForDapCommands(self: *DebugContext, current_pc: usize, vm: anytype) void {
        const protocol = self.dap_protocol.?;

        while (self.execution_state == .paused) {
            const msg = protocol.readMessage(self.allocator) catch |err| {
                std.debug.print("DAP read error: {}\n", .{err});
                continue;
            };
            defer msg.deinit();

            self.processDapCommand(msg.value, current_pc, vm) catch |err| {
                std.debug.print("DAP command error: {}\n", .{err});
            };
        }
    }

    fn processDapCommand(self: *DebugContext, msg: std.json.Value, current_pc: usize, vm: anytype) !void {
        const protocol = self.dap_protocol.?;
        const obj = msg.object;

        const msg_type = obj.get("type").?.string;
        if (!std.mem.eql(u8, msg_type, "request")) return;

        const seq: u32 = @intCast(obj.get("seq").?.integer);
        const command = obj.get("command").?.string;

        if (std.mem.eql(u8, command, "continue")) {
            self.execution_state = .running;
            try protocol.sendResponse(seq, command, true, .{ .allThreadsContinued = true });
        } else if (std.mem.eql(u8, command, "next")) {
            self.execution_state = .step_over;
            try protocol.sendResponse(seq, command, true, .{});
        } else if (std.mem.eql(u8, command, "stepIn")) {
            self.execution_state = .step_into;
            try protocol.sendResponse(seq, command, true, .{});
        } else if (std.mem.eql(u8, command, "stepOut")) {
            // Set target depth to one less than current depth
            const current_depth = vm.callstack.items.len;
            if (current_depth > 1) {
                // Step out within the current VM
                self.step_out_target_depth = current_depth - 1;
                self.execution_state = .step_out;
            } else if (self.vm_info_stack.items.len > 1) {
                // At top level of current VM but there are outer Brillig VMs
                // Mark the current VM as stepping out
                self.vm_info_stack.items[self.vm_info_stack.items.len - 1].stepping_out = true;
                self.execution_state = .running; // Let it run until VM exits
            } else {
                // Already at top level of top VM.
                self.execution_state = .step_over;
            }
            try protocol.sendResponse(seq, command, true, .{});
        } else if (std.mem.eql(u8, command, "threads")) {
            const threads = .{ .threads = &[_]dap.Thread{.{ .id = 1, .name = "main" }} };
            try protocol.sendResponse(seq, command, true, threads);
        } else if (std.mem.eql(u8, command, "stackTrace")) {
            try self.sendStackTrace(seq, current_pc);
        } else if (std.mem.eql(u8, command, "disconnect")) {
            self.execution_state = .terminated;
            try protocol.sendResponse(seq, command, true, .{});
        } else if (std.mem.eql(u8, command, "setBreakpoints")) {
            // Parse the request arguments
            const args = obj.get("arguments") orelse return error.NoArguments;
            const source = args.object.get("source") orelse return error.NoSource;
            const path = source.object.get("path") orelse return error.NoPath;
            const source_breakpoints = args.object.get("breakpoints") orelse return error.NoBreakpoints;

            // Set breakpoints and send response
            const verified_breakpoints = try self.setBreakpoints(path.string, source_breakpoints.array.items);
            defer self.allocator.free(verified_breakpoints);

            const response = .{ .breakpoints = verified_breakpoints };
            try protocol.sendResponse(seq, command, true, response);
        } else if (std.mem.eql(u8, command, "configurationDone")) {
            try protocol.sendResponse(seq, command, true, .{});
        } else {
            // Unknown command - send error response
            try protocol.sendResponse(seq, command, false, .{ .message = "Unsupported command" });
        }
    }

    fn sendStoppedEvent(self: *DebugContext, reason: []const u8, pc: usize) !void {
        _ = pc;
        const protocol = self.dap_protocol.?;
        const body = dap.StoppedEventBody{
            .reason = reason,
            .threadId = self.current_thread_id,
        };
        try protocol.sendEvent("stopped", body);
    }

    fn sendStackTrace(self: *DebugContext, request_seq: u32, current_pc: usize) !void {
        const protocol = self.dap_protocol.?;

        var frames = std.ArrayList(dap.StackFrame).init(self.allocator);
        defer frames.deinit();

        var frame_id: u32 = 0;

        // If we have Brillig VMs on the stack, process them from innermost to outermost
        if (self.vm_info_stack.items.len > 0) {
            // Add frames for the current VM (innermost)
            const current_vm = &self.vm_info_stack.items[self.vm_info_stack.items.len - 1];

            // Add current frame
            if (current_vm.debug_info.getSourceLocation(current_pc)) |loc| {
                var file_key_buf: [32]u8 = undefined;
                const file_key = try std.fmt.bufPrint(&file_key_buf, "{}", .{loc.file_id});

                if (current_vm.debug_info.files.get(file_key)) |file_info| {
                    try frames.append(.{
                        .id = frame_id,
                        .name = "brillig_current",
                        .source = .{
                            .path = file_info.path,
                            .name = std.fs.path.basename(file_info.path),
                        },
                        .line = loc.line,
                        .column = loc.column,
                    });
                    frame_id += 1;
                }
            }

            // Add frames from the current VM's callstack
            for (current_vm.callstack) |return_pc| {
                if (current_vm.debug_info.getSourceLocation(return_pc)) |loc| {
                    var file_key_buf: [32]u8 = undefined;
                    const file_key = try std.fmt.bufPrint(&file_key_buf, "{}", .{loc.file_id});

                    if (current_vm.debug_info.files.get(file_key)) |file_info| {
                        try frames.append(.{
                            .id = frame_id,
                            .name = "brillig_frame",
                            .source = .{
                                .path = file_info.path,
                                .name = std.fs.path.basename(file_info.path),
                            },
                            .line = loc.line,
                            .column = loc.column,
                        });
                        frame_id += 1;
                    }
                }
            }

            // Add frames from outer VMs
            var i = self.vm_info_stack.items.len - 1;
            while (i > 0) : (i -= 1) {
                const outer_vm = &self.vm_info_stack.items[i - 1];
                if (outer_vm.debug_info.getSourceLocation(outer_vm.pc)) |loc| {
                    var file_key_buf: [32]u8 = undefined;
                    const file_key = try std.fmt.bufPrint(&file_key_buf, "{}", .{loc.file_id});

                    if (outer_vm.debug_info.files.get(file_key)) |file_info| {
                        try frames.append(.{
                            .id = frame_id,
                            .name = "brillig_caller",
                            .source = .{
                                .path = file_info.path,
                                .name = std.fs.path.basename(file_info.path),
                            },
                            .line = loc.line,
                            .column = loc.column,
                        });
                        frame_id += 1;
                    }
                }
            }
        }

        const response_body = .{
            .stackFrames = frames.items,
            .totalFrames = frames.items.len,
        };

        try protocol.sendResponse(request_seq, "stackTrace", true, response_body);
    }

    fn setBreakpoints(self: *DebugContext, file_path: []const u8, source_breakpoints: []const std.json.Value) ![]dap.Breakpoint {
        // Update requested breakpoints for this file
        if (self.requested_breakpoints.fetchRemove(file_path)) |existing| {
            existing.value.deinit();
        }

        // Store new requested breakpoints
        var line_list = std.ArrayList(u32).init(self.allocator);
        errdefer line_list.deinit();

        for (source_breakpoints) |bp| {
            const line = bp.object.get("line") orelse continue;
            try line_list.append(@intCast(line.integer));
        }
        try self.requested_breakpoints.put(file_path, line_list);

        // If no VM is active yet, return unvalidated response
        if (self.vm_info_stack.items.len == 0) {
            var verified = try self.allocator.alloc(dap.Breakpoint, source_breakpoints.len);
            for (source_breakpoints, 0..) |bp, i| {
                const line = bp.object.get("line") orelse continue;
                const line_num: u32 = @intCast(line.integer);
                const bp_id = try self.getOrCreateBreakpointId(file_path, line_num);
                verified[i] = .{
                    .id = bp_id,
                    .verified = true,
                    .line = line_num,
                    .source = .{ .path = file_path },
                };
            }
            return verified;
        }

        // Revalidate for current VM
        var current_vm = &self.vm_info_stack.items[self.vm_info_stack.items.len - 1];

        // Remove existing validated breakpoints for this file
        if (current_vm.validated_breakpoints.fetchRemove(file_path)) |existing| {
            existing.value.deinit();
        }

        // Validate and return response
        return self.validateBreakpointsForFile(current_vm, file_path, source_breakpoints);
    }

    fn checkBreakpoint(self: *const DebugContext, source_loc: ?nargo_debug_info.SourceLocation) bool {
        const loc = source_loc orelse return false;

        // Get the current VM's validated breakpoints
        if (self.vm_info_stack.items.len == 0) return false;
        const current_vm = &self.vm_info_stack.items[self.vm_info_stack.items.len - 1];

        // Get the file path for this location
        var file_key_buf: [32]u8 = undefined;
        const file_key = std.fmt.bufPrint(&file_key_buf, "{}", .{loc.file_id}) catch return false;

        const file_info = current_vm.debug_info.files.get(file_key) orelse return false;

        // Check if we have validated breakpoints for this file in current VM
        const breakpoint_lines = current_vm.validated_breakpoints.get(file_info.path) orelse return false;

        // Check if current line has a breakpoint
        for (breakpoint_lines.items) |bp_line| {
            if (bp_line == loc.line) {
                return true;
            }
        }

        return false;
    }

    fn getOrCreateBreakpointId(self: *DebugContext, file_path: []const u8, line: u32) !u32 {
        // Create a key from file path and line number
        var key_buf: [4096]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}:{}", .{ file_path, line });

        // Check if we already have an ID for this breakpoint
        if (self.breakpoint_id_map.get(key)) |id| {
            return id;
        }

        // Generate a new ID
        const id = self.next_breakpoint_id;
        self.next_breakpoint_id += 1;

        // Store the mapping (we need to duplicate the key)
        const key_copy = try self.allocator.dupe(u8, key);
        try self.breakpoint_id_map.put(key_copy, id);

        return id;
    }

    fn validateBreakpointsForVm(self: *DebugContext, vm_info: *VmInfo) !void {
        // Validate all requested breakpoints for this VM
        var iter = self.requested_breakpoints.iterator();
        while (iter.next()) |entry| {
            const file_path = entry.key_ptr.*;
            const requested_lines = entry.value_ptr.*;

            // Create validated line list for this file
            var validated_lines = std.ArrayList(u32).init(self.allocator);
            errdefer validated_lines.deinit();

            for (requested_lines.items) |requested_line| {
                // Find the next valid line with opcodes
                const actual_line = try vm_info.debug_info.findNextLineWithOpcodes(file_path, requested_line) orelse requested_line;
                try validated_lines.append(actual_line);
            }

            try vm_info.validated_breakpoints.put(file_path, validated_lines);
        }
    }

    fn validateBreakpointsForFile(self: *DebugContext, vm_info: *VmInfo, file_path: []const u8, source_breakpoints: []const std.json.Value) ![]dap.Breakpoint {
        // Create validated line list for this file
        var validated_lines = std.ArrayList(u32).init(self.allocator);
        errdefer validated_lines.deinit();

        // Create verified breakpoints response
        var verified = try self.allocator.alloc(dap.Breakpoint, source_breakpoints.len);

        // Validate each requested breakpoint
        for (source_breakpoints, 0..) |bp, i| {
            const requested_line = bp.object.get("line") orelse continue;
            const line_num: u32 = @intCast(requested_line.integer);

            // Find the next valid line with opcodes
            const actual_line = try vm_info.debug_info.findNextLineWithOpcodes(file_path, line_num) orelse line_num;

            try validated_lines.append(actual_line);

            const bp_id = try self.getOrCreateBreakpointId(file_path, line_num);
            verified[i] = .{
                .id = bp_id,
                .verified = actual_line != 0,
                .line = actual_line,
                .source = .{ .path = file_path },
            };

            // If the actual line differs from requested, add a message
            if (actual_line != line_num and actual_line != 0) {
                var msg_buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&msg_buf, "Breakpoint moved from line {} to {}", .{ line_num, actual_line });
                verified[i].message = try self.allocator.dupe(u8, msg);
            }
        }

        // Store validated breakpoints for this VM
        try vm_info.validated_breakpoints.put(file_path, validated_lines);

        return verified;
    }

    fn sendBreakpointUpdate(self: *DebugContext) !void {
        // Send a breakpoint event to notify VSCode about validated breakpoints
        if (self.dap_protocol == null or self.vm_info_stack.items.len == 0) return;

        const current_vm = &self.vm_info_stack.items[self.vm_info_stack.items.len - 1];

        // For each file with breakpoints, send an update
        var iter = current_vm.validated_breakpoints.iterator();
        while (iter.next()) |entry| {
            const file_path = entry.key_ptr.*;
            const validated_lines = entry.value_ptr.*;

            // Get corresponding requested lines
            const requested_lines = self.requested_breakpoints.get(file_path) orelse continue;

            // Create breakpoint array for DAP event
            var breakpoints = try self.allocator.alloc(dap.Breakpoint, requested_lines.items.len);
            defer self.allocator.free(breakpoints);

            for (requested_lines.items, validated_lines.items, 0..) |requested, validated, i| {
                const bp_id = try self.getOrCreateBreakpointId(file_path, requested);
                breakpoints[i] = .{
                    .id = bp_id,
                    .verified = true,
                    .line = validated,
                    .source = .{ .path = file_path },
                };

                if (requested != validated) {
                    var msg_buf: [256]u8 = undefined;
                    std.debug.print("Breakpoint moved from line {} to {}\n", .{ requested, validated });
                    const msg = try std.fmt.bufPrint(&msg_buf, "Breakpoint moved from line {} to {}", .{ requested, validated });
                    breakpoints[i].message = try self.allocator.dupe(u8, msg);
                }
            }

            // Send breakpoint event with the correct structure
            // According to DAP spec, we need to send one event per breakpoint
            // Add a small delay between events to ensure VSCode processes them correctly
            for (breakpoints) |bp| {
                const body = .{
                    .reason = "changed",
                    .breakpoint = bp,
                };
                try self.dap_protocol.?.sendEvent("breakpoint", body);
            }
        }
    }
};
