const std = @import("std");
const io = @import("./io.zig");
const Fr = @import("../bn254/fr.zig").Fr;
const bincode = @import("../bincode/bincode.zig");

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

    pub fn initFromPath(allocator: std.mem.Allocator, path: []const u8) !WitnessMap {
        var result = WitnessMap.init(allocator);
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var decom = std.compress.gzip.decompressor(file.reader());
        try result.readWitnesses(allocator, true, decom.reader());
        return result;
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

    pub fn printWitnesses(self: *const WitnessMap, binary: bool) !void {
        const stdout = std.io.getStdOut().writer();
        try writeWitnesses(self, binary, stdout);
    }

    pub fn writeWitnesses(self: *const WitnessMap, binary: bool, writer: anytype) !void {
        var keys = try self.allocator.alloc(u32, self.inner.count());
        defer self.allocator.free(keys);

        var index: usize = 0;
        var it = self.inner.iterator();
        while (it.next()) |entry| {
            keys[index] = entry.key_ptr.*;
            index += 1;
        }

        std.mem.sort(u32, keys, {}, std.sort.asc(u32));

        if (binary) {
            var witnesses = try std.ArrayList(io.WitnessEntry).initCapacity(self.allocator, keys.len);
            defer witnesses.deinit();

            for (keys) |key| {
                const value = self.inner.get(key) orelse unreachable;
                try witnesses.append(.{ .index = key, .value = value.to_int() });
            }

            var out = [_]io.StackItem{.{ .index = 0, .witnesses = witnesses.items }};
            const out2: []io.StackItem = &out;
            try bincode.serialize(writer, out2);
        } else {
            for (keys) |key| {
                const value = self.inner.get(key) orelse unreachable;
                try writer.print("{}: {x}\n", .{ key, value });
            }
        }
    }

    fn readWitnesses(self: *WitnessMap, allocator: std.mem.Allocator, binary: bool, reader: anytype) !void {
        if (binary) {
            const items = try bincode.deserializeAlloc(reader, allocator, []io.StackItem, false);
            if (items.len != 1 or items[0].witnesses.len == 0) {
                return error.InvalidWitnessData;
            }
            for (items[0].witnesses) |entry| {
                const witness = entry.index;
                const value = Fr.from_int(entry.value);
                try self.put(witness, value);
            }
        }
    }
};
