const std = @import("std");
const formatStruct = @import("../bvm/io.zig").formatStruct;
const Fr = @import("../bn254/fr.zig").Fr;
const poseidon2Hash = @import("../poseidon2/poseidon2.zig").hash;
const ThreadPool = @import("../thread/thread_pool.zig").ThreadPool;

const HASH_SIZE = 32;
pub const Hash = Fr;

/// Our basic hash compression function. We use poseidon2.
inline fn compressTask(lhs: *const Hash, rhs: *const Hash, dst: *Hash) void {
    dst.* = poseidon2Hash(&[_]Fr{ lhs.*, rhs.* });
}

/// A task object for scheduling onto the thread pool that performs a hash compression.
/// This is used for the simple case of updating a collection of leaves, where no intermediate state is needed.
/// We can layer by layer, schedule the compressions for that layer, wait for completion, and advance up a layer.
const CompressTask = struct {
    task: ThreadPool.Task,
    lhs: *Hash,
    rhs: *Hash,
    dst: *Hash,
    cnt: *std.atomic.Value(u64),

    pub fn onSchedule(task: *ThreadPool.Task) void {
        const self: *CompressTask = @fieldParentPtr("task", task);
        compressTask(self.lhs, self.rhs, self.dst);
        _ = self.cnt.fetchSub(1, .release);
    }
};

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
pub fn MerkleTree(depth: u6) type {
    return struct {
        const Self = @This();
        const Index = std.meta.Int(.unsigned, depth);
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
        db_path: []const u8,
        layers: [depth]Layer,
        pool: ?ThreadPool,

        /// A task object for scheduling individual updates that return witness data needed for proving.
        /// We need each intermediate hash path to reflect the state between each update.
        /// In this situation only one task at a time can be updating a given layer to ensure we do not overlap.
        /// The task list is double linked.
        /// This allows a task to wait until its predecessor has advanced to a layer above before starting.
        /// It also allows a task to schedule it's successor once it has been scheduled (to avoid deadlock).
        const IndividualUpdateTask = struct {
            task: ThreadPool.Task,
            index: usize,
            value: *const Hash,
            level: std.atomic.Value(u64),
            next: ?*IndividualUpdateTask,
            prev: ?*IndividualUpdateTask,
            layers: []Layer,
            result: *IndividualUpdateResult,
            pool: ?*ThreadPool,

            pub fn onSchedule(task: *ThreadPool.Task) void {
                const self: *IndividualUpdateTask = @fieldParentPtr("task", task);

                // If have a dependent, we can schedule now that we've been scheduled.
                if (self.next) |t| {
                    self.pool.?.schedule(ThreadPool.Batch.from(&t.task));
                }

                self.result.index = self.index;

                for (0..depth) |li| {
                    // Announce our new level.
                    std.debug.print("index {} setting level to {}\n", .{ self.index, li });
                    self.level.store(li, .release);

                    // Ensure the update before us has advanced to a higher level.
                    if (self.prev) |prev| {
                        while (prev.level.load(.acquire) == self.level.load(.monotonic)) {
                            std.atomic.spinLoopHint();
                        }
                    }
                    std.debug.print("index {} level proceeding {}\n", .{ self.index, li });

                    if (li == 0) {
                        const sib_idx = if (self.index & 1 == 1) self.index - 1 else self.index + 1;
                        self.result.before_path[0] = self.layers[0].data[self.index];
                        self.result.after_path[0] = self.value.*;
                        self.result.sibling_path[0] = self.layers[0].data[sib_idx];
                        self.layers[0].update(&[_]Hash{self.value.*}, self.index);
                        continue;
                    }

                    // const prev = self.prev.?;

                    const to_layer = &self.layers[li];
                    const from_layer = &self.layers[li - 1];
                    const from_idx = self.index >> @truncate(li - 1);
                    const is_right = from_idx & 1;
                    const from_idx_lhs = from_idx - is_right;
                    const from_idx_rhs = if (is_right == 1) from_idx else from_idx + 1;
                    const to_idx = from_idx >> 1;

                    to_layer.size = @max(to_layer.size, to_idx);

                    const lhs = &from_layer.data[from_idx_lhs];
                    const rhs = from_layer.get_ptr(from_idx_rhs);
                    const dst = &to_layer.data[to_idx];

                    if (li < depth - 1) {
                        self.result.before_path[li] = to_layer.get(to_idx);
                    } else {
                        self.result.root_before = to_layer.get(to_idx);
                    }

                    compressTask(lhs, rhs, dst);

                    // printStruct(.{ .li = li, .lhs = lhs.*, .rhs = rhs.*, .dst = dst.* });

                    if (li < depth - 1) {
                        const sib_idx = if (to_idx & 1 == 1) to_idx - 1 else to_idx + 1;
                        self.result.after_path[li] = dst.*;
                        self.result.sibling_path[li] = to_layer.get(sib_idx);
                    } else {
                        printStruct(.{ .li = li, .lhs = lhs.*, .rhs = rhs.*, .dst = dst.* });
                        self.result.root_after = to_layer.get(to_idx);
                    }
                }

                std.debug.print("index {} setting level {}\n", .{ self.index, depth });
                self.level.store(depth, .release);
            }
        };

        pub fn init(allocator: std.mem.Allocator, db_path: []const u8, threads: u8, erase: bool) !Self {
            var tree = Self{
                .allocator = allocator,
                .db_path = db_path,
                .layers = undefined,
                .pool = if (threads > 0) ThreadPool.init(.{ .max_threads = threads }) else null,
            };

            if (erase) {
                try std.fs.cwd().deleteTree(db_path);
            }

            try std.fs.cwd().makePath(db_path);

            var empty_hash = Hash.zero;
            for (0..depth) |layer_index| {
                const max_size = @as(usize, 1) << @truncate(depth - 1 - layer_index);
                tree.layers[layer_index] = try Layer.init(allocator, db_path, layer_index, max_size, empty_hash);
                compressTask(&empty_hash, &empty_hash, &empty_hash);
            }

            return tree;
        }

        pub fn deinit(self: *Self) void {
            if (self.pool) |*p| {
                p.shutdown();
                p.deinit();
            }
            for (self.layers[0..]) |*layer| {
                layer.deinit();
            }
        }

        pub fn root(self: *Self) Hash {
            return self.layers[depth - 1].data[0];
        }

        pub fn size(self: *Self) usize {
            return self.layers[0].size;
        }

        pub fn getSiblingPath(self: *Self, index: Index) HashPath {
            var result: HashPath = undefined;
            var i = index;
            for (0..depth - 1) |li| {
                const sibling_index = if (i & 0x1 == 0) i + 1 else i - 1;
                result[li] = self.layers[li].get(sibling_index);
                i = sibling_index >> 1;
            }
            return result;
        }

        /// Appends a contiguous set of leaves to the end of the tree.
        pub fn append(self: *Self, leaves: []const Hash) !void {
            try self.update(&.{.{ .index = self.layers[0].size, .hashes = leaves }});
        }

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
                self.layers[0].update(u.hashes, u.index);
            }
            var tasks = try std.ArrayList(CompressTask).initCapacity(self.allocator, num_to_compress);
            defer tasks.deinit();
            // std.debug.print("Update prep took: {}us\n", .{t.read() / 1000});

            for (1..self.layers.len) |li| {
                self.applyUpdates(updates, li, &tasks);
            }
        }

        /// Perform rehashing for a set of updates at a given layer index.
        /// Assumes that the layer below has already been updated.
        fn applyUpdates(self: *Self, updates: []const MerkleUpdate, li: usize, tasks: *std.ArrayList(CompressTask)) void {
            var counter = std.atomic.Value(u64).init(0);
            tasks.clearRetainingCapacity();
            var batch = ThreadPool.Batch{};

            for (updates) |u| {
                const to_layer = &self.layers[li];
                const from_layer = &self.layers[li - 1];
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
                const to = to_layer.data[to_start..to_end];

                to_layer.size = @max(to_layer.size, to_end);

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
                    tasks.append(t) catch unreachable;
                    batch.push(ThreadPool.Batch.from(&tasks.items[tasks.items.len - 1].task));
                }
            }

            if (self.pool) |*p| {
                p.schedule(batch);
            } else {
                for (tasks.items) |*t| CompressTask.onSchedule(&t.task);
            }

            // Spin waiting for all jobs to complete.
            while (counter.load(.acquire) > 0) {
                std.atomic.spinLoopHint();
            }
        }

        fn flush(self: *Self) !void {
            for (self.layers[0..]) |*l| try l.flush();
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
                    .layers = &self.layers,
                    .level = std.atomic.Value(u64).init(0),
                    .result = &result.items[i],
                    .task = ThreadPool.Task{ .callback = IndividualUpdateTask.onSchedule },
                    .value = &u.value,
                    .pool = if (self.pool) |*p| p else null,
                };
            }

            if (self.pool) |*p| {
                // Schedule the first update. Each update schedules the next.
                p.schedule(ThreadPool.Batch.from(&tasks.items[0].task));
            } else {
                for (tasks.items) |*t| IndividualUpdateTask.onSchedule(&t.task);
            }

            // Spin waiting for all jobs to complete.
            while (tasks.items[tasks.items.len - 1].level.load(.acquire) < depth) {
                std.atomic.spinLoopHint();
            }

            return result.toOwnedSlice();
        }
    };
}

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
    ) !Layer {
        const layer_filename = try std.fmt.allocPrint(allocator, "{s}/layer_{d:0>2}.dat", .{ base_path, layer_index });
        defer allocator.free(layer_filename);

        const fs = std.fs.cwd();
        var file = try fs.createFile(layer_filename, .{ .read = true, .truncate = false });
        defer file.close();

        // TODO: Capping at 16TB file size (minus one block) to map in (ext4 file size limit).
        // Note xfs doesn't have this limit.
        // There's work to do remap if data exceeds this limit.
        const file_size = @min(max_size * HASH_SIZE, 1024 * 1024 * 1024 * 1024 * 16 - 4096);

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

    pub inline fn get(self: *Layer, at: usize) Hash {
        return if (self.data[at].is_zero()) self.empty_hash else self.data[at];
    }

    pub inline fn get_ptr(self: *Layer, at: usize) *const Hash {
        return if (self.data[at].is_zero()) &self.empty_hash else &self.data[at];
    }

    /// Appends src to the layer, and returns a slice of elements that must be re-hashed up the tree.
    pub fn append(self: *Layer, src: []Hash) void {
        self.update(src, self.size);
    }

    /// Copy src hash slice to at.
    pub fn update(self: *Layer, src: []const Hash, at: usize) void {
        const at_end = at + src.len;
        const to = self.data[at..at_end];
        std.mem.copyForwards(Hash, to, src);
        self.size = @max(at_end, self.size);
    }

    pub fn flush(self: *Layer) !void {
        try std.posix.msync(std.mem.asBytes(self.data.ptr), 4);
    }
};

test "merkle tree init deinit" {
    const allocator = std.heap.page_allocator;
    const depth = 40;
    const threads = 1;
    const data_dir = "./merkle_tree_data";

    var merkle_tree = try MerkleTree(depth).init(allocator, data_dir, threads, true);
    defer merkle_tree.deinit();
}

test "merkle tree bench" {
    const allocator = std.heap.page_allocator;
    const depth = 40;
    const num = 16;
    const threads = @min(try std.Thread.getCpuCount(), 64);
    const data_dir = "./merkle_tree_data";

    var merkle_tree = try MerkleTree(depth).init(allocator, data_dir, threads, true);
    defer merkle_tree.deinit();

    std.debug.print("Benching: size: {}, threads: {}\n", .{ num, threads });

    var values = try std.ArrayListAligned(Hash, 32).initCapacity(allocator, num);
    defer values.deinit();
    try values.resize(values.capacity);
    for (values.items, 1..) |*v, i| {
        v.* = Fr.from_int(i);
    }

    var t = try std.time.Timer.start();
    try merkle_tree.append(values.items);
    try merkle_tree.flush();
    std.debug.print("Inserted {} entries in {}ms\n", .{ values.items.len, t.read() / 1_000_000 });
    std.debug.print("Root: {x}\n", .{merkle_tree.root()});

    var updates = try std.ArrayList(MerkleUpdate).initCapacity(allocator, num);
    for (0..num) |i| {
        try updates.append(.{ .index = i, .hashes = values.items[i .. i + 1] });
    }
    t.reset();
    try merkle_tree.update(updates.items);
    try merkle_tree.flush();
    std.debug.print("Updated {} entries in {}ms\n", .{ values.items.len, t.read() / 1_000_000 });

    std.debug.print("Root: {x}\n", .{merkle_tree.root()});

    if (num == 65536) {
        const expected = Fr.from_int(0x13352cbc749b6262990ed07a2b145229ed5aefecac08070d462b651c7fae28ad);
        try std.testing.expect(merkle_tree.root().eql(expected));
    }

    const sib_0 = merkle_tree.getSiblingPath(0);
    const sib_7 = merkle_tree.getSiblingPath(7);

    try std.testing.expect(!sib_0[2].eql(sib_7[2]));
    try std.testing.expect(sib_0[3].eql(sib_7[3]));
}

// Inserted 134217728 entries in 33558ms
// Root: 0x0500253d2d312f39b8126d9d580290977379927f9321ba9a7fd2dd90ca29db01
// OK
// All 1 tests passed.

// Benching: size: 1048576, threads: 32
// Update prep took: 19733us
// Inserted 1048576 entries in 516ms
// Update prep took: 6051us
// Updated 1048576 entries in 14551ms
// Root: 0x1d8a34206c45ce784581f0d8b0dab54102cd2906217149c6e3562da8d6e63d0b
// OK
// All 1 tests passed.

// 1/1 merkle_tree.merkle_tree.test.merkle tree...
// Benching: size: 1048576, threads: 64
// Update prep took: 19960us
// Inserted 1048576 entries in 317ms
// Update prep took: 6013us
// Updated 1048576 entries in 7965ms
// Root: 0x1d8a34206c45ce784581f0d8b0dab54102cd2906217149c6e3562da8d6e63d0b
// OK
// All 1 tests passed.

// 1/1 merkle_tree.merkle_tree.test.merkle tree...
// Benching: size: 1048576, threads: 128
// Update prep took: 19904us
// Inserted 1048576 entries in 323ms
// Update prep took: 5878us
// Updated 1048576 entries in 7333ms
// Root: 0x1d8a34206c45ce784581f0d8b0dab54102cd2906217149c6e3562da8d6e63d0b
// OK
// All 1 tests passed.

test "merkle tree individual update bench" {
    const allocator = std.heap.page_allocator;
    const depth = 40;
    const num = 16;
    const threads = @min(try std.Thread.getCpuCount(), 64);
    const data_dir = "./merkle_tree_indiv_data";

    var merkle_tree = try MerkleTree(depth).init(allocator, data_dir, threads, true);
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
    try merkle_tree.flush();
    std.debug.print("Update with witness {} entries in {}ms\n", .{ updates.items.len, t.read() / 1_000_000 });

    std.debug.print("Root: {x}\n", .{merkle_tree.root()});

    for (r) |result| {
        std.debug.print("{x} -> {x}\n", .{
            result.root_before,
            result.root_after,
        });
        //     std.debug.print("-------\nidx: {}\nbefore: {x}\nafter: {x}\nsib: {x}\n", .{
        //         result.index,
        //         result.before_path,
        //         result.after_path,
        //         result.sibling_path,
        //     });
    }
}
