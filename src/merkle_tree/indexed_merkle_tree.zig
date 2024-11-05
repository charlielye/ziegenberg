const std = @import("std");
const lmdb = @import("lmdb");
const mt = @import("./merkle_tree.zig");
const Fr = @import("../bn254/fr.zig").Fr;

const Leaf = struct {
    value: Fr,
    next_index: u64,
};

/// Adds a btree (lmdb) structure for storing ordered leaf -> pre-image mappings.
/// These can then be appended/updated in the underlying tree.
pub fn IndexedMerkleTree(depth: u6) type {
    return struct {
        const Self = @This();
        const MerkleTree = mt.MerkleTree(depth);
        const Hash = mt.Hash;
        tree: MerkleTree,
        lmdb_env: lmdb.Environment,

        pub fn init(allocator: std.mem.Allocator, db_path: []const u8, threads: u8, erase: bool) !Self {
            if (erase) {
                try std.fs.cwd().deleteTree(db_path);
            }

            try std.fs.cwd().makePath(db_path);

            const lmdb_env = try lmdb.Environment.init(@ptrCast(db_path.ptr), .{});
            const tree = try MerkleTree.init(allocator, db_path, threads, false);

            return .{
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

            for (values, self.tree.size()..) |v, idx| {
                // Find the existing, or nearest lower leaf.
                var c = try txn.cursor();
                try c.seek(v.to_raw_buf());
                const e = try c.getCurrentEntry();

                // If this entry already exists, skip.
                if (std.mem.eql(u8, e.key, v.to_raw_buf())) {
                    continue;
                }

                try txn.set(v.to_raw_buf(), std.mem.asBytes(&idx));
            }
            try txn.commit();

            try self.tree.append(values);
        }
    };
}

test "indexed merkle tree" {
    const allocator = std.heap.page_allocator;
    var tree = try IndexedMerkleTree(40).init(allocator, "indexed_merkle_tree_data", 0, true);
    defer tree.deinit();
    try tree.add(&[_]Fr{Fr.random()});
}
