const std = @import("std");
const fs = std.fs;

pub const NetSrs = struct {
    num_points: usize,
    g1_data: []u8,
    g2_data: [128]u8,
    cache_path: ?[]const u8,

    pub fn init(num_points: usize, cache_path: ?[]const u8) !NetSrs {
        const allocator = std.heap.page_allocator;
        const g1_data = try allocator.alloc(u8, num_points * 64);

        var instance = NetSrs{
            .num_points = num_points,
            .g1_data = g1_data,
            .g2_data = undefined,
            .cache_path = cache_path,
        };

        if (cache_path) |path| {
            const g1_cache_file = try fs.path.join(allocator, &[_][]const u8{ path, "bn254_g1.dat" });
            defer allocator.free(g1_cache_file);

            const g2_cache_file = try fs.path.join(allocator, &[_][]const u8{ path, "bn254_g2.dat" });
            defer allocator.free(g2_cache_file);

            if (try NetSrs.useCacheOrDownload(g1_cache_file, instance.g1_data)) {
                std.debug.print("Using cached G1 data.\n", .{});
            } else {
                std.debug.print("Downloading G1 data.\n", .{});
                try NetSrs.downloadG1Data(num_points, g1_data);
                try NetSrs.saveToCache(g1_cache_file, g1_data);
            }

            if (try NetSrs.useCacheOrDownload(g2_cache_file, &instance.g2_data)) {
                std.debug.print("Using cached G2 data.\n", .{});
            } else {
                std.debug.print("Downloading G2 data.\n", .{});
                try NetSrs.downloadG2Data(&instance.g2_data);
                try NetSrs.saveToCache(g2_cache_file, &instance.g2_data);
            }
        } else {
            std.debug.print("Downloading G1 and G2 data without cache.\n", .{});
            try NetSrs.downloadG1Data(num_points, g1_data);
            try NetSrs.downloadG2Data(&instance.g2_data);
        }

        return instance;
    }

    pub fn deinit(self: NetSrs) void {
        std.heap.page_allocator.free(self.g1_data);
    }

    pub fn getNumPoints(self: NetSrs) usize {
        return self.num_points;
    }

    pub fn getG1Data(self: NetSrs) []u8 {
        return self.g1_data;
    }

    pub fn getG2Data(self: NetSrs) [128]u8 {
        return self.g2_data;
    }

    fn downloadG1Data(num_points: usize, buf: []u8) !void {
        const allocator = std.heap.page_allocator;
        const g1_end = num_points * 64 - 1;

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const range_header = std.fmt.allocPrint(allocator, "bytes=0-{}", .{g1_end}) catch unreachable;
        defer allocator.free(range_header);

        var array_list = std.ArrayListAlignedUnmanaged(u8, null).initBuffer(buf);

        _ = try client.fetch(.{
            .location = .{ .url = "https://aztec-ignition.s3.amazonaws.com/MAIN%20IGNITION/flat/g1.dat" },
            .extra_headers = &[_]std.http.Header{
                .{
                    .name = "Range",
                    .value = range_header,
                },
            },
            .response_storage = .{ .static = &array_list },
        });
    }

    fn downloadG2Data(buf: []u8) !void {
        const allocator = std.heap.page_allocator;

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var array_list = std.ArrayListAlignedUnmanaged(u8, null).initBuffer(buf);

        _ = try client.fetch(.{
            .location = .{ .url = "https://aztec-ignition.s3.amazonaws.com/MAIN%20IGNITION/flat/g2.dat" },
            .response_storage = .{ .static = &array_list },
        });
    }

    fn useCacheOrDownload(cache_file: []const u8, buf: []u8) !bool {
        var file = fs.cwd().openFile(cache_file, .{}) catch return false;
        defer file.close();

        const file_info = try file.stat();
        if (file_info.size >= buf.len) {
            _ = try file.readAll(buf);
            return true;
        }

        return false;
    }

    fn saveToCache(cache_file: []const u8, data: []const u8) !void {
        var file = try fs.cwd().createFile(cache_file, .{ .truncate = true });
        defer file.close();

        try file.writeAll(data);
    }
};

test "download points" {
    std.debug.print("downloading...\n", .{});
    var timer = try std.time.Timer.start();

    const net_srs = try NetSrs.init(128, "/mnt/user-data/charlie/.bb-crs");
    defer net_srs.deinit();

    std.debug.print("{}ms\n", .{timer.read() / 1_000_000});
    std.debug.print("{x}\n", .{net_srs.getG2Data()});
    std.debug.print("{x}\n", .{net_srs.getG1Data()});
}
