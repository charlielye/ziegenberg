const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const ForeignCallParam = @import("./param.zig").ForeignCallParam;
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");
const marshal = @import("marshal.zig");
const structDispatcher = @import("struct_dispatcher.zig").structDispatcher;

const MockedCall = struct {
    /// The id of the mock, used to update or remove it
    id: usize,
    /// The oracle it's mocking
    name: []const u8,
    /// Optionally match the parameters
    params: ?[]ForeignCallParam,
    /// The parameters with which the mock was last called
    last_called_params: ?[]ForeignCallParam,
    /// The result to return when this mock is called
    result: []ForeignCallParam,
    /// How many times should this mock be called before it is removed
    times_left: ?u64,
    /// How many times this mock was actually called
    times_called: u32,
};

pub const Mocker = struct {
    allocator: std.mem.Allocator,
    mock_id: u64 = 0,
    mock_calls: std.ArrayList(?MockedCall),

    pub fn init(allocator: std.mem.Allocator) Mocker {
        return .{
            .allocator = allocator,
            .mock_calls = std.ArrayList(?MockedCall).init(allocator),
        };
    }

    pub fn deinit(self: *Mocker) void {
        self.mock_calls.deinit();
    }

    /// Dispatch function for foreign calls.
    /// Uses comptime meta foo to marshal data in and out of vm memory, and call functions with the same name on self.
    /// Handler functions arguments and return types must match the layout as described by the foreign call.
    /// The given allocator is used for transient data and is freed by the caller.
    /// Note the use of ForeignCallParam.sliceDeepCopy to copy data that needs to become long-lived into self.allocator.
    pub fn handleForeignCall(
        self: *Mocker,
        allocator: std.mem.Allocator,
        mem: *Memory,
        fc: *const io.ForeignCall,
        params: []ForeignCallParam,
    ) !bool {
        // If the foreign call has been mocked, handle the mock and return.
        for (self.mock_calls.items) |*maybe_call| {
            if (maybe_call.*) |*call| {
                if (std.mem.eql(u8, call.name, fc.function) and
                    (call.params == null or ForeignCallParam.sliceEql(call.params.?, params)))
                {
                    // std.debug.print("Calling mocked function: {s} with params: {any}\n", .{ fc.function, params });
                    std.debug.print("Calling mocked function: {s}\n", .{fc.function});
                    std.debug.print("Destination value types: {any}\n", .{fc.destination_value_types});
                    call.last_called_params = try ForeignCallParam.sliceDeepCopy(params, self.allocator);
                    call.times_called += 1;
                    marshal.marshalForeignCallParam(call.result, mem, fc.destinations, fc.destination_value_types);
                    if (call.times_left) |*left| {
                        left.* -= 1;
                        if (left.* == 0) {
                            maybe_call.* = null;
                        }
                    }
                    return true;
                }
            }
        }

        // Special case function handlers that can't be genericised.
        if (std.mem.eql(u8, "set_mock_returns", fc.function)) {
            std.debug.print("Making foreign call to: set_mock_returns with params: {any}\n", .{params[1..]});
            const id: usize = @intCast(params[0].Single);
            self.mock_calls.items[id].?.result = try ForeignCallParam.sliceDeepCopy(params[1..], self.allocator);
            return true;
        } else if (std.mem.eql(u8, "set_mock_params", fc.function)) {
            std.debug.print("Making foreign call to: set_mock_params\n", .{});
            const id: usize = @intCast(params[0].Single);
            self.mock_calls.items[id].?.params = try ForeignCallParam.sliceDeepCopy(params[1..], self.allocator);
            return true;
        }

        return try structDispatcher(self, allocator, mem, fc, params);
    }

    pub fn create_mock(
        self: *Mocker,
        _: std.mem.Allocator,
        oracle_name: []const u8,
    ) !F {
        std.debug.print("create_mock: {s}\n", .{oracle_name});
        try self.mock_calls.append(.{
            .id = self.mock_id,
            .name = try self.allocator.dupe(u8, oracle_name),
            .params = null,
            .last_called_params = null,
            .result = &[_]ForeignCallParam{},
            .times_left = null,
            .times_called = 0,
        });
        const id = F.from_int(self.mock_id);
        self.mock_id += 1;
        return id;
    }

    pub fn get_mock_last_params(
        self: *Mocker,
        _: std.mem.Allocator,
        id: u64,
    ) ![]ForeignCallParam {
        // std.debug.print("set_mock_returns: {any}\n", .{params});
        return self.mock_calls.items[id].?.last_called_params orelse error.MockNeverCalled;
    }

    pub fn set_mock_times(
        self: *Mocker,
        _: std.mem.Allocator,
        id: u64,
        times_left: u64,
    ) !void {
        self.mock_calls.items[id].?.times_left = times_left;
    }

    pub fn clear_mock(
        self: *Mocker,
        _: std.mem.Allocator,
        id: u64,
    ) !void {
        self.mock_calls.items[id] = null;
    }

    pub fn get_times_called(
        self: *Mocker,
        _: std.mem.Allocator,
        id: u64,
    ) !u32 {
        return self.mock_calls.items[id].?.times_called;
    }
};
