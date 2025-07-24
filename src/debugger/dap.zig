const std = @import("std");

/// Debug Adapter Protocol implementation for VSCode debugging
pub const DapProtocol = struct {
    allocator: std.mem.Allocator,
    reader: std.io.BufferedReader(4096, std.fs.File.Reader),
    writer: std.io.BufferedWriter(4096, std.fs.File.Writer),
    seq_counter: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) DapProtocol {
        return .{
            .allocator = allocator,
            .reader = std.io.bufferedReader(std.io.getStdIn().reader()),
            .writer = std.io.bufferedWriter(std.io.getStdOut().writer()),
        };
    }

    pub fn deinit(self: *DapProtocol) void {
        self.writer.flush() catch {};
    }

    /// Read a DAP message from stdin
    pub fn readMessage(self: *DapProtocol, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        // Read Content-Length header
        var buf: [256]u8 = undefined;
        const header_line = try self.reader.reader().readUntilDelimiterOrEof(&buf, '\n') orelse return error.EndOfStream;
        
        // Parse Content-Length
        if (!std.mem.startsWith(u8, header_line, "Content-Length: ")) {
            return error.InvalidHeader;
        }
        const len_str = std.mem.trim(u8, header_line["Content-Length: ".len..], "\r\n ");
        const content_length = try std.fmt.parseInt(usize, len_str, 10);

        // Read empty line after headers
        _ = try self.reader.reader().readUntilDelimiterOrEof(&buf, '\n');

        // Read JSON body
        const json_body = try allocator.alloc(u8, content_length);
        defer allocator.free(json_body);
        _ = try self.reader.reader().readAll(json_body);

        return try std.json.parseFromSlice(std.json.Value, allocator, json_body, .{});
    }

    pub fn readMessageNonBlocking(self: *DapProtocol, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        // Check if data is available using poll
        var pfd = [_]std.posix.pollfd{.{
            .fd = std.io.getStdIn().handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        
        const ready = try std.posix.poll(&pfd, 0); // 0 timeout = non-blocking
        if (ready == 0) {
            return error.WouldBlock;
        }

        // Data is available, read it
        return self.readMessage(allocator);
    }

    /// Send a response to a request
    pub fn sendResponse(self: *DapProtocol, request_seq: u32, command: []const u8, success: bool, body: anytype) !void {
        const response = .{
            .seq = self.getNextSeq(),
            .type = "response",
            .request_seq = request_seq,
            .success = success,
            .command = command,
            .body = body,
        };
        try self.sendMessage(response);
    }

    /// Send an event
    pub fn sendEvent(self: *DapProtocol, event: []const u8, body: anytype) !void {
        const event_msg = .{
            .seq = self.getNextSeq(),
            .type = "event",
            .event = event,
            .body = body,
        };
        try self.sendMessage(event_msg);
    }

    fn sendMessage(self: *DapProtocol, message: anytype) !void {
        // Serialize to JSON
        var json_buf = std.ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();
        try std.json.stringify(message, .{}, json_buf.writer());

        // Write headers and body
        const writer = self.writer.writer();
        try writer.print("Content-Length: {}\r\n\r\n", .{json_buf.items.len});
        try writer.writeAll(json_buf.items);
        try self.writer.flush();
    }

    fn getNextSeq(self: *DapProtocol) u32 {
        const seq = self.seq_counter;
        self.seq_counter += 1;
        return seq;
    }
};

// DAP protocol structures

// Common DAP structures
pub const Source = struct {
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const StackFrame = struct {
    id: u32,
    name: []const u8,
    source: ?Source = null,
    line: u32,
    column: u32,
};

pub const Thread = struct {
    id: u32,
    name: []const u8,
};

pub const StoppedEventBody = struct {
    reason: []const u8,
    threadId: u32 = 1,
    allThreadsStopped: bool = true,
};

pub const InitializeRequestArguments = struct {
    clientID: ?[]const u8 = null,
    clientName: ?[]const u8 = null,
    adapterID: []const u8,
    locale: ?[]const u8 = null,
    linesStartAt1: bool = true,
    columnsStartAt1: bool = true,
    pathFormat: ?[]const u8 = null,
    supportsVariableType: bool = false,
    supportsVariablePaging: bool = false,
    supportsRunInTerminalRequest: bool = false,
    supportsMemoryReferences: bool = false,
    supportsProgressReporting: bool = false,
    supportsInvalidatedEvent: bool = false,
};

pub const Capabilities = struct {
    supportsConfigurationDoneRequest: bool = true,
    supportsFunctionBreakpoints: bool = false,
    supportsConditionalBreakpoints: bool = false,
    supportsHitConditionalBreakpoints: bool = false,
    supportsEvaluateForHovers: bool = false,
    supportsStepBack: bool = false,
    supportsSetVariable: bool = false,
    supportsRestartFrame: bool = false,
    supportsGotoTargetsRequest: bool = false,
    supportsStepInTargetsRequest: bool = false,
    supportsCompletionsRequest: bool = false,
    supportsModulesRequest: bool = false,
    supportsDelayedStackTraceLoading: bool = false,
    supportsTerminateRequest: bool = true,
    supportsPauseRequest: bool = true,
};

pub const SourceBreakpoint = struct {
    line: u32,
    column: ?u32 = null,
    condition: ?[]const u8 = null,
    hitCondition: ?[]const u8 = null,
    logMessage: ?[]const u8 = null,
};

pub const Breakpoint = struct {
    id: ?u32 = null,
    verified: bool,
    message: ?[]const u8 = null,
    source: ?Source = null,
    line: ?u32 = null,
    column: ?u32 = null,
    endLine: ?u32 = null,
    endColumn: ?u32 = null,
};