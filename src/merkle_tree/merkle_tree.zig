const std = @import("std");
const formatStruct = @import("../bvm/io.zig").formatStruct;
const Fr = @import("../bn254/fr.zig").Fr;
const G1 = @import("../grumpkin/g1.zig").G1;
const pedersenHash = @import("../pedersen/pedersen.zig").hash;
const poseidon2Hash = @import("../poseidon2/poseidon2.zig").hash;

const HASH_SIZE = 32;
const Hash = Fr; //[HASH_SIZE]u8;
// const EMPTY_HASH = std.mem.zeroes(Hash);

fn compressSh256(lhs: *const Hash, rhs: *const Hash) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var r: Hash = undefined;
    hasher.update(lhs);
    hasher.update(rhs);
    hasher.final(&r);
    return r;
}

fn compressTask(lhs: *Hash, rhs: *Hash, dst: *Hash) void {
    // dst.* = compressSh256(lhs, rhs);

    // const glhs = G1.Fr.from_int(lhs.to_int());
    // const grhs = G1.Fr.from_int(rhs.to_int());
    // dst.* = pedersenHash(G1, &[_]G1.Fr{ glhs, grhs }, 0);

    dst.* = poseidon2Hash(&[_]Fr{ lhs.*, rhs.* });
}

var glob_pool: std.Thread.Pool = undefined;

// You can stare at this for inspiration.
//
// 3:                               [ ]
//                             /            \
// 2:               [ ]                             [ ]
//               /       \                       /       \
// 1:       [ ]             [ ]             [ ]             [ ]
//        /     \         /     \         /     \         /     \
// 0:   [0]     [1]     [2]     [3]     [4]     [5]     [6]     [7]
const MerkleTree = struct {
    allocator: std.mem.Allocator,
    db_path: []const u8,
    layers: std.ArrayList(Layer),
    depth: u6,
    pool: ?*std.Thread.Pool,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8, depth: u6, threads: u8, erase: bool) !MerkleTree {
        var tree = MerkleTree{
            .allocator = allocator,
            .db_path = db_path,
            .layers = try std.ArrayList(Layer).initCapacity(allocator, depth),
            .depth = depth,
            .pool = if (threads > 0) &glob_pool else null,
        };

        if (tree.pool) |p| {
            try p.init(.{ .allocator = allocator, .n_jobs = threads });
        }

        if (erase) {
            try std.fs.cwd().deleteTree(db_path);
        }

        try std.fs.cwd().makePath(db_path);

        var empty_hash = Hash.zero;
        for (0..depth) |layer_index| {
            const max_size = @as(usize, 1) << @truncate(depth - 1 - layer_index);
            try tree.layers.append(try Layer.init(allocator, db_path, layer_index, max_size, empty_hash));
            compressTask(&empty_hash, &empty_hash, &empty_hash);
        }

        return tree;
    }

    pub fn deinit(self: *MerkleTree) void {
        for (self.layers.items) |*layer| {
            layer.deinit();
        }
        self.layers.deinit();
        if (self.pool) |p| p.deinit();
    }

    pub fn append(self: *MerkleTree, leaves: []Hash) !void {
        try self.update(&.{.{ .index = self.layers.items[0].size, .hashes = leaves }});
    }

    fn update(self: *MerkleTree, updates: []const MerkleUpdate) !void {
        // TODO: Parallelise?
        // Maybe not. If most of these are single entry updates, it would be more costly to marshal these
        // out to threads, than just copying them into place.
        for (updates) |u| {
            self.layers.items[0].update(u.hashes, u.index);
        }

        for (1..self.layers.items.len) |li| {
            var to_layer = self.layers.items[li];
            const from_layer = self.layers.items[li - 1];

            var wg = std.Thread.WaitGroup{};
            wg.reset();

            for (updates) |u| {
                var l0_start = u.index;
                var l0_end = l0_start + u.hashes.len;
                l0_start -= l0_start & 1;
                l0_end += l0_end & 1;
                var from_start = l0_start >> @truncate(li - 1);
                var from_end = l0_end >> @truncate(li - 1);
                from_start -= from_start & 1;
                from_end += from_end & 1;
                from_end = @max(from_end, 2);

                const to_start = from_start >> 1;
                const to_end = from_end >> 1;
                const from = from_layer.data[from_start..from_end];

                to_layer.size = @max(to_layer.size, to_end);

                // printStruct(.{
                //     .li = li,
                //     .start = l0_start,
                //     .end = l0_end,
                //     .from_start = from_start,
                //     .from_end = from_end,
                //     .to_start = to_start,
                //     .to_end = to_end,
                // });
                // to_layer.compressUpdate(from, to_start, &wg);
                const to = to_layer.data[to_start..to_end];

                for (0..to.len) |i| {
                    const lhs = &from[i * 2];
                    const rhs_index = i * 2 + 1;
                    const rhs = if (from.len == 1 or from[rhs_index].is_zero())
                        &to_layer.empty_hash
                    else
                        &from[rhs_index];
                    const dst = &to[i];

                    // printStruct(.{
                    //     .i = i,
                    //     .lhs = lhs,
                    //     .rhs = rhs,
                    //     .dst = dst,
                    //     .pool = self.pool,
                    // });

                    if (self.pool) |p| {
                        p.spawnWg(&wg, compressTask, .{ lhs, rhs, dst });
                    } else {
                        compressTask(lhs, rhs, dst);
                    }
                }
            }

            wg.wait();
            // self.pool.waitAndWork(&wg);
        }
    }

    fn flush(self: *MerkleTree) !void {
        for (self.layers.items) |*l| try l.flush();
    }
};

fn printStruct(s: anytype) void {
    const stderr = std.io.getStdErr().writer();
    formatStruct(s, stderr) catch unreachable;
    stderr.print("\n", .{}) catch unreachable;
}

const Layer = struct {
    allocator: std.mem.Allocator,
    data: []align(std.mem.page_size) Hash,
    size: usize,
    empty_hash: Hash,

    pub fn init(
        allocator: std.mem.Allocator,
        base_path: []const u8,
        layer_index: usize,
        max_size: usize,
        empty_hash: Hash,
        // pool: *std.Thread.Pool,
    ) !Layer {
        const layer_filename = try std.fmt.allocPrint(allocator, "{s}/layer_{d:0>2}.dat", .{ base_path, layer_index });
        defer allocator.free(layer_filename);

        const fs = std.fs.cwd();
        var file = try fs.createFile(layer_filename, .{ .read = true, .truncate = false });
        defer file.close();

        const file_size = max_size * HASH_SIZE;

        try std.posix.ftruncate(file.handle, file_size);

        const data_bytes = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        // 4 = HOLE. Finds the end of the data within the sparse file.
        const eof = std.c.lseek64(file.handle, 0, 4);
        if (eof == -1) {
            return error.SeekFailed;
        }
        const data = std.mem.bytesAsSlice(Hash, data_bytes);
        var size: usize = @as(usize, @bitCast(eof)) / HASH_SIZE;
        if (size > 0) {
            while (data[size - 1].is_zero()) size -= 1;
        }
        // std.debug.print("{s}: {d} {d}\n", .{ layer_filename, (try file.stat()).size, size });

        return Layer{
            .allocator = allocator,
            .data = data,
            .size = size,
            .empty_hash = empty_hash,
        };
    }

    pub fn deinit(self: *Layer) void {
        defer std.posix.munmap(std.mem.sliceAsBytes(self.data));
    }

    /// Appends src to the layer, and returns a slice of elements that must be re-hashed up the tree.
    pub fn append(self: *Layer, src: []Hash) void {
        self.update(src, self.size);
    }

    /// Copy src hash slice to at.
    pub fn update(self: *Layer, src: []Hash, at: usize) void {
        const at_end = at + src.len;
        const to = self.data[at..at_end];
        std.mem.copyForwards(Hash, to, src);
        self.size = @max(at_end, self.size);
    }

    pub fn flush(self: *Layer) !void {
        try std.posix.msync(std.mem.asBytes(self.data.ptr), 4);
    }
};

const MerkleUpdate = struct {
    index: usize,
    hashes: []Hash,
};

test "merkle tree" {
    const allocator = std.heap.page_allocator;

    var merkle_tree = try MerkleTree.init(allocator, "./merkle_tree_data", 40, 0, true);
    defer merkle_tree.deinit();

    // Detect and reapply any committed transactions on startup
    // try merkle_tree.recover();

    const num = 1024 * 256;
    var values = try std.ArrayListAligned(Hash, 32).initCapacity(allocator, num);
    defer values.deinit();
    try values.resize(values.capacity);
    for (values.items, 1..) |*v, i| {
        v.* = Fr.from_int(i);
        // const p: *u256 = @ptrCast(v);
        // p.* = i;
    }

    var t = try std.time.Timer.start();
    try merkle_tree.append(values.items);
    try merkle_tree.flush();
    std.debug.print("Inserted {} entries in {}ms\n", .{ values.items.len, t.read() / 1_000_000 });

    // var updates = try std.ArrayList(MerkleUpdate).initCapacity(allocator, num);
    // for (0..num) |i| {
    //     try updates.append(.{ .index = i, .hashes = values.items[666..667] });
    // }
    // t.reset();
    // try merkle_tree.update(updates.items);
    // try merkle_tree.flush();
    // std.debug.print("Updated {} entries in {}ms\n", .{ values.items.len, t.read() / 1_000_000 });

    // Example usage: adding and updating leaves
    // var updates = [_]MerkleUpdate{
    //     .{ .index = 0, .hash = [HASH_SIZE]u8{ /* ... */ } },
    //     // Add more updates as needed
    // };

    // try merkle_tree.applyTransaction(&updates);
}
