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

    pub fn init(allocator: std.mem.Allocator, mode: DebugMode) !DebugContext {
        var ctx = DebugContext{
            .allocator = allocator,
            .mode = mode,
            .vm_info_stack = std.ArrayList(VmInfo).init(allocator),
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
        self.vm_info_stack.deinit();
    }

    pub fn onVmEnter(self: *DebugContext, debug_info: *const nargo_debug_info.DebugInfo) void {
        // When entering a new Brillig VM, push it onto the stack
        self.vm_info_stack.append(.{
            .pc = 0,
            .callstack = &.{},
            .debug_info = debug_info,
        }) catch unreachable;
    }

    pub fn onVmExit(self: *DebugContext) void {
        const current_vm = self.vm_info_stack.pop().?;

        // If we were stepping out of this VM and there's a parent VM
        if (current_vm.stepping_out and self.vm_info_stack.items.len > 0) {
            // Mark that we should pause when the parent VM resumes
            self.execution_state = .paused;
            self.step_out_target_depth = null;
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
        std.debug.print("{any}\n", .{vm.callstack.items});
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
                // For now, just acknowledge but don't actually set breakpoints
                const breakpoints = .{ .breakpoints = &[_]struct {}{} };
                try protocol.sendResponse(cmd_seq, cmd, true, breakpoints);
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
                    // TODO: Check for breakpoints
                    // For now, just continue
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
            // For now, just acknowledge but don't actually set breakpoints
            const breakpoints = .{ .breakpoints = &[_]struct {}{} };
            try protocol.sendResponse(seq, command, true, breakpoints);
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
};
