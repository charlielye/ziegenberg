const std = @import("std");
const lmdb = @import("lmdb");
const mt = @import("./merkle_tree.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const bincode = @import("../bincode/bincode.zig");

/// From clients perspective, this presents a set of values.
/// You can add to the set, and check if a value is present in the set.
/// The set of values is also recorded within a merkle tree which can be probed for witness data of (non)existence.
/// The leaves of the merkle tree represent a linked list of values, allowing updates via appends and updates.
/// This model is cheaper (shallower trees) than a traditional sparse tree which would need a depth of e.g. 256.
/// Adds a btree (lmdb) structure for storing ordered value -> tree index mappings.
/// The actual leaf nodes in the tree are not the direct value, but of compressed type Leaf, to encode the links.
/// These are required to locate list elements and their pre-images within the merkle tree for updates.
pub fn IndexedMerkleTree(depth: u6) type {
    return struct {
        const Self = @This();
        const MerkleTree = mt.MerkleTree(depth);
        const Hash = mt.Hash;
        const Entry = struct {
            next_value: Hash,
            value: Hash,
            index: u64,
            next_index: u64,

            pub inline fn toBuf(self: *const Entry) [80]u8 {
                var buffer: [80]u8 = undefined;
                var stream = std.io.fixedBufferStream(&buffer);
                bincode.serialize(stream.writer(), self.*) catch unreachable;
                return buffer;
            }
        };
        allocator: std.mem.Allocator,
        tree: MerkleTree,
        lmdb_env: lmdb.Environment,

        pub fn init(allocator: std.mem.Allocator, db_path: []const u8, threads: u8, erase: bool) !Self {
            if (erase) {
                try std.fs.cwd().deleteTree(db_path);
            }

            try std.fs.cwd().makePath(db_path);

            const lmdb_env = try lmdb.Environment.init(@ptrCast(db_path.ptr), .{});
            var tree = try MerkleTree.init(allocator, db_path, threads, false);

            // Ensure our 0 leaf is present.
            const txn = try lmdb.Transaction.init(lmdb_env, .{ .mode = .ReadWrite });
            errdefer txn.abort();
            const zero_entry = std.mem.zeroes(Entry);
            try txn.set(&Fr.zero.to_buf(), std.mem.asBytes(&zero_entry));
            try txn.commit();
            try tree.append(&[_]Hash{Hash.zero});

            std.debug.print("sizeof entry {}\n", .{@sizeOf(Entry)});
            return .{
                .allocator = allocator,
                .tree = tree,
                .lmdb_env = lmdb_env,
            };
        }

        pub fn deinit(self: *Self) void {
            self.tree.deinit();
            self.lmdb_env.deinit();
        }

        pub fn add(self: *Self, values: []const Hash) !void {
            const txn = try lmdb.Transaction.init(self.lmdb_env, .{ .mode = .ReadWrite });
            errdefer txn.abort();

            // Prealloc our tree updates. 1 update per value low-leaf update, plus 1 batch insert.
            var updates = try std.ArrayList(mt.MerkleUpdate).initCapacity(self.allocator, values.len + 1);
            defer updates.deinit();

            for (values, self.tree.size()..) |v, idx| {
                const key: []const u8 = &v.to_buf();

                // Find the existing, or nearest lower leaf.
                var c = try txn.cursor();
                std.debug.print("seeking to key {x}...\n", .{key});
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
                var prev_value = try c.getCurrentValue();
                std.debug.print("low element: key {any} value {any} len {}\n", .{ prev, prev_value, prev_value.len });
                var prev_entry = bincode.deserializeBuffer(Entry, &prev_value);

                const new_entry = Entry{
                    .index = idx,
                    // .preimage = .{
                    .next_index = prev_entry.next_index,
                    .next_value = prev_entry.next_value,
                    .value = v,
                    // },
                };

                // Update the entry.
                std.debug.print("before update {}\n", .{prev_entry});
                prev_entry.next_index = idx;
                prev_entry.next_value = v;

                std.debug.print("updating key {any} value {any}\n", .{ prev, prev_entry });
                std.debug.print("inserting key {any} value {any}\n", .{ key, new_entry });

                try txn.set(prev, &prev_entry.toBuf());
                try txn.set(key, &new_entry.toBuf());
            }
            try txn.commit();

            try updates.append(.{ .index = self.tree.size(), .hashes = values });
            try self.tree.update(updates.items);

            std.debug.print("done.\n\n", .{});
        }
    };
}

test "indexed merkle tree" {
    const allocator = std.heap.page_allocator;
    const depth = 40;
    const num = 128;

    var tree = try IndexedMerkleTree(depth).init(allocator, "indexed_merkle_tree_data", 0, true);
    defer tree.deinit();

    var values = try std.ArrayListAligned(mt.Hash, 32).initCapacity(allocator, num);
    defer values.deinit();
    try values.resize(values.capacity);
    for (values.items, 0..) |*v, i| {
        v.* = Fr.from_int(i);
    }

    try tree.add(values.items[3..4]);
    try tree.add(values.items[1..2]);
    try tree.add(values.items[2..3]);
    try tree.add(values.items[5..6]);
}
