const std = @import("std");
const DapClient = @import("dap_client.zig").DapClient;

pub const DebugCli = struct {
    allocator: std.mem.Allocator,
    client: DapClient,
    running: bool = true,
    
    // Command history
    history: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator, reader: std.fs.File.Reader, writer: std.fs.File.Writer) DebugCli {
        return .{
            .allocator = allocator,
            .client = DapClient.init(allocator, reader, writer),
            .history = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *DebugCli) void {
        for (self.history.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.history.deinit();
        self.client.deinit();
    }
    
    pub fn run(self: *DebugCli) !void {
        // Initialize DAP connection
        try self.client.initialize();
        try self.client.launch();
        
        std.debug.print("ZB Debugger - Type 'help' for commands\n", .{});
        if (self.client.stopped) {
            std.debug.print("Program paused at entry. Set breakpoints and use 'continue' to run.\n", .{});
            self.showCurrentLocation();
            std.debug.print("\n", .{});
        }
        
        // Main command loop
        while (self.running) {
            // Ensure we have a valid state before showing prompt
            if (!self.client.initialized) {
                std.debug.print("Waiting for initialization...\n", .{});
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            }
            
            // Show prompt based on state
            if (self.client.stopped) {
                std.debug.print("(zb-debug) ", .{});
            } else {
                std.debug.print("(running) ", .{});
            }
            
            // Read command from stdin
            const stdin = std.io.getStdIn().reader();
            var buf: [1024]u8 = undefined;
            if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
                const cmd = std.mem.trim(u8, line, " \t\r\n");
                if (cmd.len == 0) continue;
                
                // Add to history
                const cmd_copy = try self.allocator.dupe(u8, cmd);
                try self.history.append(cmd_copy);
                
                // Process command
                try self.processCommand(cmd);
            } else {
                // EOF - exit
                self.running = false;
            }
        }
        
        // Cleanup
        try self.client.terminate();
    }
    
    fn processCommand(self: *DebugCli, cmd: []const u8) !void {
        var iter = std.mem.tokenizeAny(u8, cmd, " \t");
        const command = iter.next() orelse return;
        
        // Check if we're initialized before executing most commands
        if (!self.client.initialized and !std.mem.eql(u8, command, "quit") and !std.mem.eql(u8, command, "q") and !std.mem.eql(u8, command, "help") and !std.mem.eql(u8, command, "h")) {
            std.debug.print("Debugger not yet initialized. Please wait...\n", .{});
            return;
        }
        
        // Parse commands
        if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "h")) {
            self.printHelp();
        } else if (std.mem.eql(u8, command, "quit") or std.mem.eql(u8, command, "q")) {
            self.running = false;
        } else if (std.mem.eql(u8, command, "break") or std.mem.eql(u8, command, "b")) {
            try self.handleBreakpoint(iter.rest());
        } else if (std.mem.eql(u8, command, "delete") or std.mem.eql(u8, command, "d")) {
            try self.handleDeleteBreakpoint(iter.rest());
        } else if (std.mem.eql(u8, command, "continue") or std.mem.eql(u8, command, "c")) {
            try self.handleContinue();
        } else if (std.mem.eql(u8, command, "next") or std.mem.eql(u8, command, "n")) {
            try self.handleNext();
        } else if (std.mem.eql(u8, command, "step") or std.mem.eql(u8, command, "s")) {
            try self.handleStep();
        } else if (std.mem.eql(u8, command, "out") or std.mem.eql(u8, command, "o")) {
            try self.handleOut();
        } else if (std.mem.eql(u8, command, "backtrace") or std.mem.eql(u8, command, "bt")) {
            try self.handleBacktrace();
        } else if (std.mem.eql(u8, command, "pause") or std.mem.eql(u8, command, "p")) {
            try self.handlePause();
        } else if (std.mem.eql(u8, command, "info")) {
            try self.handleInfo(iter.rest());
        } else if (std.mem.eql(u8, command, "vars")) {
            try self.handleVariables(iter.rest());
        } else {
            std.debug.print("Unknown command: {s}. Type 'help' for available commands.\n", .{command});
        }
    }
    
    fn showCurrentLocation(self: *DebugCli) void {
        const location = self.client.getCurrentLocation() catch {
            return;
        };
        
        if (location) |loc| {
            // Extract just the filename from the path
            const filename = std.fs.path.basename(loc.file);
            std.debug.print("Stopped at {s}:{} in {s}\n", .{ filename, loc.line, loc.name });
            
            // Read and display the actual source line
            const file = std.fs.openFileAbsolute(loc.file, .{}) catch {
                return;
            };
            defer file.close();
            
            // Read the file line by line to get to the target line
            var buf_reader = std.io.bufferedReader(file.reader());
            var line_num: u32 = 1;
            var buf: [1024]u8 = undefined;
            
            while (buf_reader.reader().readUntilDelimiterOrEof(&buf, '\n') catch null) |line| {
                if (line_num == loc.line) {
                    // Print the source line with some formatting
                    std.debug.print("  > {s}\n", .{line});
                    break;
                }
                line_num += 1;
            }
        }
    }
    
    fn printHelp(self: *DebugCli) void {
        _ = self;
        std.debug.print(
            \\Available commands:
            \\  help (h)              - Show this help
            \\  quit (q)              - Exit debugger
            \\  
            \\Breakpoints:
            \\  break <file>:<line>   - Set breakpoint at file:line
            \\  b <file>:<line>       - Short form
            \\  delete <file>         - Remove all breakpoints from file
            \\  d <file>              - Short form
            \\  
            \\Execution:
            \\  continue (c)          - Continue execution
            \\  next (n)              - Step over (next line)
            \\  step (s)              - Step into function
            \\  out (o)               - Step out of function
            \\  pause (p)             - Pause execution
            \\  
            \\Information:
            \\  backtrace (bt)        - Show call stack
            \\  info breakpoints      - List all breakpoints
            \\  vars [frame_id]       - Show variables in current or specified frame
            \\
        , .{});
    }
    
    fn handleBreakpoint(self: *DebugCli, args: []const u8) !void {
        // Parse file:line
        var parts = std.mem.splitScalar(u8, args, ':');
        const file = parts.next() orelse {
            std.debug.print("Usage: break <file>:<line>\n", .{});
            return;
        };
        const line_str = parts.next() orelse {
            std.debug.print("Usage: break <file>:<line>\n", .{});
            return;
        };
        
        const line = std.fmt.parseInt(u32, line_str, 10) catch {
            std.debug.print("Invalid line number: {s}\n", .{line_str});
            return;
        };
        
        try self.client.setBreakpoint(file, line);
        std.debug.print("Breakpoint set at {s}:{}\n", .{ file, line });
    }
    
    fn handleDeleteBreakpoint(self: *DebugCli, args: []const u8) !void {
        const file = std.mem.trim(u8, args, " \t");
        if (file.len == 0) {
            std.debug.print("Usage: delete <file>\n", .{});
            return;
        }
        
        try self.client.removeBreakpoint(file);
        std.debug.print("Breakpoints removed from {s}\n", .{file});
    }
    
    fn handleContinue(self: *DebugCli) !void {
        if (!self.client.stopped) {
            std.debug.print("Program is already running\n", .{});
            return;
        }
        
        std.debug.print("Continuing...\n", .{});
        try self.client.continue_();
    }
    
    fn handleNext(self: *DebugCli) !void {
        if (!self.client.stopped) {
            std.debug.print("Program is running. Use 'pause' first.\n", .{});
            return;
        }
        
        try self.client.stepOver();
        self.showCurrentLocation();
    }
    
    fn handleStep(self: *DebugCli) !void {
        if (!self.client.stopped) {
            std.debug.print("Program is running. Use 'pause' first.\n", .{});
            return;
        }
        
        try self.client.stepInto();
        self.showCurrentLocation();
    }
    
    fn handleOut(self: *DebugCli) !void {
        if (!self.client.stopped) {
            std.debug.print("Program is running. Use 'pause' first.\n", .{});
            return;
        }
        
        try self.client.stepOut();
        self.showCurrentLocation();
    }
    
    fn handlePause(self: *DebugCli) !void {
        if (self.client.stopped) {
            std.debug.print("Program is already paused\n", .{});
            return;
        }
        
        std.debug.print("Pausing...\n", .{});
        try self.client.pause();
        self.showCurrentLocation();
    }
    
    fn handleBacktrace(self: *DebugCli) !void {
        if (!self.client.stopped) {
            std.debug.print("Program is running. Use 'pause' first.\n", .{});
            return;
        }
        
        const response = self.client.getStackTrace() catch |err| {
            if (err == error.NoActiveThread) {
                std.debug.print("No active thread. Program may not be initialized yet.\n", .{});
                return;
            }
            return err;
        };
        defer response.deinit();
        
        const body = response.value.object.get("body").?;
        const frames = body.object.get("stackFrames").?.array;
        
        std.debug.print("Call stack:\n", .{});
        for (frames.items, 0..) |frame, i| {
            const name = frame.object.get("name").?.string;
            const source = frame.object.get("source");
            const line = frame.object.get("line");
            
            std.debug.print("#{} {s}", .{ i, name });
            
            if (source) |src| {
                // Check if source is not null
                if (src == .object) {
                    if (src.object.get("path")) |path| {
                        std.debug.print(" at {s}", .{path.string});
                        if (line) |l| {
                            std.debug.print(":{}", .{l.integer});
                        }
                    }
                }
            }
            std.debug.print("\n", .{});
        }
    }
    
    fn handleInfo(self: *DebugCli, args: []const u8) !void {
        _ = self;
        var iter = std.mem.tokenizeAny(u8, args, " \t");
        const what = iter.next() orelse {
            std.debug.print("Usage: info <what>\n", .{});
            return;
        };
        
        if (std.mem.eql(u8, what, "breakpoints")) {
            std.debug.print("Breakpoint information not yet implemented\n", .{});
            // TODO: Track breakpoints locally
        } else {
            std.debug.print("Unknown info command: {s}\n", .{what});
        }
    }
    
    fn handleVariables(self: *DebugCli, args: []const u8) !void {
        _ = args;
        
        if (!self.client.stopped) {
            std.debug.print("Program is running. Use 'pause' first.\n", .{});
            return;
        }
        
        // Get current frame
        const stack_response = try self.client.getStackTrace();
        defer stack_response.deinit();
        
        const frames = stack_response.value.object.get("body").?.object.get("stackFrames").?.array;
        if (frames.items.len == 0) {
            std.debug.print("No stack frames available\n", .{});
            return;
        }
        
        const frame_id = @as(u32, @intCast(frames.items[0].object.get("id").?.integer));
        
        // Get scopes
        const scopes_response = try self.client.getScopes(frame_id);
        defer scopes_response.deinit();
        
        const scopes = scopes_response.value.object.get("body").?.object.get("scopes").?.array;
        
        // Get variables for each scope
        for (scopes.items) |scope| {
            const scope_name = scope.object.get("name").?.string;
            const var_ref = @as(u32, @intCast(scope.object.get("variablesReference").?.integer));
            
            std.debug.print("\n{s}:\n", .{scope_name});
            
            if (var_ref > 0) {
                const vars_response = try self.client.getVariables(var_ref);
                defer vars_response.deinit();
                
                const variables = vars_response.value.object.get("body").?.object.get("variables").?.array;
                
                for (variables.items) |variable| {
                    const name = variable.object.get("name").?.string;
                    const value = variable.object.get("value").?.string;
                    const var_type = if (variable.object.get("type")) |t| t.string else "";
                    
                    if (var_type.len > 0) {
                        std.debug.print("  {s}: {s} ({s})\n", .{ name, value, var_type });
                    } else {
                        std.debug.print("  {s}: {s}\n", .{ name, value });
                    }
                }
            }
        }
    }
};