const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");

const AztecAddress = F;

const Point = struct {
    x: F,
    y: F,
    i: bool,
};

const NpkM = Point;
const IvpkM = Point;
const OvpkM = Point;
const TpkM = Point;

const PublicKeys = struct {
    npk_m: NpkM,
    ivpk_m: IvpkM,
    ovpk_m: OvpkM,
    tpk_m: TpkM,
};

const CompleteAddress = struct {
    address: AztecAddress,
    public_keys: PublicKeys,
};

const MockedCall = struct {
    /// The id of the mock, used to update or remove it
    id: usize,
    /// The oracle it's mocking
    name: []const u8,
    /// Optionally match the parameters
    params: ?[]foreign_call.ForeignCallParam,
    /// The parameters with which the mock was last called
    last_called_params: ?[]foreign_call.ForeignCallParam,
    /// The result to return when this mock is called
    result: []foreign_call.ForeignCallParam,
    /// How many times should this mock be called before it is removed
    times_left: ?u64,
    /// How many times this mock was actually called
    times_called: u32,
};

pub const Txe = struct {
    allocator: std.mem.Allocator,
    version: F = F.one,
    chain_id: F = F.one,
    block_number: u64 = 0,
    side_effect_counter: u64 = 0,
    contract_address: AztecAddress,
    msg_sender: AztecAddress,
    function_selector: F = F.zero,
    is_static_call: bool = false,
    nested_call_returndata: []F,
    mock_id: u64 = 0,
    mock_calls: std.ArrayList(?MockedCall),
    //   private contractDataOracle: ContractDataOracle;

    pub fn init(allocator: std.mem.Allocator) Txe {
        return .{
            .allocator = allocator,
            .contract_address = F.random(),
            .msg_sender = F.max,
            .nested_call_returndata = &[_]F{},
            .mock_calls = std.ArrayList(?MockedCall).init(allocator),
        };
    }

    pub fn deinit(self: *Txe) void {
        self.mock_calls.deinit();
    }

    /// Dispatch function for foreign calls.
    /// Uses comptime meta foo to marshal data in and out of vm memory, and call functions with the same name on self.
    /// Handler functions arguments and return types must match the layout as described by the foreign call.
    pub fn handleForeignCall(self: *Txe, mem: *Memory, fc: *const io.ForeignCall) !void {
        // This arena allocator is for the transient memory needed for processing the call.
        // In the actual call handlers and mock data, you have access to self.allocator for longer lived data.
        // Note the use of ForeignCallParam.sliceDeepCopy to copy data that needs to become long-lived into self.allocator.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Extract from the VM memory, a slice of ForeignCallParam's, one per argument.
        const params = try foreign_call.extractParams(allocator, mem, fc);

        // If the foreign call has been mocked, handle the mock and return.
        for (self.mock_calls.items) |*maybe_call| {
            if (maybe_call.*) |*call| {
                if (std.mem.eql(u8, call.name, fc.function) and
                    (call.params == null or foreign_call.ForeignCallParam.sliceEql(call.params.?, params)))
                {
                    // std.debug.print("Calling mocked function: {s} with params: {any}\n", .{ fc.function, params });
                    std.debug.print("Calling mocked function: {s}\n", .{fc.function});
                    std.debug.print("Destination value types: {any}\n", .{fc.destination_value_types});
                    call.last_called_params = try foreign_call.ForeignCallParam.sliceDeepCopy(params, self.allocator);
                    call.times_called += 1;
                    // _ = foreign_call.marshalOutput(&call.result, mem, fc.destinations);
                    // for (call.result) |*r_param| {
                    _ = foreign_call.marshalOutput(&call.result, mem, fc.destinations, fc.destination_value_types);
                    // }
                    if (call.times_left) |*left| {
                        left.* -= 1;
                        if (left.* == 0) {
                            maybe_call.* = null;
                        }
                    }
                    return;
                }
            }
        }

        // Special case function handlers that can't be genericised.
        if (std.mem.eql(u8, "set_mock_returns", fc.function)) {
            std.debug.print("Making foreign call to: set_mock_returns with params: {any}\n", .{params[1..]});
            const id: usize = @intCast(params[0].Single);
            self.mock_calls.items[id].?.result = try foreign_call.ForeignCallParam.sliceDeepCopy(params[1..], self.allocator);
            return;
        } else if (std.mem.eql(u8, "set_mock_params", fc.function)) {
            std.debug.print("Making foreign call to: set_mock_params\n", .{});
            const id: usize = @intCast(params[0].Single);
            self.mock_calls.items[id].?.params = try foreign_call.ForeignCallParam.sliceDeepCopy(params[1..], self.allocator);
            return;
        }

        // Otherwise we're going to dispatch to an actual implementation.
        // Get the type information of this Txe struct.
        const info = @typeInfo(Txe).@"struct";

        // Compile time loop over each declaration in the Txe struct.
        // Filtering for relevant functions at compile-time, we dispatch at runtime to function with matching name.
        inline for (info.decls) |decl| {
            // Get the field by declaration name.
            const field = @field(Txe, decl.name);
            // Get the type, and type info of the field.
            const field_type = @TypeOf(field);
            const field_info = @typeInfo(field_type);
            // Compile time check:
            // - This field is a function.
            // - Is not one of the special functions (init, deinit, handleForeignCall).
            if (field_info == .@"fn" and
                field_info.@"fn".params.len >= 1 and
                !comptime (std.mem.eql(u8, decl.name, "init") or
                    std.mem.eql(u8, decl.name, "deinit") or
                    std.mem.eql(u8, decl.name, "handleForeignCall")))
            {
                // Runtime check for matching function name.
                if (std.mem.eql(u8, decl.name, fc.function)) {
                    // There is a function name matching the call on ourself.
                    // Get a tuple to hold the values of the argument types for the function.
                    const Args = std.meta.ArgsTuple(@TypeOf(field));
                    var args: Args = undefined;
                    // Check that the number of parameters matches the number of arguments in the foreign call.
                    std.debug.assert(args.len == params.len + 1);
                    // First arg should be this Txe struct.
                    args[0] = self;
                    inline for (1..args.len) |i| {
                        std.debug.print("Marshal into {s} arg {}: {any}\n", .{ decl.name, i, params[i - 1] });
                        // Marshal the ForeignCallParam into the argument type.
                        foreign_call.marshalInput(&args[i], allocator, params[i - 1]) catch |err| {
                            std.debug.print("Failed to marshal into {s} arg {}: {any}\n", .{ decl.name, i, params[i - 1] });
                            return err;
                        };
                    }
                    // Make the function call.
                    std.debug.print("Making foreign call to: {s}\n", .{decl.name});
                    const r = try @call(.auto, field, args);
                    // Marshall the result back into the VM memory.
                    _ = foreign_call.marshalOutput(&r, mem, fc.destinations, fc.destination_value_types);
                    // std.debug.assert(written == fc.destinations.len);
                    return;
                }
            }
        }

        // We didn't find a matching function. Fallback on default foreign call handler.
        try foreign_call.handleForeignCall(allocator, mem, fc);
    }

    pub fn reset(_: *Txe) !void {
        std.debug.print("reset called!\n", .{});
    }

    pub fn createAccount(self: *Txe) !CompleteAddress {
        _ = self;
        std.debug.print("createAccount called!\n", .{});
        return .{
            .address = F.random(),
            .public_keys = .{
                .npk_m = .{ .x = F.from_int(1), .y = F.from_int(2), .i = false },
                .ivpk_m = .{ .x = F.from_int(3), .y = F.from_int(4), .i = false },
                .ovpk_m = .{ .x = F.from_int(5), .y = F.from_int(6), .i = false },
                .tpk_m = .{ .x = F.from_int(7), .y = F.from_int(8), .i = false },
            },
        };
    }

    pub fn setContractAddress(self: *Txe, address: AztecAddress) !void {
        self.contract_address = address;
        std.debug.print("setContractAddress: {x}\n", .{self.contract_address});
    }

    const DeployResponse = struct {
        salt: F,
        deployer: F,
        contract_class_id: F,
        initialization_hash: F,
        public_keys: PublicKeys,
    };

    pub fn deploy(
        self: *Txe,
        path: []u8,
        name: []u8,
        initializer: []u8,
        args_len: u32,
        args: []F,
        public_keys_hash: F,
    ) ![16]F {
        _ = self;
        std.debug.print("deploy: {s} {s} {s} {} {short} {short}\n", .{
            path,
            name,
            initializer,
            args_len,
            args,
            public_keys_hash,
        });
        var r: [16]F = undefined;
        for (&r) |*e| e.* = F.random();
        return r;
    }

    pub fn create_mock(
        self: *Txe,
        oracle_name: []const u8,
    ) !F {
        std.debug.print("create_mock: {s}\n", .{oracle_name});
        try self.mock_calls.append(.{
            .id = self.mock_id,
            .name = try self.allocator.dupe(u8, oracle_name),
            .params = null,
            .last_called_params = null,
            .result = &[_]foreign_call.ForeignCallParam{},
            .times_left = null,
            .times_called = 0,
        });
        const id = F.from_int(self.mock_id);
        self.mock_id += 1;
        return id;
    }

    pub fn get_mock_last_params(
        self: *Txe,
        id: u64,
    ) ![]foreign_call.ForeignCallParam {
        // std.debug.print("set_mock_returns: {any}\n", .{params});
        return self.mock_calls.items[id].?.last_called_params orelse error.MockNeverCalled;
    }

    pub fn set_mock_times(
        self: *Txe,
        id: u64,
        times_left: u64,
    ) !void {
        self.mock_calls.items[id].?.times_left = times_left;
    }

    pub fn clear_mock(
        self: *Txe,
        id: u64,
    ) !void {
        self.mock_calls.items[id] = null;
    }

    pub fn get_times_called(
        self: *Txe,
        id: u64,
    ) !u32 {
        return self.mock_calls.items[id].?.times_called;
    }
};
