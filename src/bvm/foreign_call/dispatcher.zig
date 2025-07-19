const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");
const Mocker = @import("./mocker.zig").Mocker;
const Txe = @import("./txe.zig").Txe;
const structDispatcher = @import("./struct_dispatcher.zig").structDispatcher;

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    txe: Txe,
    mocker: Mocker,

    pub fn init(allocator: std.mem.Allocator) !Dispatcher {
        return .{
            .allocator = allocator,
            .txe = try Txe.init(allocator, "data/contracts"),
            .mocker = Mocker.init(allocator),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.txe.deinit();
        self.mocker.deinit();
    }

    pub fn handleForeignCall(self: *Dispatcher, mem: *Memory, fc: *const io.ForeignCall) !void {
        // This arena allocator is for the transient memory needed for processing the call.
        // In the actual call handlers you have access to self.allocator for longer lived data.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Extract from the VM memory, a slice of ForeignCallParam's, one per argument.
        const params = try foreign_call.extractParams(arena.allocator(), mem, fc);

        // First see if this is a mock setup call, or a mocked call.
        if (try self.mocker.handleForeignCall(arena.allocator(), mem, fc, params)) {
            return;
        }

        // Otherwise attempt to dispatch on txe.
        if (try self.txe.handleForeignCall(arena.allocator(), mem, fc, params, self)) {
            return;
        }

        // We didn't find a matching function. Fallback on default foreign call handler.
        try foreign_call.handleForeignCall(arena.allocator(), mem, fc, params);
    }
};
