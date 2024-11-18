const std = @import("std");
const pretty = @import("../fmt/pretty.zig");
const poseidon2 = @import("../poseidon2/poseidon2.zig");
const F = @import("../bn254/fr.zig").Fr;
const mt = @import("../merkle_tree/package.zig");

const VERSION = 1;

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
};

pub const ContractAbi = struct {
    noir_version: []const u8,
    name: []const u8,
    functions: []const Function,
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
    std.debug.print("{s}\n", .{buf[0..stream.pos]});
    const hash = poseidon2.hashBytes(buf[0..stream.pos]);
    return std.mem.bytesToValue(FunctionSelector, hash.to_buf()[28..32]);
}

fn computeMetadataHash(contract: ContractAbi) F {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = stream.writer();
    writer.print("{{\"name\":\"{s}\"}}(", .{contract.name}) catch unreachable;
    const hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(buf[0..stream.pos]);
    return F.from_buf(hasher.finalResult());
}

inline fn containsString(strings: []const []const u8, target: []const u8) bool {
    for (strings) |s| if (std.mem.eql(u8, s, target)) return true;
    return false;
}

pub fn computePrivateFunctionTreeRoot(functions: []const Function) !F {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var selectors = try std.ArrayList(FunctionSelector).initCapacity(allocator, functions.len);
    for (functions) |f| {
        if (containsString(f.custom_attributes, "private")) {
            try selectors.append(computeFunctionSelector(f));
        }
    }
    std.mem.sort(FunctionSelector, selectors.items, {}, std.sort.asc(FunctionSelector));
    var leaves = try std.ArrayList(mt.Hash).initCapacity(allocator, selectors.items.len);
    for (selectors.items) |s| {
        const sb = std.mem.asBytes(&s);
        const bytes = [5]u8{ VERSION, sb[0], sb[1], sb[2], sb[3] };
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&bytes, &h, .{});
        try leaves.append(F.from_buf(h));
    }
    const depth = std.math.log2_int_ceil(usize, leaves.items.len) + 1;
    std.debug.print("{} {x}\n", .{ depth, leaves.items });
    // Oh drat. We need runtime depths.
    // var tree = mt.MerkleTreeMem().init(comptime depth: u6, allocator: std.mem.Allocator, pool: ?*ThreadPool)
    return F.zero;
}

// pub fn computeContractArtifactHash(contract: ContractAbi) F {
//     computeFunctionTreeRoot(private);
//     computeFunctionTreeRoot(public);
//     const mdHash = computeMetadataHash(public);
// }

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
    return parsed.value;
}

test "parse contract abi" {
    const abi = try load(std.heap.page_allocator, "./src/contract/fixture.json");
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

test "compute function selector" {
    const selector = computeFunctionSelector(func_fixture);
    std.debug.print("{x}\n", .{selector});
}

test "compute private function tree root" {
    var f2 = func_fixture;
    f2.name = "my_function2";
    var f3 = func_fixture;
    f3.name = "my_function3";
    const root = try computePrivateFunctionTreeRoot(&[_]Function{ func_fixture, f2, f3 });
    std.debug.print("{x}\n", .{root});
}
