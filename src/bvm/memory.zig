const std = @import("std");
const fieldOps = @import("../blackbox/field.zig");
const io = @import("io.zig");

/// Provides a view of machine memory.
/// The memory view is a contiguous range of slots.
/// Each slot can hold a field, or an integer of particular width.
/// In this simple implementation each slot is 32 bytes regardless of its type.
/// One could imagine a more efficient implementation which separated specific types and used indexes to resolve.
pub const Memory = struct {
    allocator: std.mem.Allocator,
    memory: []align(4096) u256,
    max_slot_set: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, num_slots: usize) !Memory {
        return .{
            .allocator = allocator,
            .memory = try allocator.alignedAlloc(u256, 4096, num_slots),
        };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.memory);
    }

    pub fn dumpMem(self: *Memory, offset: usize, n: usize) void {
        for (offset..offset + n) |i| {
            var f align(32) = self.memory[i];
            fieldOps.bn254_fr_normalize(@ptrCast(&f));
            std.debug.print("{:0>3}: 0x{x:0>64}\n", .{ i, f });
        }
    }

    pub inline fn resolveSlot(self: *Memory, mem_address: io.MemoryAddress) usize {
        return mem_address.resolve(self.memory);
    }

    pub inline fn getSlot(self: *Memory, mem_address: io.MemoryAddress) u256 {
        return self.memory[mem_address.resolve(self.memory)];
    }

    pub inline fn getSlotAtIndex(self: *Memory, index: usize) u256 {
        return self.memory[index];
    }

    pub inline fn getSlotAddrAtIndex(self: *Memory, index: usize) *u256 {
        return &self.memory[index];
    }

    pub inline fn getSlotAddr(self: *Memory, mem_address: io.MemoryAddress) *align(32) u256 {
        return &self.memory[mem_address.resolve(self.memory)];
    }

    pub inline fn getIndirectSlot(self: *Memory, mem_address: io.MemoryAddress) u256 {
        return self.memory[@truncate(self.getSlot(mem_address))];
    }

    pub inline fn getIndirectSlotAddr(self: *Memory, mem_address: io.MemoryAddress) *align(32) u256 {
        return &self.memory[@truncate(self.getSlot(mem_address))];
    }

    pub inline fn setSlot(self: *Memory, mem_address: io.MemoryAddress, value: u256) void {
        self.setSlotAtIndex(mem_address.resolve(self.memory), value);
    }

    pub inline fn setSlotAtIndex(self: *Memory, index: usize, value: u256) void {
        if (self.max_slot_set < index) {
            self.max_slot_set = index;
        }
        self.memory[index] = value;
    }

    /// Caller should free returned slice.
    pub fn getMemSlice(self: *Memory, comptime T: type, offset: usize, n: usize) []const T {
        const slice = self.allocator.alloc(T, n) catch unreachable;
        for (self.memory[offset .. offset + n], 0..) |e, i| slice[i] = @intCast(e);
        return slice;
    }
};
