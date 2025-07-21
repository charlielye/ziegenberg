const std = @import("std");
const ErrorContext = @import("brillig_vm.zig").ErrorContext;

/// Full source info for a PC (file path, line number, and source text)
pub const SourceInfo = struct {
    file_path: []const u8,
    line_number: u32,
    source_line: []const u8,
    column: u32,
};

/// Pre-parsed debug info for efficient PC lookup
pub const ParsedDebugInfo = struct {
    allocator: std.mem.Allocator,
    /// Map from PC to source location
    pc_to_location: std.AutoHashMap(usize, SourceInfo),

    pub fn init(allocator: std.mem.Allocator) ParsedDebugInfo {
        return .{
            .allocator = allocator,
            .pc_to_location = std.AutoHashMap(usize, SourceInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ParsedDebugInfo) void {
        var iter = self.pc_to_location.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.file_path);
            self.allocator.free(entry.value_ptr.source_line);
        }
        self.pc_to_location.deinit();
    }

    pub fn getLineForPC(self: *const ParsedDebugInfo, pc: usize) ?u32 {
        const entry = self.pc_to_location.get(pc) orelse return null;
        return entry.line_number;
    }

    pub fn getSourceInfoForPC(self: *const ParsedDebugInfo, pc: usize) ?SourceInfo {
        return self.pc_to_location.get(pc);
    }
};

/// Looks up source location for a given PC in a function (legacy interface)
pub fn lookupSourceLocation(
    allocator: std.mem.Allocator,
    artifact_path: []const u8,
    function_name: []const u8,
    pc: usize,
) !void {
    const source_info = try getSourceInfoForPC(allocator, artifact_path, function_name, pc) orelse {
        std.debug.print("  PC {} not found in debug symbols\n", .{pc});
        return;
    };
    defer allocator.free(source_info.file_path);
    defer allocator.free(source_info.source_line);

    // Print location
    std.debug.print("  {s}:{}:{}\n", .{ source_info.file_path, source_info.line_number, source_info.column });

    // Show source context (reuse the source_line we already have)
    const src = source_info.source_line;
    const line_num = source_info.line_number;
    const col_num = source_info.column;

    // Since we only have the current line, just show it with the indicator
    std.debug.print(">>> {}: {s}\n", .{ line_num, src });

    // Show column indicator
    if (col_num > 0) {
        std.debug.print("    ", .{});
        var i: usize = 0;
        const line_digits = std.fmt.count("{}", .{line_num});
        while (i < col_num + line_digits + 1) : (i += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("^\n", .{});
    }
}

/// Get source info for a PC using loaded artifact JSON
pub fn getSourceInfoForPC(
    allocator: std.mem.Allocator,
    artifact_path: []const u8,
    function_name: []const u8,
    pc: usize,
) !?SourceInfo {
    const file = try std.fs.cwd().openFile(artifact_path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    return try getSourceInfoFromParsedJson(allocator, &parsed.value, function_name, pc);
}

/// Get source info from already parsed JSON
pub fn getSourceInfoFromParsedJson(
    allocator: std.mem.Allocator,
    parsed_json: *const std.json.Value,
    function_name: []const u8,
    pc: usize,
) !?SourceInfo {
    const debug_b64 = try getDebugSymbolsForFunction(parsed_json, function_name) orelse return null;
    const root = parsed_json.object;

    // Decode and decompress
    const decoded = try decodeBase64(allocator, debug_b64);
    defer allocator.free(decoded);

    const decompressed = try decompressDeflate(allocator, decoded);
    defer allocator.free(decompressed);

    // Parse debug JSON
    var debug_parsed = try std.json.parseFromSlice(std.json.Value, allocator, decompressed, .{});
    defer debug_parsed.deinit();

    const debug_infos = debug_parsed.value.object.get("debug_infos") orelse return null;

    // Look up PC in all debug infos
    for (debug_infos.array.items) |info| {
        if (try extractSourceInfoForPC(allocator, info, pc, root)) |source_info| {
            return source_info;
        }
    }

    return null;
}

/// Parse debug info once for efficient repeated lookups
pub fn parseDebugInfo(
    allocator: std.mem.Allocator,
    parsed_json: *const std.json.Value,
    function_name: []const u8,
) !ParsedDebugInfo {
    var info = ParsedDebugInfo.init(allocator);
    errdefer info.deinit();

    const debug_b64 = try getDebugSymbolsForFunction(parsed_json, function_name) orelse return error.NoDebugSymbols;
    const root = parsed_json.object;

    // Decode and decompress
    const decoded = try decodeBase64(allocator, debug_b64);
    defer allocator.free(decoded);

    const decompressed = try decompressDeflate(allocator, decoded);
    defer allocator.free(decompressed);

    // Parse debug JSON
    var debug_parsed = try std.json.parseFromSlice(std.json.Value, allocator, decompressed, .{});
    defer debug_parsed.deinit();

    const debug_infos = debug_parsed.value.object.get("debug_infos") orelse return error.NoDebugInfos;

    // Parse all PC mappings from all debug infos
    for (debug_infos.array.items) |debug_info_item| {
        try parseAllPCMappings(&info, debug_info_item, root);
    }

    return info;
}

// Helper functions

fn getDebugSymbolsForFunction(parsed_json: *const std.json.Value, function_name: []const u8) !?[]const u8 {
    const root = parsed_json.object;

    if (root.get("functions")) |functions| {
        // Contract artifact - find the function
        for (functions.array.items) |func| {
            const func_obj = func.object;
            const name = func_obj.get("name") orelse continue;
            if (std.mem.eql(u8, name.string, function_name)) {
                const debug_sym = func_obj.get("debug_symbols") orelse return null;
                return debug_sym.string;
            }
        }
        return null;
    } else if (root.get("debug_symbols")) |debug_symbols| {
        // Program artifact - use top-level debug_symbols
        return debug_symbols.string;
    }
    return null;
}

fn decodeBase64(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_size = try decoder.calcSizeForSlice(b64);
    const decoded = try allocator.alloc(u8, decoded_size);
    try decoder.decode(decoded, b64);
    return decoded;
}

fn decompressDeflate(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var stream = std.io.fixedBufferStream(compressed);
    var decompressed = std.ArrayList(u8).init(allocator);
    try std.compress.flate.decompress(stream.reader(), decompressed.writer());
    return decompressed.toOwnedSlice();
}

fn extractSourceInfoForPC(
    allocator: std.mem.Allocator,
    debug_info: std.json.Value,
    pc: usize,
    root: std.json.ObjectMap,
) !?SourceInfo {
    const locations = debug_info.object.get("brillig_locations") orelse return null;
    const inner_locations = locations.object.get("0") orelse return null;

    var pc_key_buf: [32]u8 = undefined;
    const pc_key = try std.fmt.bufPrint(&pc_key_buf, "{}", .{pc});

    const location_idx_val = inner_locations.object.get(pc_key) orelse return null;
    const location_idx = location_idx_val.integer;

    const tree = debug_info.object.get("location_tree") orelse return null;
    const locations_array = tree.object.get("locations") orelse return null;
    const locs = locations_array.array.items;

    if (location_idx < 0 or location_idx >= locs.len) return null;

    return try extractSourceInfoFromLocation(allocator, locs[@intCast(location_idx)], root);
}

fn extractSourceInfoFromLocation(
    allocator: std.mem.Allocator,
    loc: std.json.Value,
    root: std.json.ObjectMap,
) !SourceInfo {
    const value = loc.object.get("value") orelse return error.InvalidLocation;
    const file_id = (value.object.get("file") orelse return error.NoFileId).integer;

    // Get character position from span
    var char_pos: usize = 0;
    if (value.object.get("span")) |span| {
        if (span.object.get("start")) |start| {
            char_pos = @intCast(start.integer);
        }
    }

    // Look up file info
    var file_key_buf: [32]u8 = undefined;
    const file_key = try std.fmt.bufPrint(&file_key_buf, "{}", .{file_id});

    const file_map = root.get("file_map") orelse return error.NoFileMap;
    const file_info = file_map.object.get(file_key) orelse return error.FileNotFound;
    const path = (file_info.object.get("path") orelse return error.NoPath).string;
    const source = (file_info.object.get("source") orelse return error.NoSource).string;

    // Calculate line and column from char position
    const line_info = findLineAndColumn(source, char_pos);

    return SourceInfo{
        .file_path = try allocator.dupe(u8, path),
        .line_number = @intCast(line_info.line),
        .source_line = try allocator.dupe(u8, source[line_info.line_start..line_info.line_end]),
        .column = @intCast(line_info.column),
    };
}

fn parseAllPCMappings(
    info: *ParsedDebugInfo,
    debug_info_item: std.json.Value,
    root: std.json.ObjectMap,
) !void {
    const locations = debug_info_item.object.get("brillig_locations") orelse return;
    const inner_locations = locations.object.get("0") orelse return;

    const tree = debug_info_item.object.get("location_tree") orelse return;
    const locations_array = tree.object.get("locations") orelse return;
    const locs = locations_array.array.items;

    // Iterate through all PC mappings
    var iter = inner_locations.object.iterator();
    while (iter.next()) |entry| {
        const pc = std.fmt.parseInt(usize, entry.key_ptr.*, 10) catch continue;
        const location_idx = entry.value_ptr.integer;

        if (location_idx < 0 or location_idx >= locs.len) continue;

        const source_info = extractSourceInfoFromLocation(info.allocator, locs[@intCast(location_idx)], root) catch continue;
        try info.pc_to_location.put(pc, source_info);
    }
}

const LineInfo = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

fn findLineAndColumn(source: []const u8, char_pos: usize) LineInfo {
    var line: usize = 1;
    var column: usize = 1;
    var line_start: usize = 0;
    var current_pos: usize = 0;

    for (source, 0..) |ch, i| {
        if (current_pos == char_pos) break;
        if (ch == '\n') {
            line += 1;
            column = 1;
            line_start = i + 1;
        } else {
            column += 1;
        }
        current_pos += 1;
    }

    // Find line end
    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

    return .{
        .line = line,
        .column = column,
        .line_start = line_start,
        .line_end = line_end,
    };
}

pub fn printBrilligTrapError(
    allocator: std.mem.Allocator,
    error_ctx: *const ErrorContext,
    function_name: []const u8,
    function_selector: u32,
    contract_artifact_path: ?[]const u8,
) void {
    std.debug.print("\n=== Brillig VM Trap ===\n", .{});
    std.debug.print("Function: {s} (selector: 0x{x})\n", .{ function_name, function_selector });
    std.debug.print("Brillig PC: {}\n", .{error_ctx.pc});
    std.debug.print("Operations executed: {}\n", .{error_ctx.ops_executed});
    std.debug.print("Return data: {x}\n", .{error_ctx.return_data});
    if (error_ctx.callstack.len > 0) {
        std.debug.print("Callstack: ", .{});
        for (error_ctx.callstack) |addr| {
            std.debug.print("{} ", .{addr});
        }
        std.debug.print("\n", .{});
    }

    // Try to look up source location
    if (contract_artifact_path) |artifact_path| {
        std.debug.print("\nSource location:\n", .{});
        lookupSourceLocation(allocator, artifact_path, function_name, error_ctx.pc) catch |lookup_err| {
            std.debug.print("  Could not resolve source location: {}\n", .{lookup_err});
        };
    }
    std.debug.print("======================\n\n", .{});
}
