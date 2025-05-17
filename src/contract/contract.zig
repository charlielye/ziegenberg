const std = @import("std");
const pretty = @import("../fmt/pretty.zig");
const poseidon2 = @import("../poseidon2/poseidon2.zig");
const F = @import("../bn254/fr.zig").Fr;
const mt = @import("../merkle_tree/package.zig");

var VERSION: u8 = 1;

const Type = struct {
    kind: []const u8,
    path: ?[]const u8 = null,
    fields: ?[]Parameter = null,
};

pub const Parameter = struct {
    name: []const u8,
    type: Type,
};

const Abi = struct {
    parameters: []const Parameter,
};

pub const Function = struct {
    name: []const u8,
    is_unconstrained: bool,
    custom_attributes: []const []const u8,
    abi: Abi,
    selector: FunctionSelector = 0,

    pub fn cmp(_: void, a: Function, b: Function) bool {
        return a.selector < b.selector;
    }
};

pub const ContractAbi = struct {
    noir_version: []const u8,
    name: []const u8,
    functions: []Function,
};

const FunctionSelector = u32;

pub fn computeFunctionSelector(function: Function) FunctionSelector {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = stream.writer();
    writer.print("{s}(", .{function.name}) catch unreachable;
    for (function.abi.parameters, 0..) |p, i| {
        if (i > 0) writer.writeByte(',') catch unreachable;
        writer.print("{s}", .{p.type.kind}) catch unreachable;
    }
    writer.writeByte(')') catch unreachable;
    // std.debug.print("{s}\n", .{buf[0..stream.pos]});
    const hash = poseidon2.hashBytes(buf[0..stream.pos]);
    return std.mem.bytesToValue(FunctionSelector, hash.to_buf()[28..32]);
}

fn computeMetadataHash(contract: ContractAbi) F {
    var buf: [256]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&buf);
    return shaHashTuple(allocator.allocator(), .{ "{\"name\":\"", contract.name, "\"}" }) catch unreachable;
}

inline fn containsString(strings: []const []const u8, target: []const u8) bool {
    for (strings) |s| if (std.mem.eql(u8, s, target)) return true;
    return false;
}

fn toBuffer(allocator: std.mem.Allocator, input: anytype) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const info = @typeInfo(@TypeOf(input));
    inline for (info.@"struct".fields) |f| {
        const finfo = @typeInfo(f.type);
        switch (finfo) {
            .int => try buf.appendSlice(std.mem.asBytes(&@field(input, f.name))),
            .pointer => try buf.appendSlice(@field(input, f.name)),
            .array => try buf.appendSlice(&@field(input, f.name)),
            else => unreachable,
        }
    }
    return buf.toOwnedSlice();
}

fn shaHashTuple(allocator: std.mem.Allocator, input: anytype) !F {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try toBuffer(allocator, input), &h, .{});
    return F.from_buf(h);
}

pub fn filterFunctions(allocator: std.mem.Allocator, functions: []const Function, attr: []const u8) ![]Function {
    var result = try std.ArrayList(Function).initCapacity(allocator, functions.len);
    for (functions) |f| {
        if (containsString(f.custom_attributes, attr)) {
            try result.append(f);
        }
    }
    std.mem.sort(Function, result.items, {}, Function.cmp);
    return result.toOwnedSlice();
}

pub fn computePrivateFunctionTreeRoot(allocator: std.mem.Allocator, functions: []const Function) !F {
    return computeFunctionTreeRoot(allocator, try filterFunctions(allocator, functions, "private"));
}

pub fn computePublicFunctionTreeRoot(allocator: std.mem.Allocator, functions: []const Function) !F {
    return computeFunctionTreeRoot(allocator, try filterFunctions(allocator, functions, "public"));
}

pub fn computeUnconstrainedFunctionTreeRoot(allocator: std.mem.Allocator, functions: []const Function) !F {
    return computeFunctionTreeRoot(allocator, try filterFunctions(allocator, functions, "unconstrained"));
}

/// So this differs from how our TS does it.
/// TS uses a variable height tree. We fix to 5.
/// TS uses shafr for artifact roots. We use poseidon2.
pub fn computeFunctionTreeRoot(allocator: std.mem.Allocator, functions: []const Function) !F {
    var leaves = try std.ArrayList(mt.Hash).initCapacity(allocator, functions.len);
    for (functions) |f| {
        const h = try shaHashTuple(allocator, .{ VERSION, f.selector });
        try leaves.append(h);
    }
    // const depth = std.math.log2_int_ceil(usize, leaves.items.len) + 1;
    // std.debug.print("{} {x}\n", .{ depth, leaves.items });
    // Oh drat. We need runtime depths.
    var tree = try mt.MerkleTreeMem(5, mt.poseidon2).init(allocator, null);
    try tree.append(leaves.items);
    return tree.root();
}

pub fn computeContractArtifactHash(allocator: std.mem.Allocator, contract: ContractAbi) !F {
    const private_root = try computePrivateFunctionTreeRoot(allocator, contract.functions);
    // const public_root = try computePublicFunctionTreeRoot(allocator, contract.functions);
    const unconstrained_root = try computeUnconstrainedFunctionTreeRoot(allocator, contract.functions);
    const md_hash = computeMetadataHash(contract);
    return try shaHashTuple(allocator, .{ private_root.to_buf(), unconstrained_root.to_buf(), md_hash.to_buf() });
}

/// Load the contract abi from the json file.
/// Compute all the function selectors.
pub fn load(allocator: std.mem.Allocator, contract_path: []const u8) !ContractAbi {
    var file = try std.fs.cwd().openFile(contract_path, .{});
    defer file.close();
    var json_reader = std.json.reader(allocator, file.reader());
    const parsed = try std.json.parseFromTokenSource(
        ContractAbi,
        allocator,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    );
    const abi = parsed.value;
    for (abi.functions) |*f| f.selector = computeFunctionSelector(f.*);
    return abi;
}

test "parse contract abi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const abi = try load(arena.allocator(), "./src/contract/fixture.json");
    // try pretty.print(std.heap.page_allocator, abi, .{ .max_depth = 20 });
    try std.testing.expectEqualDeep("0.38.0+260440293ebf215278eabca0c6d9e15d76362e5b", abi.noir_version);
    try std.testing.expectEqualDeep("Token", abi.name);
    try std.testing.expectEqual(37, abi.functions.len);
}

const func_fixture = Function{
    .name = "my_function",
    .is_unconstrained = false,
    .custom_attributes = &[_][]const u8{"private"},
    .abi = Abi{ .parameters = &[_]Parameter{.{
        .name = "my_arg",
        .type = .{ .kind = "my_arg_type" },
    }} },
};

test "compute metadata hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const abi = try load(arena.allocator(), "./src/contract/fixture.json");
    const h = computeMetadataHash(abi);
    std.debug.print("metadata hash: {x}\n", .{h});
}

test "compute function selector" {
    const selector = computeFunctionSelector(func_fixture);
    std.debug.print("function selector: {x}\n", .{selector});
}

test "compute private function tree root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f2 = func_fixture;
    f2.name = "my_function2";
    var f3 = func_fixture;
    f3.name = "my_function3";
    const root = try computePrivateFunctionTreeRoot(arena.allocator(), &[_]Function{ func_fixture, f2, f3 });
    std.debug.print("private function tree root: {x}\n", .{root});
}

test "compute artifact hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const abi = try load(arena.allocator(), "./src/contract/fixture.json");
    const h = try computeContractArtifactHash(arena.allocator(), abi);
    std.debug.print("artifact hash: {x}\n", .{h});
}
