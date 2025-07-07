const std = @import("std");

// Represents a single parameter in a foreign call.
// Can be a single value, or an array of values.
// When an array, it can represent plain array, or structured data types.
pub const ForeignCallParam = union(enum) {
    Single: u256,
    Array: []ForeignCallParam,

    pub fn eql(a: ForeignCallParam, b: ForeignCallParam) bool {
        if (a == .Single and b == .Single) {
            return a.Single == b.Single;
        } else if (a == .Array and b == .Array) {
            if (a.Array.len != b.Array.len) return false;
            for (a.Array, b.Array) |ae, be| {
                if (!ForeignCallParam.eql(ae, be)) return false;
            }
            return true;
        } else {
            return false;
        }
    }

    pub fn sliceEql(a: []ForeignCallParam, b: []ForeignCallParam) bool {
        if (a.len != b.len) return false;
        for (a, b) |ae, be| {
            if (!ForeignCallParam.eql(ae, be)) return false;
        }
        return true;
    }

    pub fn deepCopy(self: ForeignCallParam, allocator: std.mem.Allocator) !ForeignCallParam {
        switch (self) {
            .Single => return ForeignCallParam{ .Single = self.Single },
            .Array => {
                const len = self.Array.len;
                var new_array = try allocator.alloc(ForeignCallParam, len);
                for (self.Array, 0..) |elem, i| {
                    new_array[i] = try elem.deepCopy(allocator);
                }
                return ForeignCallParam{ .Array = new_array };
            },
        }
    }

    pub fn sliceDeepCopy(slice: []const ForeignCallParam, allocator: std.mem.Allocator) ![]ForeignCallParam {
        var new_slice = try allocator.alloc(ForeignCallParam, slice.len);
        for (slice, 0..) |param, i| {
            new_slice[i] = try param.deepCopy(allocator);
        }
        return new_slice;
    }

    pub fn format(
        self: ForeignCallParam,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Single => |value| try writer.print("0x{x}", .{value}),
            .Array => |array| {
                try writer.writeAll("[");
                for (array, 0..) |elem, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try elem.format("", .{}, writer);
                }
                try writer.writeAll("]");
            },
        }
    }

    pub fn flatten(self: ForeignCallParam, allocator: std.mem.Allocator) ![]u256 {
        const total_size: usize = self.countFlattenedElements();
        const result = try allocator.alloc(u256, total_size);
        var idx: usize = 0;
        self.flattenParam(result, &idx);
        return result;
    }

    fn countFlattenedElements(self: ForeignCallParam) usize {
        switch (self) {
            .Single => return 1,
            .Array => |arr| {
                var count: usize = 0;
                for (arr) |elem| {
                    count += elem.countFlattenedElements();
                }
                return count;
            },
        }
    }

    fn flattenParam(self: ForeignCallParam, out: []u256, idx: *usize) void {
        switch (self) {
            .Single => |val| {
                out[idx.*] = val;
                idx.* += 1;
            },
            .Array => |arr| {
                for (arr) |elem| {
                    flattenParam(elem, out, idx);
                }
            },
        }
    }
};
