const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");
const Mocker = @import("./mocker.zig").Mocker;
const foreignCallStructDispatcher = @import("./foreign_call_struct_dispatcher.zig").foreignCallStructDispatcher;

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
    mocker: Mocker,
    //   private contractDataOracle: ContractDataOracle;

    pub fn init(allocator: std.mem.Allocator) Txe {
        return .{
            .allocator = allocator,
            .contract_address = F.random(),
            .msg_sender = F.max,
            .nested_call_returndata = &[_]F{},
            .mocker = Mocker.init(allocator),
        };
    }

    pub fn deinit(self: *Txe) void {
        self.mocker.deinit();
    }

    /// Dispatch function for foreign calls.
    /// Uses comptime meta foo to marshal data in and out of vm memory, and call functions with the same name on self.
    /// Handler functions arguments and return types must match the layout as described by the foreign call.
    pub fn handleForeignCall(self: *Txe, mem: *Memory, fc: *const io.ForeignCall) !void {
        // This arena allocator is for the transient memory needed for processing the call.
        // In the actual call handlers you have access to self.allocator for longer lived data.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Extract from the VM memory, a slice of ForeignCallParam's, one per argument.
        const params = try foreign_call.extractParams(arena.allocator(), mem, fc);

        // First see if this is a mock setup call, or a mocked call.
        if (try self.mocker.handleForeignCall(mem, fc, params)) {
            return;
        }

        // Otherwise attempt to dispatch on ourself.
        if (try foreignCallStructDispatcher(self, arena.allocator(), mem, fc, params)) {
            return;
        }

        // We didn't find a matching function. Fallback on default foreign call handler.
        try foreign_call.handleForeignCall(arena.allocator(), mem, fc, params);
    }

    pub fn reset(_: *Txe) !void {
        std.debug.print("reset called!\n", .{});
    }

    pub fn createAccount(self: *Txe, secret: F) !CompleteAddress {
        _ = self;
        std.debug.print("createAccount called: {x}\n", .{secret});
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
};
