const std = @import("std");
const lmdb = @import("lmdb");
const mt = @import("./merkle_tree.zig");
const hash = @import("./hash.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const bincode = @import("../bincode/bincode.zig");
const poseidon2Hash = @import("../poseidon2/poseidon2.zig").hash;
const ThreadPool = @import("../thread/thread_pool.zig").ThreadPool;

/// From clients perspective, this presents a set of values.
/// You can add to the set, and check if a value is present in the set.
/// The set of values is also recorded within a merkle tree which can be probed for witness data of (non)existence.
/// The leaves of the merkle tree represent a linked list of values, allowing updates via appends and updates.
/// This model is cheaper (shallower trees) than a traditional sparse tree which would need a depth of e.g. 256.
/// Adds a btree (lmdb) structure for storing ordered value -> tree index mappings.
/// The actual leaf nodes in the tree are not the direct value, but of compressed type Leaf, to encode the links.
/// These are required to locate list elements and their pre-images within the merkle tree for updates.
pub fn IndexedMerkleTree(depth: u6, comptime compressFn: hash.HashFunc) type {
    return struct {
        const Self = @This();
        const MerkleTree = mt.MerkleTree(depth, mt.MmapStore(depth, compressFn), compressFn);
        const Hash = hash.Hash;
        /// Represents an entry in the linked list we write to lmdb.
        const Entry = struct {
            next_value: u256,
            index: u64,
            next_index: u64,

            pub inline fn toBuf(self: *const Entry) [48]u8 {
                var buffer: [48]u8 = undefined;
                var stream = std.io.fixedBufferStream(&buffer);
                bincode.serialize(stream.writer(), self.*) catch unreachable;
                return buffer;
            }

            pub inline fn toLeaf(self: *const Entry, value: Hash) Hash {
                return poseidon2Hash(&[_]Hash{ value, Hash.from_int(self.next_value), Hash.from_int(self.index) });
            }
        };
        /// For scheduling the toLeaf calls of each Entry on the thread pool.
        const EntryTask = struct {
            task: ThreadPool.Task,
            entry: Entry,
            value: Hash,
            as_leaf: Hash,
            cnt: *std.atomic.Value(u64),

            pub fn onSchedule(task: *ThreadPool.Task) void {
                const self: *EntryTask = @alignCast(@fieldParentPtr("task", task));
                self.as_leaf = self.entry.toLeaf(self.value);
                _ = self.cnt.fetchSub(1, .release);
            }
        };
        allocator: std.mem.Allocator,
        tree: MerkleTree,
        lmdb_env: lmdb.Environment,
        pool: ?*ThreadPool,

        pub fn init(allocator: std.mem.Allocator, db_path: []const u8, pool: ?*ThreadPool, erase: bool) !Self {
            if (erase) {
                try std.fs.cwd().deleteTree(db_path);
            }

            try std.fs.cwd().makePath(db_path);

            const lmdb_env = try lmdb.Environment.init(@ptrCast(db_path.ptr), .{ .map_size = 1024 * 1024 * 1024 });
            var tree = try mt.MerkleTreeDb(depth, hash.poseidon2).init(allocator, db_path, pool, false, false);

            const stat = try lmdb_env.stat();
            if (stat.entries == 0) {
                // Ensure our 0 leaf is present.
                const txn = try lmdb.Transaction.init(lmdb_env, .{ .mode = .ReadWrite });
                errdefer txn.abort();
                const zero_entry = std.mem.zeroes(Entry);
                try txn.set(&Fr.zero.to_buf(), std.mem.asBytes(&zero_entry));
                try txn.commit();
                try tree.append(&[_]Hash{Hash.zero});
            }

            return .{
                .allocator = allocator,
                .tree = tree,
                .lmdb_env = lmdb_env,
                .pool = pool,
            };
        }

        pub fn deinit(self: *Self) void {
            self.tree.deinit();
            self.lmdb_env.deinit();
        }

        pub fn add(self: *Self, value: Hash) !void {
            try self.batchAdd(&[_]Hash{value});
        }

        pub fn batchAdd(self: *Self, values: []const Hash) !void {
            const txn = try lmdb.Transaction.init(self.lmdb_env, .{ .mode = .ReadWrite });
            errdefer txn.abort();
            var c = try txn.cursor();

            // Allocate space for our leaf computation tasks.
            // There are 2 leaves for every value, the append and prior leaf update.
            var update_tasks = try std.ArrayList(EntryTask).initCapacity(self.allocator, values.len);
            defer update_tasks.deinit();
            var append_tasks = try std.ArrayList(EntryTask).initCapacity(self.allocator, values.len);
            defer append_tasks.deinit();
            var task_counter = std.atomic.Value(u64).init(values.len * 2);

            // var timer = try std.time.Timer.start();

            for (values, self.tree.size()..) |v, idx| {
                const key = &v.to_buf();

                // Find the existing, or nearest lower leaf.
                // std.debug.print("seeking to key {x}...\n", .{key});
                const r = try c.seek(key);
                // std.debug.print("seek to key {x} returned {any}\n", .{ v, r });

                if (r) |e| {
                    if (std.mem.eql(u8, e, key)) {
                        // If this entry already exists, fail.
                        return error.AlreadyExists;
                    }
                }

                // It doesn't exist, so we get the nearest lower value.
                const prev = (try c.goToPrevious()).?;
                const prev_key = Hash.from_buf_slice(prev);
                var prev_value_buf = try c.getCurrentValue();
                // std.debug.print("low element: key {any} value {any} len {}\n", .{ prev, prev_value_buf, prev_value_buf.len });
                var prev_entry = bincode.deserializeBuffer(Entry, &prev_value_buf);

                const new_entry = Entry{
                    .index = idx,
                    .next_index = prev_entry.next_index,
                    .next_value = prev_entry.next_value,
                };

                // Update the entry.
                // std.debug.print("before update {}\n", .{prev_entry});
                prev_entry.next_index = idx;
                prev_entry.next_value = v.to_int();

                // std.debug.print("updating key {any} value {any}\n", .{ prev, prev_entry });
                // std.debug.print("inserting key {any} value {any}\n", .{ key, new_entry });

                try txn.set(prev, &prev_entry.toBuf());
                try txn.set(key, &new_entry.toBuf());

                // Add the tasks to compute the leafs.
                try update_tasks.append(.{
                    .entry = prev_entry,
                    .value = prev_key,
                    .task = ThreadPool.Task{ .callback = EntryTask.onSchedule },
                    .cnt = &task_counter,
                    .as_leaf = Hash.zero,
                });
                try append_tasks.append(.{
                    .entry = new_entry,
                    .value = v,
                    .task = ThreadPool.Task{ .callback = EntryTask.onSchedule },
                    .cnt = &task_counter,
                    .as_leaf = Hash.zero,
                });

                // Schedule the tasks.
                if (self.pool) |p| {
                    p.schedule(ThreadPool.Batch.from(&update_tasks.items[update_tasks.items.len - 1].task));
                    p.schedule(ThreadPool.Batch.from(&append_tasks.items[append_tasks.items.len - 1].task));
                } else {
                    EntryTask.onSchedule(&update_tasks.items[update_tasks.items.len - 1].task);
                    EntryTask.onSchedule(&append_tasks.items[append_tasks.items.len - 1].task);
                }
            }
            // std.debug.print("prep data: {}us\n", .{timer.read() / 1000});

            // timer.reset();
            try txn.commit();
            // std.debug.print("tx commit: {}us\n", .{timer.read() / 1000});

            // Spin waiting for all leaf computation jobs to complete.
            while (task_counter.load(.acquire) > 0) {
                std.atomic.spinLoopHint();
            }

            // Construct our set of tree updates.
            // Prealloc 1 low-leaf update per value, plus 1 batch insert.
            var tree_updates = try std.ArrayList(mt.MerkleUpdate).initCapacity(self.allocator, values.len + 1);
            defer tree_updates.deinit();
            for (update_tasks.items) |*t| {
                try tree_updates.append(.{ .index = t.entry.index, .hashes = &[_]Hash{t.as_leaf} });
            }
            var append_leaves = try self.allocator.alloc(Hash, append_tasks.items.len);
            defer self.allocator.free(append_leaves);
            for (append_tasks.items, 0..) |*t, i| append_leaves[i] = t.as_leaf;
            try tree_updates.append(.{ .index = self.tree.size(), .hashes = append_leaves });

            // Update tree.
            // timer.reset();
            try self.tree.update(tree_updates.items);
            // std.debug.print("tree update: {}us\n", .{timer.read() / 1000});
        }

        pub fn exists(self: *Self, value: Hash) !bool {
            const r = try self.batchExists(&[_]Hash{value});
            return r[0];
        }

        pub fn batchExists(self: *Self, values: []const Hash) ![]bool {
            const txn = try lmdb.Transaction.init(self.lmdb_env, .{ .mode = .ReadOnly });
            defer txn.abort();
            var c = try txn.cursor();
            var r = try self.allocator.alloc(bool, values.len);
            @memset(r, false);
            for (values, 0..) |*value, i| {
                const key = &value.to_buf();
                c.goToKey(key) catch continue;
                r[i] = true;
            }
            return r;
        }
    };
}

// test "lmdb bench" {
//     const allocator = std.heap.page_allocator;
//     const num = 1024 * 1024;
//     const value = std.mem.zeroes([48]u8);
//     var keys = try std.ArrayListAligned(u256, 32).initCapacity(allocator, num);
//     defer keys.deinit();
//     try keys.resize(keys.capacity);
//     for (keys.items, 1..) |*v, i| v.* = i;

//     const db_path = "lmdb_bench_data";
//     try std.fs.cwd().deleteTree(db_path);
//     try std.fs.cwd().makePath(db_path);
//     // defer std.fs.cwd().deleteTree(db_path) catch unreachable;

//     const lmdb_env = try lmdb.Environment.init(db_path, .{ .map_size = 1024 * 1024 * 1024 });

//     const txn = try lmdb.Transaction.init(lmdb_env, .{ .mode = .ReadWrite });
//     errdefer txn.abort();
//     var t = try std.time.Timer.start();
//     for (keys.items) |k| {
//         try txn.set(std.mem.asBytes(&k), std.mem.asBytes(&value));
//     }
//     try txn.commit();
//     const took = t.read();
//     std.debug.print("Update {} entries in {}ms {d:.0}/s\n", .{
//         keys.items.len,
//         took / 1_000_000,
//         @as(f64, @floatFromInt(keys.items.len)) / (@as(f64, @floatFromInt(took)) / 1_000_000_000),
//     });
// }

test "exists" {
    const data_dir = "./data/indexed_merkle_tree_exists";
    defer std.fs.cwd().deleteTree(data_dir) catch unreachable;

    var tree = try IndexedMerkleTree(2, hash.poseidon2).init(std.heap.page_allocator, data_dir, null, true);
    defer tree.deinit();

    const e = Fr.random();
    try std.testing.expect(try tree.exists(Fr.random()) == false);

    try tree.add(e);
    try std.testing.expect(try tree.exists(e));
}

test "bench" {
    const allocator = std.heap.page_allocator;
    const depth = 40;
    const num = 1024 * 1024;
    const threads = @min(try std.Thread.getCpuCount(), 64);
    const data_dir = "./data/indexed_merkle_tree_bench";
    defer std.fs.cwd().deleteTree(data_dir) catch unreachable;

    var pool = ThreadPool.init(.{ .max_threads = threads });
    defer {
        pool.shutdown();
        pool.deinit();
    }

    var tree = try IndexedMerkleTree(depth, hash.poseidon2).init(allocator, data_dir, &pool, true);
    defer tree.deinit();

    var values = try std.ArrayListAligned(hash.Hash, 32).initCapacity(allocator, num);
    defer values.deinit();
    try values.resize(values.capacity);
    for (values.items, 1..) |*v, i| {
        v.* = Fr.from_int(i);
    }

    var t = try std.time.Timer.start();
    try tree.batchAdd(values.items);
    const took = t.read();
    std.debug.print("Inserted {} entries in {}ms {d:.0}/s\n", .{
        values.items.len,
        took / 1_000_000,
        @as(f64, @floatFromInt(values.items.len)) / (@as(f64, @floatFromInt(took)) / 1_000_000_000),
    });
    std.debug.print("Root: {x}\n", .{tree.tree.root()});

    if (num == 1024 * 1024) {
        const expected = Fr.from_int(0x135c92b3c43dabe4aabffc13043e3bc23206a3c7c3bfb79b78212c427bf18182);
        try std.testing.expect(tree.tree.root().eql(expected));
    }

    const exists = try tree.batchExists(values.items);
    for (exists) |e| {
        try std.testing.expect(e);
    }
}
