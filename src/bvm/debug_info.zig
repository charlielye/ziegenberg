const std = @import("std");

/// Source location information
pub const SourceLocation = struct {
    file_id: u32,
    file_path: []const u8,
    source_line: []const u8,
    line_number: u32,
};

/// Looks up source location for a given PC in a function
pub fn lookupSourceLocation(
    allocator: std.mem.Allocator,
    artifact_path: []const u8,
    function_name: []const u8,
    pc: usize,
) !void {
    const file = try std.fs.cwd().openFile(artifact_path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    
    // Check if this is a contract artifact (has "functions") or a program artifact (has "debug_symbols")
    if (root.get("functions")) |functions| {
        // Contract artifact - use the existing logic
        return lookupInContractArtifact(allocator, functions, function_name, pc, root);
    } else if (root.get("debug_symbols")) |debug_symbols| {
        // Program artifact - look up directly in debug_symbols
        return lookupInProgramArtifact(allocator, debug_symbols, pc, root);
    } else {
        std.debug.print("  Unknown artifact format\n", .{});
        return;
    }
}

fn lookupInContractArtifact(
    allocator: std.mem.Allocator,
    functions: std.json.Value,
    function_name: []const u8,
    pc: usize,
    root: std.json.ObjectMap,
) !void {

    // Find the function
    for (functions.array.items) |func| {
        const func_obj = func.object;
        const name = func_obj.get("name") orelse continue;

        if (!std.mem.eql(u8, name.string, function_name)) continue;

        const debug_sym = func_obj.get("debug_symbols") orelse {
            std.debug.print("  No debug symbols available for function {s}\n", .{function_name});
            return;
        };

        // Decode and decompress debug symbols
        const debug_b64 = debug_sym.string;
        const decoder = std.base64.standard.Decoder;
        const decoded_size = try decoder.calcSizeForSlice(debug_b64);
        const decoded = try allocator.alloc(u8, decoded_size);
        defer allocator.free(decoded);

        try decoder.decode(decoded, debug_b64);

        // Decompress (raw deflate)
        var stream = std.io.fixedBufferStream(decoded);
        var decompressed = std.ArrayList(u8).init(allocator);
        defer decompressed.deinit();
        try std.compress.flate.decompress(stream.reader(), decompressed.writer());

        // Parse debug JSON
        var debug_parsed = try std.json.parseFromSlice(std.json.Value, allocator, decompressed.items, .{});
        defer debug_parsed.deinit();

        const debug_infos = debug_parsed.value.object.get("debug_infos") orelse return;

        // Look up PC in debug info
        for (debug_infos.array.items) |info| {
            if (try lookupPcInDebugInfo(allocator, info, pc, root)) return;
        }

        std.debug.print("  PC {} not found in debug symbols\n", .{pc});
        return;
    }

    std.debug.print("  Function {s} not found\n", .{function_name});
}

fn lookupInProgramArtifact(
    allocator: std.mem.Allocator,
    debug_symbols: std.json.Value,
    pc: usize,
    root: std.json.ObjectMap,
) !void {
    // Program artifacts have debug_symbols as a base64 encoded string
    const debug_b64 = debug_symbols.string;
    const decoder = std.base64.standard.Decoder;
    const decoded_size = try decoder.calcSizeForSlice(debug_b64);
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);
    
    try decoder.decode(decoded, debug_b64);
    
    // Decompress (raw deflate)
    var stream = std.io.fixedBufferStream(decoded);
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();
    try std.compress.flate.decompress(stream.reader(), decompressed.writer());
    
    // Parse debug JSON
    var debug_parsed = try std.json.parseFromSlice(std.json.Value, allocator, decompressed.items, .{});
    defer debug_parsed.deinit();
    
    // Program artifacts have the same structure as contract artifacts
    const debug_infos = debug_parsed.value.object.get("debug_infos") orelse return;

    // Look up PC in debug info
    for (debug_infos.array.items) |info| {
        if (try lookupPcInDebugInfo(allocator, info, pc, root)) return;
    }

    std.debug.print("  PC {} not found in debug symbols\n", .{pc});
}

fn lookupPcInDebugInfo(
    _: std.mem.Allocator,
    info: std.json.Value,
    pc: usize,
    root: std.json.ObjectMap,
) !bool {
    const locations = info.object.get("brillig_locations") orelse return false;
    const inner_locations = locations.object.get("0") orelse return false;

    var pc_key_buf: [32]u8 = undefined;
    const pc_key = try std.fmt.bufPrint(&pc_key_buf, "{}", .{pc});

    const location_idx_val = inner_locations.object.get(pc_key) orelse return false;
    const location_idx = location_idx_val.integer;

    const tree = info.object.get("location_tree") orelse return false;
    const locations_array = tree.object.get("locations") orelse return false;
    const locs = locations_array.array.items;

    if (location_idx < 0 or location_idx >= locs.len) return false;

    const loc = locs[@intCast(location_idx)];
    const value = loc.object.get("value") orelse return false;
    const file_id_val = value.object.get("file") orelse return false;
    const file_id = file_id_val.integer;

    // Get span for line calculation
    var char_pos: usize = 0;
    if (value.object.get("span")) |span| {
        if (span.object.get("start")) |start| {
            char_pos = @intCast(start.integer);
        }
    }

    // Look up file
    const file_map = root.get("file_map") orelse return false;
    var file_key_buf: [32]u8 = undefined;
    const file_key = try std.fmt.bufPrint(&file_key_buf, "{}", .{file_id});

    const file_info = file_map.object.get(file_key) orelse return false;
    const path = file_info.object.get("path") orelse return false;
    const source = file_info.object.get("source") orelse return false;

    // Find line and column from character position
    const src = source.string;
    var line_num: usize = 1;
    var col_num: usize = 1;
    var current_pos: usize = 0;

    for (src) |ch| {
        if (current_pos == char_pos) break;
        if (ch == '\n') {
            line_num += 1;
            col_num = 1;
        } else {
            col_num += 1;
        }
        current_pos += 1;
    }

    std.debug.print("  {s}:{}:{}\n", .{ path.string, line_num, col_num });

    // Show source context
    var lines = std.mem.splitScalar(u8, src, '\n');
    var current_line: usize = 1;
    while (lines.next()) |line| : (current_line += 1) {
        if (current_line >= line_num -| 2 and current_line <= line_num + 2) {
            const prefix = if (current_line == line_num) ">>> " else "    ";
            std.debug.print("{s}{}: {s}\n", .{ prefix, current_line, line });
        }
    }

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

    return true;
}

pub const ErrorContext = struct {
    pc: usize,
    callstack: []const usize,
    ops_executed: u64,
    return_data: []const u256,
};

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
