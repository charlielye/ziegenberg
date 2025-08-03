const std = @import("std");
const DapClient = @import("dap_client.zig").DapClient;
const Linenoise = @import("linenoize").Linenoise;

pub const DebugCli = struct {
    allocator: std.mem.Allocator,
    client: DapClient,
    running: bool = true,
    linenoise: Linenoise,

    pub fn init(allocator: std.mem.Allocator, reader: std.fs.File.Reader, writer: std.fs.File.Writer) DebugCli {
        return .{
            .allocator = allocator,
            .client = DapClient.init(allocator, reader, writer),
            .linenoise = Linenoise.init(allocator),
        };
    }

    pub fn deinit(self: *DebugCli) void {
        self.linenoise.deinit();
        self.client.deinit();
    }

    pub fn run(self: *DebugCli) !void {
        // Initialize DAP connection
        try self.client.initialize();
        try self.client.launch();

        // Set up linenoize
        self.linenoise.completions_callback = completions;
        self.linenoise.hints_callback = hints;

        // Load history from home directory
        const history_path = blk: {
            if (std.process.getEnvVarOwned(self.allocator, "HOME")) |home| {
                defer self.allocator.free(home);
                break :blk std.fs.path.join(self.allocator, &.{ home, ".zb_debug_history" }) catch ".zb_debug_history";
            } else |_| {
                break :blk ".zb_debug_history";
            }
        };
        defer self.allocator.free(history_path);

        self.linenoise.history.load(history_path) catch {
            // Ignore error if history file doesn't exist
        };
        defer self.linenoise.history.save(history_path) catch {};

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
            const prompt = if (self.client.stopped) "(zb-debug) " else "(running) ";

            // Read command using linenoize
            const maybe_input = self.linenoise.linenoise(prompt) catch |err| {
                if (err == error.CtrlC) {
                    // Ctrl+C pressed - just continue with a new prompt
                    continue;
                }
                return err;
            };

            if (maybe_input) |input| {
                defer self.allocator.free(input);

                const cmd = std.mem.trim(u8, input, " \t\r\n");
                if (cmd.len == 0) continue;

                // Add to history
                try self.linenoise.history.add(cmd);

                // Process command
                try self.processCommand(cmd);
            } else {
                // EOF (Ctrl+D) - exit
                std.debug.print("\nEnd of input detected. Exiting debugger.\n", .{});
                self.running = false;
            }
        }

        // Cleanup
        std.debug.print("Terminating debug session...\n", .{});
        self.client.terminate() catch |err| {
            // Ignore errors during termination - the server might already be gone
            if (err != error.BrokenPipe and err != error.EndOfStream) {
                std.debug.print("Warning: Failed to terminate cleanly: {}\n", .{err});
            }
        };
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
            const file = (if (std.fs.path.isAbsolute(loc.file))
                std.fs.openFileAbsolute(loc.file, .{})
            else
                std.fs.cwd().openFile(loc.file, .{})) catch return;
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
        self.client.continue_() catch |err| {
            if (err == error.Terminated) {
                std.debug.print("Program terminated.\n", .{});
                self.running = false;
                return;
            }
            return err;
        };

        // Show location when we stop (due to breakpoint, exception, etc.)
        if (self.client.stopped) {
            self.showCurrentLocation();
        }
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

            // Skip memory writes
            if (std.mem.startsWith(u8, scope_name, "Memory Writes")) {
                continue;
            }

            std.debug.print("\n{s}:\n", .{scope_name});

            if (var_ref > 0) {
                const vars_response = try self.client.getVariables(var_ref);
                defer vars_response.deinit();

                const variables = vars_response.value.object.get("body").?.object.get("variables").?.array;

                for (variables.items) |variable| {
                    const name = variable.object.get("name").?.string;

                    const value = variable.object.get("value").?.string;
                    const var_type = if (variable.object.get("type")) |t| t.string else "";
                    const child_var_ref = if (variable.object.get("variablesReference")) |ref| @as(u32, @intCast(ref.integer)) else 0;

                    if (var_type.len > 0) {
                        std.debug.print("  {s}: {s} ({s})\n", .{ name, value, var_type });
                    } else {
                        std.debug.print("  {s}: {s}\n", .{ name, value });
                    }

                    // If this variable has children (like notes, nullifiers, etc.), expand them
                    if (child_var_ref > 0 and (std.mem.eql(u8, name, "notes") or
                        std.mem.eql(u8, name, "nullifiers") or
                        std.mem.eql(u8, name, "accounts") or
                        std.mem.eql(u8, name, "logs")))
                    {
                        try self.expandVariable(child_var_ref, 2);
                    }
                }
            }
        }
    }

    fn expandVariable(self: *DebugCli, var_ref: u32, indent_level: usize) !void {
        const vars_response = try self.client.getVariables(var_ref);
        defer vars_response.deinit();

        const variables = vars_response.value.object.get("body").?.object.get("variables").?.array;

        for (variables.items) |variable| {
            const name = variable.object.get("name").?.string;
            const value = variable.object.get("value").?.string;
            const child_ref = if (variable.object.get("variablesReference")) |ref| @as(u32, @intCast(ref.integer)) else 0;

            // Print with indentation
            var i: usize = 0;
            while (i < indent_level) : (i += 1) {
                std.debug.print("  ", .{});
            }
            std.debug.print("{s}: {s}\n", .{ name, value });

            // Recursively expand if it has children and is not too deep
            if (child_ref > 0 and indent_level < 4) {
                try self.expandVariable(child_ref, indent_level + 1);
            }
        }
    }
};

// Completion function for linenoize
fn completions(allocator: std.mem.Allocator, buf: []const u8) ![]const []const u8 {
    var result = std.ArrayList([]const u8).init(allocator);

    // List of all commands
    const commands = [_][]const u8{
        "help",      "h",
        "quit",      "q",
        "break",     "b",
        "delete",    "d",
        "continue",  "c",
        "next",      "n",
        "step",      "s",
        "out",       "o",
        "backtrace", "bt",
        "pause",     "p",
        "info",      "vars",
    };

    // Find matching commands
    for (commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, buf)) {
            try result.append(try allocator.dupe(u8, cmd));
        }
    }

    return result.toOwnedSlice();
}

// Hints function for linenoize
fn hints(allocator: std.mem.Allocator, buf: []const u8) !?[]const u8 {
    // Provide hints for incomplete commands
    const hint_map = .{
        .{ "b", " <file>:<line>" },
        .{ "break", " <file>:<line>" },
        .{ "d", " <file>" },
        .{ "delete", " <file>" },
        .{ "info", " breakpoints" },
        .{ "vars", " [frame_id]" },
    };

    // Split the input to get just the command
    var iter = std.mem.tokenizeAny(u8, buf, " \t");
    const cmd = iter.next() orelse return null;

    // Only show hints if there's no additional text after the command
    if (iter.rest().len > 0) return null;

    inline for (hint_map) |hint| {
        if (std.mem.eql(u8, cmd, hint[0])) {
            return try allocator.dupe(u8, hint[1]);
        }
    }

    return null;
}
