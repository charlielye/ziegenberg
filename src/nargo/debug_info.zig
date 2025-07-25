const std = @import("std");

// ANSI color codes
const RESET = "\x1b[0m";
const YELLOW = "\x1b[33m";
const GREEN = "\x1b[32m";
const BLUE = "\x1b[34m";
const PURPLE = "\x1b[35m";

/// Represents a position in source code
pub const SourceLocation = struct {
    file_id: u32,
    line: u32,
    column: u32,
    char_pos: usize,
};

/// File information stored once
pub const FileInfo = struct {
    path: []const u8,
    source: []const u8,
};

/// Debug info for a function/artifact
pub const DebugInfo = struct {
    allocator: std.mem.Allocator,
    /// Map from PC to location index in the location tree
    pc_to_location_idx: std.AutoHashMap(usize, usize),
    /// Location tree from parsed JSON (references into parsed data)
    locations: []const std.json.Value,
    /// File map from parsed JSON (references into parsed data)  
    files: std.StringHashMap(FileInfo),
    /// Owned parsed JSON data
    parsed_data: std.json.Parsed(std.json.Value),

    pub fn init(
        allocator: std.mem.Allocator,
        debug_symbols_b64: []const u8,
        file_map: ?std.json.Value,
    ) !DebugInfo {
        // Decode and decompress
        const decoded = try decodeBase64(allocator, debug_symbols_b64);
        defer allocator.free(decoded);

        const decompressed = try decompressDeflate(allocator, decoded);
        defer allocator.free(decompressed);

        // Parse debug JSON - keep it alive
        var parsed_data = try std.json.parseFromSlice(std.json.Value, allocator, decompressed, .{});
        errdefer parsed_data.deinit();

        var self = DebugInfo{
            .allocator = allocator,
            .pc_to_location_idx = std.AutoHashMap(usize, usize).init(allocator),
            .locations = &[_]std.json.Value{},
            .files = std.StringHashMap(FileInfo).init(allocator),
            .parsed_data = parsed_data,
        };

        const root = self.parsed_data.value.object;
        
        // Get location tree
        const debug_infos = root.get("debug_infos") orelse return error.NoDebugInfos;
        if (debug_infos.array.items.len > 0) {
            const debug_info = debug_infos.array.items[0];
            if (debug_info.object.get("location_tree")) |tree| {
                if (tree.object.get("locations")) |locs| {
                    self.locations = locs.array.items;
                }
            }
            
            // Parse PC mappings
            try self.parsePCMappings(debug_info);
        }

        // Cache file info from the passed file_map
        if (file_map) |fm| {
            var iter = fm.object.iterator();
            while (iter.next()) |entry| {
                const file_obj = entry.value_ptr.object;
                const path = (file_obj.get("path") orelse continue).string;
                const source = (file_obj.get("source") orelse continue).string;
                
                try self.files.put(entry.key_ptr.*, FileInfo{
                    .path = path,
                    .source = source,
                });
            }
        }

        return self;
    }

    pub fn deinit(self: *DebugInfo) void {
        self.pc_to_location_idx.deinit();
        self.files.deinit();
        self.parsed_data.deinit();
    }

    fn parsePCMappings(self: *DebugInfo, debug_info_item: std.json.Value) !void {
        const locations = debug_info_item.object.get("brillig_locations") orelse return;
        const inner_locations = locations.object.get("0") orelse return;

        var count: usize = 0;
        var iter = inner_locations.object.iterator();
        while (iter.next()) |entry| {
            const pc = std.fmt.parseInt(usize, entry.key_ptr.*, 10) catch continue;
            const location_idx = entry.value_ptr.integer;
            
            if (location_idx >= 0 and location_idx < self.locations.len) {
                try self.pc_to_location_idx.put(pc, @intCast(location_idx));
                count += 1;
            }
        }
    }

    pub fn getSourceLocation(self: *const DebugInfo, pc: usize) ?SourceLocation {
        const loc_idx = self.pc_to_location_idx.get(pc) orelse return null;
        if (loc_idx >= self.locations.len) return null;
        
        const loc = self.locations[loc_idx];
        const value = loc.object.get("value") orelse return null;
        const file_id = (value.object.get("file") orelse return null).integer;
        
        var char_pos: usize = 0;
        if (value.object.get("span")) |span| {
            if (span.object.get("start")) |start| {
                char_pos = @intCast(start.integer);
            }
        }
        
        // Get file and calculate line/column
        var file_key_buf: [32]u8 = undefined;
        const file_key = std.fmt.bufPrint(&file_key_buf, "{}", .{file_id}) catch return null;
        const file_info = self.files.get(file_key) orelse return null;
        
        const line_info = findLineAndColumn(file_info.source, char_pos);
        
        return SourceLocation{
            .file_id = @intCast(file_id),
            .line = @intCast(line_info.line),
            .column = @intCast(line_info.column),
            .char_pos = char_pos,
        };
    }

    pub fn printSourceLocation(self: *const DebugInfo, pc: usize, context_lines: usize) void {
        self.printSourceLocationWithOptions(pc, context_lines, true);
    }
    
    /// Get all lines in a file that have associated opcodes
    pub fn getLinesWithOpcodes(self: *const DebugInfo, file_path: []const u8) !std.ArrayList(u32) {
        var lines = std.ArrayList(u32).init(self.allocator);
        errdefer lines.deinit();
        
        // Find the file_id for this path
        var target_file_id: ?u32 = null;
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.path, file_path)) {
                target_file_id = std.fmt.parseInt(u32, entry.key_ptr.*, 10) catch continue;
                break;
            }
        }
        
        if (target_file_id == null) return lines;
        
        // Collect all lines that have PC mappings
        var pc_iter = self.pc_to_location_idx.iterator();
        while (pc_iter.next()) |entry| {
            const loc = self.getSourceLocation(entry.key_ptr.*) orelse continue;
            if (loc.file_id == target_file_id.?) {
                // Check if we already have this line
                var found = false;
                for (lines.items) |line| {
                    if (line == loc.line) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try lines.append(loc.line);
                }
            }
        }
        
        // Sort the lines
        std.mem.sort(u32, lines.items, {}, std.sort.asc(u32));
        
        return lines;
    }
    
    /// Find the next line with opcodes at or after the given line (max 10 lines ahead)
    pub fn findNextLineWithOpcodes(self: *const DebugInfo, file_path: []const u8, target_line: u32) !?u32 {
        const lines_with_opcodes = try self.getLinesWithOpcodes(file_path);
        defer lines_with_opcodes.deinit();
        
        // Find the first line >= target_line, but only within 10 lines
        const max_line = target_line + 10;
        for (lines_with_opcodes.items) |line| {
            if (line >= target_line and line <= max_line) {
                return line;
            }
        }
        
        return null;
    }
    
    pub fn printSourceLocationWithOptions(self: *const DebugInfo, pc: usize, context_lines: usize, show_column_indicator: bool) void {
        const loc = self.getSourceLocation(pc) orelse {
            std.debug.print("        (source not found)\n", .{});
            return;
        };
        
        var file_key_buf: [32]u8 = undefined;
        const file_key = std.fmt.bufPrint(&file_key_buf, "{}", .{loc.file_id}) catch return;
        const file_info = self.files.get(file_key) orelse return;
        
        // Print location
        std.debug.print("  {s}:{}:{}\n", .{ file_info.path, loc.line, loc.column });
        
        // Print source with context
        printSourceWithContext(file_info.source, loc.line, loc.column, context_lines, show_column_indicator);
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

    fn printSourceWithContext(source: []const u8, target_line: u32, column: u32, context_lines: usize, show_column_indicator: bool) void {
        var lines = std.ArrayList([]const u8).init(std.heap.page_allocator);
        defer lines.deinit();

        // Split source into lines - use splitAny to preserve empty lines
        var iter = std.mem.splitAny(u8, source, "\n");
        while (iter.next()) |line| {
            lines.append(line) catch break;
        }

        const start_line = if (target_line > context_lines) target_line - context_lines else 1;
        const end_line = @min(target_line + context_lines, @as(u32, @intCast(lines.items.len)));

        // Print lines with context
        var i = start_line;
        while (i <= end_line) : (i += 1) {
            if (i - 1 < lines.items.len) {
                if (i == target_line) {
                    // Current line: blue indicator, yellow line number, purple code
                    std.debug.print("{s}>>> {s}{}: {s}{s}{s}\n", .{ 
                        BLUE, YELLOW, i, PURPLE, lines.items[i - 1], RESET 
                    });
                } else {
                    // Context lines: yellow line number
                    std.debug.print("    {s}{}: {s}{s}\n", .{ 
                        YELLOW, i, RESET, lines.items[i - 1] 
                    });
                }
            }
        }

        // Show column indicator for target line
        if (show_column_indicator and column > 0) {
            printColumnIndicator(target_line, column);
        }
    }

    fn printColumnIndicator(line_num: u32, column: u32) void {
        std.debug.print("    ", .{});
        var i: usize = 0;
        const line_digits = std.fmt.count("{}", .{line_num});
        while (i < column + line_digits + 1) : (i += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("{s}^{s}\n", .{ BLUE, RESET });
    }
};
