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

const DeployResponse = struct {
    salt: F,
    deployer: F,
    contract_class_id: F,
    initialization_hash: F,
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
    //   private contractDataOracle: ContractDataOracle;

    pub fn init(allocator: std.mem.Allocator) Txe {
        return .{
            .allocator = allocator,
            .contract_address = F.random(),
            .msg_sender = F.max,
            .nested_call_returndata = &[_]F{},
        };
    }

    /// Dispatch function for foreign calls.
    /// Uses comptime meta foo to marshal data in and out of vm memory, and call functions with the same name on self.
    /// Handler functions arguments and return types must match the layout as described by the foreign call.
    pub fn handleForeignCall(self: *Txe, mem: *Memory, fc: *const io.ForeignCall) !void {
        // This arena allocator is for the transient memory needed for processing the call.
        // In the actual call handlers, if you have access to self.allocator for longer lived data.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const info = @typeInfo(Txe).Struct;
        inline for (info.decls) |decl| {
            const field = @field(Txe, decl.name);
            const field_type = @TypeOf(field);
            const field_info = @typeInfo(field_type);
            if (field_info == .Fn and
                field_info.Fn.params.len >= 1 and
                field_info.Fn.params[0].type == *Txe and
                // TODO: Skipping this function, but !std.mem.eql didn't work?
                (field_info.Fn.params.len == 1 or field_info.Fn.params[1].type != *Memory))
            {
                if (std.mem.eql(u8, decl.name, fc.function)) {
                    // There is a function name matching the call on ourself.
                    const params = try foreign_call.extractParams(allocator, mem, fc);

                    const Args = std.meta.ArgsTuple(@TypeOf(field));
                    var args: Args = undefined;
                    std.debug.assert(args.len == params.len + 1);
                    args[0] = self;
                    inline for (1..args.len) |i| {
                        try foreign_call.marshalInput(&args[i], allocator, params[i - 1]);
                    }
                    const r = try @call(.auto, field, args);
                    const written = foreign_call.marshalOutput(&r, mem, fc.destinations);
                    std.debug.assert(written == fc.destinations.len);
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
