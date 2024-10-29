const std = @import("std");
const io = @import("./io.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const serialize = @import("../bincode/bincode.zig").serialize;

const Witness = io.Witness;

pub const WitnessMap = struct {
    allocator: std.mem.Allocator,
    inner: std.AutoHashMap(Witness, Fr),

    pub fn init(allocator: std.mem.Allocator) WitnessMap {
        return WitnessMap{
            .allocator = allocator,
            .inner = std.AutoHashMap(Witness, Fr).init(allocator),
        };
    }

    pub fn deinit(self: *WitnessMap) void {
        self.inner.deinit();
    }

    pub fn get(self: *WitnessMap, witness: Witness) ?Fr {
        return self.inner.get(witness);
    }

    pub fn put(self: *WitnessMap, witness: Witness, value: Fr) !void {
        const r = try self.inner.getOrPut(witness);
        if (r.found_existing) {
            if (!r.value_ptr.eql(value)) {
                return error.UnsatisfiedConstraint;
            }
        } else {
            r.value_ptr.* = value;
        }
    }

    pub fn count(self: *WitnessMap) usize {
        return self.inner.count();
    }

    pub fn printWitnesses(self: *WitnessMap, binary: bool) !void {
        var keys = try self.allocator.alloc(u32, self.inner.count());
        defer self.allocator.free(keys);

        var index: usize = 0;
        var it = self.inner.iterator();
        while (it.next()) |entry| {
            keys[index] = entry.key_ptr.*;
            index += 1;
        }

        std.mem.sort(u32, keys, {}, std.sort.asc(u32));

        var stdout = std.io.getStdOut().writer();
        if (binary) {
            var witnesses = try std.ArrayList(io.WitnessEntry).initCapacity(self.allocator, keys.len);
            defer witnesses.deinit();

            for (keys) |key| {
                const value = self.inner.get(key) orelse unreachable;
                try witnesses.append(.{ .index = key, .value = value.to_int() });
            }

            var out = [_]io.StackItem{.{ .index = 0, .witnesses = witnesses.items }};
            const out2: []io.StackItem = &out;
            try serialize(stdout, out2);
        } else {
            for (keys) |key| {
                const value = self.inner.get(key) orelse unreachable;
                try stdout.print("{}: {x}\n", .{ key, value });
            }
        }
    }
};
