const std = @import("std");

pub const NetSrs = struct {
    num_points: usize,
    g1_data: []u8,
    g2_data: [128]u8,

    pub fn init(num_points: usize) !NetSrs {
        const g1_data = try std.heap.page_allocator.alloc(u8, num_points * 64);
        var g2_data: [128]u8 = undefined;
        try NetSrs.downloadG1Data(num_points, g1_data);
        try NetSrs.downloadG2Data(&g2_data);
        return NetSrs{
            .num_points = num_points,
            .g1_data = g1_data,
            .g2_data = g2_data,
        };
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
};

test "download points" {
    std.debug.print("downloading...\n", .{});
    var timer = try std.time.Timer.start();
    const net_srs = try NetSrs.init(128);
    std.debug.print("{}ms\n", .{timer.read() / 1_000_000});
    std.debug.print("{x}\n", .{net_srs.getG2Data()});
    std.debug.print("{x}\n", .{net_srs.getG1Data()});
}
