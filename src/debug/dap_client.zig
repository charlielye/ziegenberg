const std = @import("std");
const dap = @import("dap.zig");

pub const DapClient = struct {
    allocator: std.mem.Allocator,
    reader: std.io.BufferedReader(4096, std.fs.File.Reader),
    writer: std.io.BufferedWriter(4096, std.fs.File.Writer),
    seq_counter: u32 = 1,
    initialized: bool = false,
    capabilities: ?Capabilities = null,
    
    // Track current state
    stopped: bool = false,
    current_thread: ?u32 = null,
    
    pub const Capabilities = struct {
        supportsConfigurationDoneRequest: bool = false,
        supportsFunctionBreakpoints: bool = false,
        supportsConditionalBreakpoints: bool = false,
        supportsEvaluateForHovers: bool = false,
        supportsStepBack: bool = false,
        supportsSetVariable: bool = false,
        supportsRestartFrame: bool = false,
        supportsStepInTargetsRequest: bool = false,
        supportsDelayedStackTraceLoading: bool = false,
        supportsLoadedSourcesRequest: bool = false,
        supportsTerminateRequest: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, reader: std.fs.File.Reader, writer: std.fs.File.Writer) DapClient {
        return .{
            .allocator = allocator,
            .reader = std.io.bufferedReader(reader),
            .writer = std.io.bufferedWriter(writer),
        };
    }

    pub fn deinit(self: *DapClient) void {
        self.writer.flush() catch {};
    }

    fn getNextSeq(self: *DapClient) u32 {
        const seq = self.seq_counter;
        self.seq_counter += 1;
        return seq;
    }

    fn sendRequest(self: *DapClient, command: []const u8, arguments: anytype) !u32 {
        const seq = self.getNextSeq();
        const request = .{
            .seq = seq,
            .type = "request",
            .command = command,
            .arguments = arguments,
        };
        
        // Serialize to JSON
        var json_buf = std.ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();
        try std.json.stringify(request, .{}, json_buf.writer());

        // Write headers and body
        const writer = self.writer.writer();
        try writer.print("Content-Length: {}\r\n\r\n", .{json_buf.items.len});
        try writer.writeAll(json_buf.items);
        try self.writer.flush();
        
        return seq;
    }

    pub fn readResponse(self: *DapClient) !std.json.Parsed(std.json.Value) {
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
        const json_body = try self.allocator.alloc(u8, content_length);
        defer self.allocator.free(json_body);
        _ = try self.reader.reader().readAll(json_body);

        return try std.json.parseFromSlice(std.json.Value, self.allocator, json_body, .{});
    }

    pub fn initialize(self: *DapClient) !void {
        _ = try self.sendRequest("initialize", .{
            .clientID = "zb-debug",
            .clientName = "ZB Debug Client",
            .adapterID = "zb",
            .locale = "en-US",
            .linesStartAt1 = true,
            .columnsStartAt1 = true,
            .pathFormat = "path",
            .supportsVariableType = true,
            .supportsVariablePaging = false,
            .supportsRunInTerminalRequest = false,
            .supportsMemoryReferences = false,
            .supportsProgressReporting = false,
            .supportsInvalidatedEvent = false,
        });
        
        // Wait for initialize response
        while (true) {
            const response = try self.readResponse();
            defer response.deinit();
            
            const msg_type = response.value.object.get("type").?.string;
            if (std.mem.eql(u8, msg_type, "response")) {
                const command = response.value.object.get("command").?.string;
                if (std.mem.eql(u8, command, "initialize")) {
                    if (response.value.object.get("success").?.bool) {
                        // Store capabilities
                        if (response.value.object.get("body")) |body| {
                            // TODO: Parse capabilities properly
                            _ = body;
                        }
                        self.initialized = true;
                        break;
                    } else {
                        return error.InitializeFailed;
                    }
                }
            }
        }
        
        // Wait for initialized event
        while (true) {
            const response = try self.readResponse();
            defer response.deinit();
            
            const msg_type = response.value.object.get("type").?.string;
            if (std.mem.eql(u8, msg_type, "event")) {
                const event = response.value.object.get("event").?.string;
                if (std.mem.eql(u8, event, "initialized")) {
                    break;
                }
            }
        }
    }

    fn handleStoppedEvent(self: *DapClient, body: std.json.Value) void {
        self.stopped = true;
        if (body.object.get("threadId")) |thread| {
            self.current_thread = @intCast(thread.integer);
        }
    }
    
    pub fn getCurrentLocation(self: *DapClient) !?struct { file: []const u8, line: u32, name: []const u8 } {
        if (!self.stopped or self.current_thread == null) return null;
        
        // Get stack trace to find current location
        const response = try self.getStackTrace();
        defer response.deinit();
        
        const body = response.value.object.get("body").?;
        const frames = body.object.get("stackFrames").?.array;
        
        if (frames.items.len == 0) return null;
        
        // Get the top frame
        const frame = frames.items[0];
        const name = frame.object.get("name").?.string;
        const source = frame.object.get("source");
        const line = frame.object.get("line");
        
        if (source) |src| {
            if (src == .object) {
                if (src.object.get("path")) |path| {
                    if (line) |l| {
                        return .{
                            .file = path.string,
                            .line = @intCast(l.integer),
                            .name = name,
                        };
                    }
                }
            }
        }
        
        return null;
    }

    pub fn launch(self: *DapClient) !void {
        _ = try self.sendRequest("launch", .{
            .noDebug = false,
            .stopOnEntry = true,
        });
        
        // Wait for launch response
        while (true) {
            const response = try self.readResponse();
            defer response.deinit();
            
            const msg_type = response.value.object.get("type").?.string;
            if (std.mem.eql(u8, msg_type, "response")) {
                const command = response.value.object.get("command").?.string;
                if (std.mem.eql(u8, command, "launch")) {
                    const success = response.value.object.get("success").?.bool;
                    if (!success) {
                        return error.LaunchFailed;
                    }
                    break;
                }
            }
        }
        
        // Send configurationDone
        _ = try self.sendRequest("configurationDone", .{});
        
        // Wait for configurationDone response and stopped event
        var got_response = false;
        while (true) {
            const response = try self.readResponse();
            defer response.deinit();
            
            const msg_type = response.value.object.get("type").?.string;
            if (std.mem.eql(u8, msg_type, "response")) {
                const command = response.value.object.get("command").?.string;
                if (std.mem.eql(u8, command, "configurationDone")) {
                    got_response = true;
                }
            } else if (std.mem.eql(u8, msg_type, "event")) {
                const event = response.value.object.get("event").?.string;
                if (std.mem.eql(u8, event, "stopped")) {
                    self.handleStoppedEvent(response.value.object.get("body").?);
                    if (got_response) break;
                }
            }
            
            // If we got the response and a stopped event, we're done
            if (got_response and self.stopped) break;
        }
    }

    pub fn setBreakpoint(self: *DapClient, file_path: []const u8, line: u32) !void {
        _ = try self.sendRequest("setBreakpoints", .{
            .source = .{
                .path = file_path,
            },
            .breakpoints = &[_]struct { line: u32 }{
                .{ .line = line },
            },
        });
        
        // Wait for response
        const response = try self.readResponse();
        defer response.deinit();
        
        // TODO: Return breakpoint info
    }

    pub fn removeBreakpoint(self: *DapClient, file_path: []const u8) !void {
        _ = try self.sendRequest("setBreakpoints", .{
            .source = .{
                .path = file_path,
            },
            .breakpoints = &[_]struct { line: u32 }{},
        });
        
        // Wait for response
        const response = try self.readResponse();
        defer response.deinit();
    }

    pub fn getStackTrace(self: *DapClient) !std.json.Parsed(std.json.Value) {
        const thread_id = self.current_thread orelse return error.NoActiveThread;
        
        _ = try self.sendRequest("stackTrace", .{
            .threadId = thread_id,
            .startFrame = 0,
            .levels = 20,
        });
        
        // Wait for response
        return try self.readResponse();
    }

    pub fn stepOver(self: *DapClient) !void {
        const thread_id = self.current_thread orelse return error.NoActiveThread;
        
        _ = try self.sendRequest("next", .{
            .threadId = thread_id,
        });
        
        self.stopped = false;
        try self.waitForStop();
    }

    pub fn stepInto(self: *DapClient) !void {
        const thread_id = self.current_thread orelse return error.NoActiveThread;
        
        _ = try self.sendRequest("stepIn", .{
            .threadId = thread_id,
        });
        
        self.stopped = false;
        try self.waitForStop();
    }

    pub fn stepOut(self: *DapClient) !void {
        const thread_id = self.current_thread orelse return error.NoActiveThread;
        
        _ = try self.sendRequest("stepOut", .{
            .threadId = thread_id,
        });
        
        self.stopped = false;
        try self.waitForStop();
    }

    pub fn continue_(self: *DapClient) !void {
        const thread_id = self.current_thread orelse return error.NoActiveThread;
        
        _ = try self.sendRequest("continue", .{
            .threadId = thread_id,
        });
        
        self.stopped = false;
        try self.waitForStop();
    }

    pub fn pause(self: *DapClient) !void {
        const thread_id = self.current_thread orelse 1;
        
        _ = try self.sendRequest("pause", .{
            .threadId = thread_id,
        });
        
        try self.waitForStop();
    }

    pub fn terminate(self: *DapClient) !void {
        _ = try self.sendRequest("terminate", .{});
        
        // Wait for response
        const response = try self.readResponse();
        defer response.deinit();
    }

    fn waitForStop(self: *DapClient) !void {
        while (!self.stopped) {
            const msg = try self.readResponse();
            defer msg.deinit();
            
            const msg_type = msg.value.object.get("type").?.string;
            if (std.mem.eql(u8, msg_type, "event")) {
                const event = msg.value.object.get("event").?.string;
                if (std.mem.eql(u8, event, "stopped")) {
                    self.handleStoppedEvent(msg.value.object.get("body").?);
                } else if (std.mem.eql(u8, event, "terminated")) {
                    self.stopped = true;
                    self.current_thread = null;
                    return error.Terminated;
                }
            }
        }
    }

    pub fn getScopes(self: *DapClient, frame_id: u32) !std.json.Parsed(std.json.Value) {
        _ = try self.sendRequest("scopes", .{
            .frameId = frame_id,
        });
        
        return try self.readResponse();
    }

    pub fn getVariables(self: *DapClient, variables_reference: u32) !std.json.Parsed(std.json.Value) {
        _ = try self.sendRequest("variables", .{
            .variablesReference = variables_reference,
        });
        
        return try self.readResponse();
    }
};