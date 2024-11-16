const std = @import("std");
const hash = @import("../hash.zig");

const Hash = hash.Hash;

pub fn MmapStore(depth: u6) type {
    return struct {
        const Self = @This();
        layers: [depth]MmapLayer,

        pub fn init(
            allocator: std.mem.Allocator,
            db_path: []const u8,
            ephemeral: bool,
            erase: bool,
        ) !MmapStore(depth) {
            if (erase) {
                try std.fs.cwd().deleteTree(db_path);
            }

            try std.fs.cwd().makePath(db_path);

            var store: MmapStore(depth) = undefined;

            var empty_hash = Hash.zero;
            for (0..depth) |layer_index| {
                const max_size = @as(usize, 1) << @truncate(depth - 1 - layer_index);
                store.layers[layer_index] = try MmapLayer.init(
                    allocator,
                    db_path,
                    layer_index,
                    max_size,
                    empty_hash,
                    ephemeral,
                );
                hash.compressTask(&empty_hash, &empty_hash, &empty_hash);
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

const MmapLayer = struct {
    data: []align(std.mem.page_size) Hash,
    size: usize,
    empty_hash: Hash,

    pub fn init(
        allocator: std.mem.Allocator,
        base_path: []const u8,
        layer_index: usize,
        max_size: usize,
        empty_hash: Hash,
        ephemeral: bool,
    ) !MmapLayer {
        const layer_filename = try std.fmt.allocPrint(allocator, "{s}/layer_{d:0>2}.dat", .{ base_path, layer_index });
        defer allocator.free(layer_filename);

        const fs = std.fs.cwd();
        var file = try fs.createFile(layer_filename, .{ .read = true, .truncate = false });
        defer file.close();

        // TODO: Capping at 16TB file size (minus one block) to map in (ext4 file size limit).
        // Note xfs doesn't have this limit.
        // There's work to do remap if data exceeds this limit.
        const file_size = @min(max_size * hash.HASH_SIZE, 1024 * 1024 * 1024 * 1024 * 16 - 4096);

        try std.posix.ftruncate(file.handle, file_size);

        const data_bytes = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = if (ephemeral) .PRIVATE else .SHARED },
            file.handle,
            0,
        );

        // 4 = HOLE. Finds the end of the data within the sparse file.
        const eof = std.c.lseek64(file.handle, 0, 4);
        if (eof == -1) {
            return error.SeekFailed;
        }
        const data = std.mem.bytesAsSlice(Hash, data_bytes);
        var size: usize = @as(usize, @bitCast(eof)) / hash.HASH_SIZE;
        if (size > 0) {
            while (data[size - 1].is_zero()) size -= 1;
        }
        // std.debug.print("{s}: {d} {d}\n", .{ layer_filename, (try file.stat()).size, size });

        return MmapLayer{
            .data = data,
            .size = size,
            .empty_hash = empty_hash,
        };
    }

    pub fn deinit(self: *MmapLayer) void {
        defer std.posix.munmap(std.mem.sliceAsBytes(self.data));
    }

    pub inline fn get(self: *MmapLayer, at: usize) Hash {
        return if (self.data[at].is_zero()) self.empty_hash else self.data[at];
    }

    pub inline fn get_ptr(self: *MmapLayer, at: usize) *const Hash {
        return if (self.data[at].is_zero()) &self.empty_hash else &self.data[at];
    }

    /// Appends src to the layer, and returns a slice of elements that must be re-hashed up the tree.
    pub fn append(self: *MmapLayer, src: []Hash) void {
        self.update(src, self.size);
    }

    /// Copy src hash slice to at.
    pub fn update(self: *MmapLayer, src: []const Hash, at: usize) void {
        const at_end = at + src.len;
        const to = self.data[at..at_end];
        std.mem.copyForwards(Hash, to, src);
        self.size = @max(at_end, self.size);
    }

    /// Ensures we can write to self.data[capacity-1].
    /// Doesn't actually update the size, which represents the highest written element.
    pub fn ensureCapacity(self: *MmapLayer, capacity: usize) !void {
        if (capacity > self.data.len) {
            std.debug.panic("Requested capacity greater than mapped region: {}\n", .{capacity});
        }
    }

    pub fn flush(self: *MmapLayer) !void {
        try std.posix.msync(std.mem.asBytes(self.data.ptr), 4);
    }
};
