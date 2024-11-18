const std = @import("std");
const hash = @import("../hash.zig");

const Hash = hash.Hash;

pub fn MemStore(depth: u6, compressFn: hash.HashFunc) type {
    return struct {
        const Self = @This();
        layers: [depth]MemLayer,

        pub fn init(allocator: std.mem.Allocator) !MemStore(depth) {
            var store: MemStore(depth) = undefined;

            var empty_hash = Hash.zero;
            for (0..depth) |layer_index| {
                store.layers[layer_index] = try MemLayer.init(
                    allocator,
                    empty_hash,
                );
                compressFn(&empty_hash, &empty_hash, &empty_hash);
            }

            return store;
        }

        pub fn deinit(self: *Self) void {
            for (&self.layers) |*l| {
                l.deinit();
            }
        }

        pub fn flush(self: *Self) !void {
            for (self.layers[0..]) |*l| try l.flush();
        }
    };
}

const MemLayer = struct {
    data_arr: std.ArrayList(Hash),
    data: []Hash,
    size: usize,
    empty_hash: Hash,

    pub fn init(
        allocator: std.mem.Allocator,
        empty_hash: Hash,
    ) !MemLayer {
        const data_arr = std.ArrayList(Hash).init(allocator);
        return MemLayer{
            .data_arr = data_arr,
            .data = data_arr.items,
            .size = 0,
            .empty_hash = empty_hash,
        };
    }

    pub fn deinit(self: *MemLayer) void {
        defer self.data_arr.deinit();
    }

    pub inline fn get(self: *MemLayer, at: usize) Hash {
        return if (self.data[at].is_zero()) self.empty_hash else self.data[at];
    }

    pub inline fn get_ptr(self: *MemLayer, at: usize) *const Hash {
        return if (self.data[at].is_zero()) &self.empty_hash else &self.data[at];
    }

    /// Appends src to the layer, and returns a slice of elements that must be re-hashed up the tree.
    pub fn append(self: *MemLayer, src: []Hash) void {
        self.update(src, self.size);
    }

    /// Copy src hash slice to at.
    pub fn update(self: *MemLayer, src: []const Hash, at: usize) void {
        const at_end = at + src.len;
        self.ensureCapacity(at_end) catch unreachable;
        const to = self.data[at..at_end];
        std.mem.copyForwards(Hash, to, src);
        self.size = @max(at_end, self.size);
    }

    /// Ensures we can write to self.data[capacity-1].
    /// Capacity is rounded up to be even, so the sibling of the highest value can be read.
    /// Doesn't actually update the size, which represents the highest written element.
    pub fn ensureCapacity(self: *MemLayer, capacity: usize) !void {
        try self.data_arr.resize(capacity + (capacity & 0x1));
        @memset(self.data_arr.items[self.size..], Hash.zero);
        self.data = self.data_arr.items;
    }

    pub fn flush(_: *MemLayer) !void {
        // Noop for a memory store.
    }
};
