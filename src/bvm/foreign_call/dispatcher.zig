const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const marshal = @import("marshal.zig");
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");
const Mocker = @import("./mocker.zig").Mocker;
const structDispatcher = @import("./struct_dispatcher.zig").structDispatcher;

pub const ForeignCallDispatcher = struct {
    context: *anyopaque,
    handleForeignCallFn: *const fn (self: *anyopaque, mem: *Memory, fc: *const io.ForeignCall) anyerror!void,

    pub fn handleForeignCall(self: *ForeignCallDispatcher, mem: *Memory, fc: *const io.ForeignCall) !void {
        return self.handleForeignCallFn(self.context, mem, fc);
    }
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    mocker: Mocker,

    pub fn fcDispatcher(self: *Dispatcher) ForeignCallDispatcher {
        return .{
            .context = self,
            .handleForeignCallFn = handleForeignCall,
        };
    }

    pub fn init(allocator: std.mem.Allocator) !Dispatcher {
        return .{
            .allocator = allocator,
            .mocker = Mocker.init(allocator),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.mocker.deinit();
    }

    pub fn handleForeignCall(context: *anyopaque, mem: *Memory, fc: *const io.ForeignCall) !void {
        const self: *Dispatcher = @alignCast(@ptrCast(context));

        // This arena allocator is for the transient memory needed for processing the call.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Extract from the VM memory, a slice of ForeignCallParam's, one per argument.
        const params = try marshal.extractParams(arena.allocator(), mem, fc);

        // First see if this is a mock setup call, or a mocked call.
        if (try self.mocker.handleForeignCall(arena.allocator(), mem, fc, params)) {
            return;
        }

        // We didn't find a matching function. Fallback on default foreign call handler.
        std.debug.print("Foreign call not found in txe or mocker: '{s}'\n", .{fc.function});
        try marshal.handleForeignCall(arena.allocator(), mem, fc, params);
    }
};
