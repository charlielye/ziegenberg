/// A super fast merkle tree implementation using memory mapped io and optimal threading strategies.
///
/// t % zig build test-exe install -Doptimize=ReleaseFast -Dtest-filter='merkle tree' && ./zig-out/bin/tests                                                      8s ~/ziegenberg master+ charlie-box
/// Benching: size: 1048576, threads: 64
/// Inserted 1048576 entries in 385ms 2722472/s
/// Root: 0x221e028d9ae9ac247e2d93c8cdcddffc7d7f17f88c000fb6555f0a262a64c1b9
/// Updated 1048576 entries in 8452ms 124050/s
/// Root: 0x221e028d9ae9ac247e2d93c8cdcddffc7d7f17f88c000fb6555f0a262a64c1b9
/// Benching: size: 1048576, threads: 64
/// Update with witness 1048576 entries in 16481ms 63620/s
/// Root: 0x221e028d9ae9ac247e2d93c8cdcddffc7d7f17f88c000fb6555f0a262a64c1b9
/// All 3 tests passed.
const std = @import("std");
const formatStruct = @import("../bvm/io.zig").formatStruct;
const Fr = @import("../bn254/fr.zig").Fr;
const poseidon2Hash = @import("../poseidon2/poseidon2.zig").hash;
const ThreadPool = @import("../thread/thread_pool.zig").ThreadPool;
const hash = @import("./hash.zig");
pub const MmapStore = @import("./store/mmap.zig").MmapStore;
pub const MemStore = @import("./store/mem.zig").MemStore;

const Hash = hash.Hash;

pub const MerkleUpdate = struct {
    index: usize,
    hashes: []const Hash,
};

pub const IndividualUpdate = struct {
    index: usize,
    value: Hash,
};

// You can stare at this for inspiration.
//
// 3:                               [ ]
//                             /            \
// 2:               [ ]                             [ ]
//               /       \                       /       \
// 1:       [ ]             [ ]             [ ]             [ ]
//        /     \         /     \         /     \         /     \
// 0:   [0]     [1]     [2]     [3]     [4]     [5]     [6]     [7]
pub fn MerkleTree(depth: u6, comptime Store: type, comptime compressFn: hash.HashFunc) type {
    return struct {
        const Self = @This();
        pub const Index = std.meta.Int(.unsigned, depth);
        const HashPath = [depth - 1]Hash;
        const IndividualUpdateResult = struct {
            index: usize,
            before_path: HashPath,
            after_path: HashPath,
            sibling_path: HashPath,
            root_before: Hash,
            root_after: Hash,
        };
        allocator: std.mem.Allocator,
        store: Store,
        pool: ?*ThreadPool,

        /// A task object for scheduling onto the thread pool that performs a hash compression.
        /// This is used for the simple case of updating a collection of leaves, where no intermediate state is needed.
        /// We layer by layer, schedule the compressions for that layer, wait for completion, and advance up a layer.
        const CompressTask = struct {
            task: ThreadPool.Task,
            lhs: *Hash,
            rhs: *Hash,
            dst: *Hash,
            cnt: *std.atomic.Value(u64),

            pub fn onSchedule(task: *ThreadPool.Task) void {
                const self: *CompressTask = @fieldParentPtr("task", task);
                compressFn(self.lhs, self.rhs, self.dst);
                _ = self.cnt.fetchSub(1, .release);
            }
        };

        /// A task object for scheduling individual updates that return witness data needed for proving.
        /// We need each intermediate hash path to reflect the state between each update.
        /// In this situation only one task at a time can be updating a given layer to ensure we do not overlap.
        /// The task list is double linked.
        /// This allows a task to wait until its predecessor has advanced to a layer above before updating the layer.
        /// It also allows a task to schedule it's successor once it has been scheduled (to avoid deadlock).
        const IndividualUpdateTask = struct {
            task: ThreadPool.Task,
            index: usize,
            value: *const Hash,
            level: std.atomic.Value(u64),
            next: ?*IndividualUpdateTask,
            prev: ?*IndividualUpdateTask,
            store: *Store,
            result: *IndividualUpdateResult,
            pool: ?*ThreadPool,

            pub fn onSchedule(task: *ThreadPool.Task) void {
                const self: *IndividualUpdateTask = @fieldParentPtr("task", task);

                self.result.index = self.index;

                var lhs: Hash = undefined;
                var rhs: Hash = undefined;

                for (0..depth) |li| {
                    // Announce our new level. Permits our successor to exit the loop below.
                    self.level.store(li, .release);

                    // Loop, waiting for the update before us to advance to a higher level.
                    if (self.prev) |prev| {
                        // var spin_count: usize = 0;
                        while (prev.level.load(.acquire) == self.level.load(.monotonic)) {
                            // std.atomic.spinLoopHint();
                            // spin_count += 1;
                            // if (spin_count > 200) {
                            // Yield to the OS scheduler after spinning for a while.
                            std.Thread.yield() catch unreachable;
                            //     spin_count = 0;
                            // }
                        }
                    }

                    if (li == 0) {
                        const is_right = self.index & 1 == 1;
                        if (!is_right) {
                            lhs = self.value.*;
                            rhs = self.store.layers[0].get(self.index + 1);
                            self.result.sibling_path[0] = rhs;
                        } else {
                            lhs = self.store.layers[0].get(self.index - 1);
                            rhs = self.value.*;
                            self.result.sibling_path[0] = lhs;
                        }
                        self.result.before_path[0] = self.store.layers[0].get(self.index);
                        self.result.after_path[0] = self.value.*;
                        self.store.layers[0].update(&[_]Hash{self.value.*}, self.index);

                        // If have a dependent, we can schedule now that we've been scheduled.
                        if (self.next) |t| {
                            if (self.pool) |p| {
                                p.schedule(ThreadPool.Batch.from(&t.task));
                            }
                        }

                        continue;
                    }

                    const to_layer = &self.store.layers[li];
                    const to_idx = self.index >> @truncate(li);

                    try to_layer.ensureCapacity(to_idx);
                    to_layer.size = @max(to_layer.size, to_idx);

                    const dst = &to_layer.data[to_idx];

                    if (li < depth - 1) {
                        self.result.before_path[li] = to_layer.get(to_idx);
                    } else {
                        self.result.root_before = to_layer.get(to_idx);
                    }

                    compressFn(&lhs, &rhs, dst);

                    // printStruct(.{ .li = li, .lhs = lhs.*, .rhs = rhs.*, .dst = dst.* });

                    if (li < depth - 1) {
                        const is_right = to_idx & 1 == 1;
                        if (!is_right) {
                            lhs = dst.*;
                            rhs = to_layer.get(to_idx + 1);
                            self.result.sibling_path[li] = rhs;
                        } else {
                            lhs = to_layer.get(to_idx - 1);
                            rhs = dst.*;
                            self.result.sibling_path[li] = lhs;
                        }
                        self.result.after_path[li] = dst.*;
                    } else {
                        // printStruct(.{ .li = li, .lhs = lhs.*, .rhs = rhs.*, .dst = dst.* });
                        self.result.root_after = to_layer.get(to_idx);
                    }
                }

                // std.debug.print("index {} setting level {}\n", .{ self.index, depth });
                self.level.store(depth, .release);
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            store: Store,
            pool: ?*ThreadPool,
        ) !Self {
            return Self{
                .allocator = allocator,
                .store = store,
                .pool = pool,
            };
        }

        pub fn deinit(self: *Self) void {
            self.store.deinit();
        }

        pub fn root(self: *Self) Hash {
            return self.store.layers[depth - 1].get(0);
        }

        pub fn size(self: *Self) usize {
            return self.store.layers[0].size;
        }

        pub fn getSiblingPath(self: *Self, index: Index) HashPath {
            var result: HashPath = undefined;
            var i = index;
            for (0..depth - 1) |li| {
                const sibling_index = if (i & 0x1 == 0) i + 1 else i - 1;
                result[li] = self.store.layers[li].get(sibling_index);
                i = sibling_index >> 1;
            }
            return result;
        }

        /// Appends a contiguous set of leaves to the end of the tree.
        pub fn append(self: *Self, leaves: []const Hash) !void {
            try self.update(&.{.{ .index = self.store.layers[0].size, .hashes = leaves }});
        }

        /// Batch updates a set of leaves in the tree.
        /// Each update could be a single value, or a range of values (subtree insertion).
        /// This is the fastest algorithm when intermediate witness data is not required.
        /// Individual compressions are scheduled on the thread pool, and we proceed layer by layer.
        pub fn update(self: *Self, updates: []const MerkleUpdate) !void {
            // TODO: Parallelise?
            // var t = try std.time.Timer.start();
            var num_to_compress: u64 = 0;
            for (updates) |u| {
                var l0_start = u.index;
                var l0_end = l0_start + u.hashes.len;
                l0_start -= l0_start & 1;
                l0_end += l0_end & 1;
                num_to_compress += (l0_end - l0_start) / 2;
                self.store.layers[0].update(u.hashes, u.index);
            }
            if (num_to_compress == 0) {
                return;
            }
            var tasks = try std.ArrayList(CompressTask).initCapacity(self.allocator, num_to_compress);
            defer tasks.deinit();
            // std.debug.print("Update prep took: {}us\n", .{t.read() / 1000});

            for (1..self.store.layers.len) |li| {
                try self.applyUpdates(updates, li, &tasks);
            }
        }

        /// Perform rehashing for a set of updates at a given layer index.
        /// Assumes that the layer below has already been updated.
        fn applyUpdates(self: *Self, updates: []const MerkleUpdate, li: usize, tasks: *std.ArrayList(CompressTask)) !void {
            var counter = std.atomic.Value(u64).init(0);
            tasks.clearRetainingCapacity();
            var batch = ThreadPool.Batch{};

            for (updates) |u| {
                const to_layer = &self.store.layers[li];
                const from_layer = &self.store.layers[li - 1];
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
                try to_layer.ensureCapacity(to_end);
                to_layer.size = @max(to_layer.size, to_end);
                const from = from_layer.data[from_start..from_end];
                const to = to_layer.data[to_start..to_end];

                for (0..to.len) |i| {
                    const lhs = &from[i * 2];
                    const rhs_index = i * 2 + 1;
                    const rhs = if (from.len == 1 or from[rhs_index].is_zero())
                        &from_layer.empty_hash
                    else
                        &from[rhs_index];
                    const dst = &to[i];

                    _ = counter.fetchAdd(1, .acquire);
                    const t = CompressTask{
                        .cnt = &counter,
                        .lhs = lhs,
                        .rhs = rhs,
                        .dst = dst,
                        .task = ThreadPool.Task{ .callback = CompressTask.onSchedule },
                    };
                    try tasks.append(t);
                    batch.push(ThreadPool.Batch.from(&tasks.items[tasks.items.len - 1].task));
                }
            }

            if (self.pool) |p| {
                p.schedule(batch);
            } else {
                for (tasks.items) |*t| CompressTask.onSchedule(&t.task);
            }

            // Spin waiting for all jobs to complete.
            while (counter.load(.acquire) > 0) {
                std.atomic.spinLoopHint();
            }

            try self.flush();
        }

        /// Ensures all data updates are flushed to whatever backs the store.
        fn flush(self: *Self) !void {
            try self.store.flush();
        }

        pub fn updateAndGetWitness(self: *Self, updates: []const IndividualUpdate) ![]IndividualUpdateResult {
            var tasks = try std.ArrayList(IndividualUpdateTask).initCapacity(self.allocator, updates.len);
            try tasks.resize(tasks.capacity);
            defer tasks.deinit();

            var result = try std.ArrayList(IndividualUpdateResult).initCapacity(self.allocator, updates.len);
            try result.resize(result.capacity);
            defer result.deinit();

            for (updates, 0..) |*u, i| {
                tasks.items[i] = IndividualUpdateTask{
                    .prev = if (i > 0) &tasks.items[i - 1] else null,
                    .next = if (i < updates.len - 1) &tasks.items[i + 1] else null,
                    .index = u.index,
                    .store = &self.store,
                    .level = std.atomic.Value(u64).init(0),
                    .result = &result.items[i],
                    .task = ThreadPool.Task{ .callback = IndividualUpdateTask.onSchedule },
                    .value = &u.value,
                    .pool = if (self.pool) |p| p else null,
                };
            }

            if (self.pool) |p| {
                // Schedule the first update. Each update schedules the next.
                p.schedule(ThreadPool.Batch.from(&tasks.items[0].task));
            } else {
                for (tasks.items) |*t| IndividualUpdateTask.onSchedule(&t.task);
            }

            // Spin waiting for all jobs to complete.
            while (tasks.items[tasks.items.len - 1].level.load(.acquire) < depth) {
                // std.atomic.spinLoopHint();
                std.Thread.yield() catch unreachable;
            }

            try self.flush();
            return result.toOwnedSlice();
        }
    };
}

pub fn MerkleTreeMem(depth: usize, compressFn: hash.HashFunc) type {
    return struct {
        const Tree = MerkleTree(depth, MemStore(depth, compressFn), compressFn);
        pub fn init(
            allocator: std.mem.Allocator,
            pool: ?*ThreadPool,
        ) !Tree {
            return Tree.init(
                allocator,
                try MemStore(depth, compressFn).init(allocator),
                pool,
            );
        }
    };
}

pub fn MerkleTreeDb(depth: usize, compressFn: hash.HashFunc) type {
    return struct {
        const Tree = MerkleTree(depth, MmapStore(depth, compressFn), compressFn);
        pub fn init(
            allocator: std.mem.Allocator,
            db_path: []const u8,
            pool: ?*ThreadPool,
            ephemeral: bool,
            erase: bool,
        ) !Tree {
            return Tree.init(
                allocator,
                try MmapStore(depth, compressFn).init(allocator, db_path, ephemeral, erase),
                pool,
            );
        }
    };
}

// fn printStruct(s: anytype) void {
//     const stderr = std.io.getStdErr().writer();
//     formatStruct(s, stderr) catch unreachable;
//     stderr.print("\n", .{}) catch unreachable;
// }

test "merkle tree db/mem consistency" {
    const allocator = std.heap.page_allocator;
    const depth = 40;
    const num = 1024;
    const threads = @min(try std.Thread.getCpuCount(), 64);
    const data_dir = "./data/merkle_tree_consistency";
    defer std.fs.cwd().deleteTree(data_dir) catch unreachable;

    var pool = ThreadPool.init(.{ .max_threads = threads });
    defer {
        pool.shutdown();
        pool.deinit();
    }

    var mem_tree = try MerkleTreeMem(depth, hash.poseidon2).init(allocator, &pool);
    defer mem_tree.deinit();

    var db_tree = try MerkleTreeDb(depth, hash.poseidon2).init(allocator, data_dir, &pool, false, true);
    defer db_tree.deinit();

    var values = try std.ArrayListAligned(Hash, 32).initCapacity(allocator, num);
    defer values.deinit();
    try values.resize(values.capacity);
    for (values.items, 1..) |*v, i| {
        v.* = Fr.from_int(i);
    }

    {
        try mem_tree.append(values.items);
        try db_tree.append(values.items);
        try std.testing.expect(mem_tree.root().eql(db_tree.root()));
    }

    {
        var updates = try std.ArrayList(MerkleUpdate).initCapacity(allocator, num);
        defer updates.deinit();
        for (0..num) |i| {
            try updates.append(.{ .index = i, .hashes = values.items[i .. i + 1] });
        }
        try db_tree.update(updates.items);
        try std.testing.expect(mem_tree.root().eql(db_tree.root()));
    }
}

test "merkle tree bench" {
    const allocator = std.heap.page_allocator;
    const depth = 40;
    const num = 1024 * 1024;
    const threads = @min(try std.Thread.getCpuCount(), 64);
    const data_dir = "./data/merkle_tree_bench";
    defer std.fs.cwd().deleteTree(data_dir) catch unreachable;

    var pool = ThreadPool.init(.{ .max_threads = threads });
    defer {
        pool.shutdown();
        pool.deinit();
    }

    var merkle_tree = try MerkleTreeDb(depth, hash.poseidon2).init(allocator, data_dir, &pool, false, true);
    defer merkle_tree.deinit();

    std.debug.print("Benching: size: {}, threads: {}\n", .{ num, threads });

    var values = try std.ArrayListAligned(Hash, 32).initCapacity(allocator, num);
    defer values.deinit();
    try values.resize(values.capacity);
    for (values.items, 1..) |*v, i| {
        v.* = Fr.from_int(i);
    }

    var t = try std.time.Timer.start();

    {
        try merkle_tree.append(values.items);
        const took = t.read();
        std.debug.print("Inserted {} entries in {}ms {d:.0}/s\n", .{
            values.items.len,
            t.read() / 1_000_000,
            @as(f64, @floatFromInt(values.items.len)) / (@as(f64, @floatFromInt(took)) / 1_000_000_000),
        });
        std.debug.print("Root: {x}\n", .{merkle_tree.root()});
    }

    {
        var updates = try std.ArrayList(MerkleUpdate).initCapacity(allocator, num);
        defer updates.deinit();
        for (0..num) |i| {
            try updates.append(.{ .index = i, .hashes = values.items[i .. i + 1] });
        }
        t.reset();
        try merkle_tree.update(updates.items);
        const took = t.read();
        std.debug.print("Updated {} entries in {}ms {d:.0}/s\n", .{
            updates.items.len,
            took / 1_000_000,
            @as(f64, @floatFromInt(updates.items.len)) / (@as(f64, @floatFromInt(took)) / 1_000_000_000),
        });
        std.debug.print("Root: {x}\n", .{merkle_tree.root()});
    }

    if (num == 65536) {
        const expected = Fr.from_int(0x13352cbc749b6262990ed07a2b145229ed5aefecac08070d462b651c7fae28ad);
        try std.testing.expect(merkle_tree.root().eql(expected));
    }

    const sib_0 = merkle_tree.getSiblingPath(0);
    const sib_7 = merkle_tree.getSiblingPath(7);

    try std.testing.expect(!sib_0[2].eql(sib_7[2]));
    try std.testing.expect(sib_0[3].eql(sib_7[3]));
}

test "merkle tree individual update bench" {
    const allocator = std.heap.page_allocator;
    const depth = 40;
    const num = 1024 * 1024;
    const threads = @min(try std.Thread.getCpuCount(), 64);
    const data_dir = "./data/merkle_tree_indiv_update_bench";
    defer std.fs.cwd().deleteTree(data_dir) catch unreachable;

    var pool = ThreadPool.init(.{ .max_threads = threads });
    defer {
        pool.shutdown();
        pool.deinit();
    }

    var merkle_tree = try MerkleTreeDb(depth, hash.poseidon2).init(allocator, data_dir, &pool, false, true);
    defer merkle_tree.deinit();

    std.debug.print("Benching: size: {}, threads: {}\n", .{ num, threads });

    var updates = try std.ArrayList(IndividualUpdate).initCapacity(allocator, num);
    defer updates.deinit();
    try updates.resize(updates.capacity);
    for (updates.items, 0..) |*v, i| {
        v.index = i;
        v.value = Fr.from_int(i + 1);
    }

    var t = try std.time.Timer.start();
    const r = try merkle_tree.updateAndGetWitness(updates.items);
    defer allocator.free(r);
    const took = t.read();
    std.debug.print("Update with witness {} entries in {}ms {d:.0}/s\n", .{
        updates.items.len,
        took / 1_000_000,
        @as(f64, @floatFromInt(updates.items.len)) / (@as(f64, @floatFromInt(took)) / 1_000_000_000),
    });

    std.debug.print("Root: {x}\n", .{merkle_tree.root()});

    // Sanity check the witness results. Only the first 32, we don't have all day.
    for (r[0..32]) |result| {
        var h = result.before_path[0];
        for (&result.before_path, &result.sibling_path, 0..) |*bh, *sh, li| {
            try std.testing.expect(h.eql(bh.*));

            if ((result.index >> @truncate(li)) & 1 == 0) {
                hash.poseidon2(&h, sh, &h);
            } else {
                hash.poseidon2(sh, &h, &h);
            }
        }
        try std.testing.expect(h.eql(result.root_before));

        h = result.after_path[0];
        for (&result.after_path, &result.sibling_path, 0..) |*bh, *sh, li| {
            try std.testing.expect(h.eql(bh.*));

            if ((result.index >> @truncate(li)) & 1 == 0) {
                hash.poseidon2(&h, sh, &h);
            } else {
                hash.poseidon2(sh, &h, &h);
            }
        }
        try std.testing.expect(h.eql(result.root_after));
    }
}
