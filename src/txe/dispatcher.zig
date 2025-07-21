const std = @import("std");
const F = @import("../../bn254/fr.zig").Fr;
const bvm = @import("../bvm/package.zig");
const TxeImpl = @import("./txe_impl.zig").TxeImpl;

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    mocker: bvm.foreign_call.Mocker,
    txe_impl: *TxeImpl,

    pub fn init(allocator: std.mem.Allocator, txe_impl: *TxeImpl) !Dispatcher {
        return .{
            .allocator = allocator,
            .mocker = bvm.foreign_call.Mocker.init(allocator),
            .txe_impl = txe_impl,
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.mocker.deinit();
    }

    pub fn handleForeignCall(self: *Dispatcher, mem: *bvm.memory.Memory, fc: *const bvm.io.ForeignCall) !void {
        // This arena allocator is for the transient memory needed for processing the call.
        // In the actual call handlers you have access to self.allocator for longer lived data.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Extract from the VM memory, a slice of ForeignCallParam's, one per argument.
        const params = try bvm.foreign_call.marshal.extractParams(arena.allocator(), mem, fc);

        // First see if this is a mock setup call, or a mocked call.
        if (try self.mocker.handleForeignCall(arena.allocator(), mem, fc, params)) {
            return;
        }

        // Otherwise attempt to dispatch on txe.
        if (try bvm.foreign_call.structDispatcher(self.txe_impl, self.allocator, mem, fc, params)) {
            return;
        }

        // We didn't find a matching function. Fallback on default foreign call handler.
        try bvm.foreign_call.marshal.handleForeignCall(arena.allocator(), mem, fc, params);
    }
};
