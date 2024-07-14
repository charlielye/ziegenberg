const std = @import("std");
const Bn254G1 = @import("../bn254/g1.zig").G1;
const fs = std.fs;

pub fn FileSrs(comptime G1: type) type {
    return struct {
        const Self = @This();
        num_points: usize,
        g1_data: []G1.Element,
        g2_data: [128]u8,
        cache_path: ?[]const u8,

        pub fn init(num_points: usize, cache_path: []const u8) !Self {
            const allocator = std.heap.page_allocator;
            const g1_data = try allocator.alloc(G1.Element, num_points);

            const instance = Self{
                .num_points = num_points,
                .g1_data = g1_data,
                .g2_data = undefined,
                .cache_path = cache_path,
            };

            const g1_cache_file = try fs.path.join(allocator, &[_][]const u8{ cache_path, "bn254_g1.dat" });
            defer allocator.free(g1_cache_file);

            // const g2_cache_file = try fs.path.join(allocator, &[_][]const u8{ cache_path, "bn254_g2.dat" });
            // defer allocator.free(g2_cache_file);

            try Self.load(g1_cache_file, instance.g1_data);
            // try FileSrs(G1).load(g2_cache_file, &instance.g2_data);

            return instance;
        }

        pub fn deinit(self: Self) void {
            std.heap.page_allocator.free(self.g1_data);
        }

        pub fn getNumPoints(self: Self) usize {
            return self.num_points;
        }

        pub fn getG1Data(self: Self) []G1.Element {
            return self.g1_data;
        }

        pub fn getG2Data(self: Self) [128]u8 {
            return self.g2_data;
        }

        fn load(cache_file: []const u8, buf: []G1.Element) !void {
            var file = try fs.cwd().openFile(cache_file, .{});
            defer file.close();

            const file_info = try file.stat();
            if (file_info.size < buf.len) {
                unreachable;
            }
            // _ = try file.readAll(buf);
            var temp_buf: [64]u8 = undefined;
            var i: usize = 0;
            while (i < buf.len) : (i += 1) {
                _ = try file.readAll(&temp_buf);
                buf[i] = G1.Element.from_buf(temp_buf);
            }
        }
    };
}

test "load points" {
    // std.debug.print("loading...\n", .{});
    // var timer = try std.time.Timer.start();

    const net_srs = try FileSrs(Bn254G1).init(128, "/mnt/user-data/charlie/.bb-crs");
    defer net_srs.deinit();
    try std.testing.expectEqual(net_srs.getG1Data().len, 128);
    try std.testing.expect(net_srs.getG1Data()[0].eql(Bn254G1.Element.one));

    // std.debug.print("{}ms\n", .{timer.read() / 1_000_000});
    // std.debug.print("{x}\n", .{net_srs.getG2Data()});
    // std.debug.print("{x}\n", .{net_srs.getG1Data()});
    // std.debug.print("{}\n", .{net_srs.getG1Data().len});
}
