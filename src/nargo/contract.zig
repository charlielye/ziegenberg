const std = @import("std");
const pretty = @import("../fmt/pretty.zig");
const poseidon2 = @import("../poseidon2/poseidon2.zig");
const F = @import("../bn254/fr.zig").Fr;
const mt = @import("../merkle_tree/package.zig");
const constants = @import("../protocol/constants.gen.zig");

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

const FunctionSelector = u32;

pub const Function = struct {
    name: []const u8,
    is_unconstrained: bool,
    custom_attributes: []const []const u8,
    abi: Abi,
    bytecode: []const u8 = &[_]u8{},
    verification_key: ?[]const u8 = null,
    selector: FunctionSelector = 0,

    pub fn computeSelector(self: *const Function) FunctionSelector {
        var buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        var writer = stream.writer();
        writer.print("{s}(", .{self.name}) catch unreachable;
        for (self.abi.parameters, 0..) |p, i| {
            if (i > 0) writer.writeByte(',') catch unreachable;
            writer.print("{s}", .{p.type.kind}) catch unreachable;
        }
        writer.writeByte(')') catch unreachable;
        std.debug.print("{s}\n", .{buf[0..stream.pos]});
        const hash = poseidon2.hashBytes(buf[0..stream.pos]);
        return std.mem.bytesToValue(FunctionSelector, hash.to_buf()[28..32]);
    }

    /// Base 64 decode, gunzip, and return the bytecode.
    pub fn getBytecode(self: *const Function, allocator: std.mem.Allocator) ![]const u8 {
        const decoder = std.base64.standard.Decoder;
        const buf = try allocator.alloc(u8, try decoder.calcSizeUpperBound(self.bytecode.len));
        defer allocator.free(buf);
        try decoder.decode(buf, self.bytecode);
        var reader_stream = std.io.fixedBufferStream(buf);
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try std.compress.gzip.decompress(reader_stream.reader(), buffer.writer());
        return buffer.toOwnedSlice();
    }

    pub fn cmp(_: void, a: Function, b: Function) bool {
        return a.selector < b.selector;
    }
};

pub const ContractAbi = struct {
    noir_version: []const u8,
    name: []const u8,
    functions: []Function,
    // Following are computed at load time.
    public_function: ?Function = null,
    private_functions: []Function = &[_]Function{},
    unconstrained_functions: []Function = &[_]Function{},
    initializer_functions: []Function = &[_]Function{},
    private_function_tree_root: F = F.zero,
    unconstrained_function_tree_root: F = F.zero,
    public_bytecode_commitment: F = F.zero,
    artifact_hash: F = F.zero,
    default_initializer: ?Function = null,
    class_id: F = F.zero,

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
        var abi = parsed.value;
        for (abi.functions) |*f| {
            f.selector = f.computeSelector();
            std.debug.print("Function: {s} {x}\n", .{ f.name, f.selector });
            if (std.mem.eql(u8, f.name, "public_dispatch")) {
                abi.public_function = f.*;
                abi.public_bytecode_commitment = try computePublicBytecodeCommitment(f.bytecode);
            }
        }

        abi.private_functions = try filterFunctions(allocator, abi.functions, "private");
        abi.unconstrained_functions = try filterFunctions(allocator, abi.functions, "unconstrained");
        abi.initializer_functions = try filterFunctions(allocator, abi.functions, "initializer");
        abi.private_function_tree_root = try computeFunctionTreeRoot(allocator, abi.private_functions);
        abi.unconstrained_function_tree_root = try computeFunctionTreeRoot(allocator, abi.unconstrained_functions);
        abi.artifact_hash = try abi.computeArtifactHash(allocator);
        abi.default_initializer = abi.findDefaultInitializer();
        abi.class_id = poseidon2.hash(&[_]F{
            F.from_int(constants.GeneratorIndex.contract_leaf),
            abi.artifact_hash,
            abi.private_function_tree_root,
            abi.public_bytecode_commitment,
        });

        return abi;
    }

    pub fn getFunctionBySelector(
        self: *const ContractAbi,
        selector: FunctionSelector,
    ) !Function {
        for (self.functions) |f| {
            if (f.selector == selector) {
                return f;
            }
        }
        return error.FunctionNotFound;
    }

    fn findDefaultInitializer(self: *ContractAbi) ?Function {
        if (self.initializer_functions.len == 0) return null;

        for (self.initializer_functions) |f| {
            if (std.mem.eql(u8, f.name, "initializer")) return f;
        }
        for (self.initializer_functions) |f| {
            if (std.mem.eql(u8, f.name, "constructor")) return f;
        }
        for (self.initializer_functions) |f| {
            if (f.abi.parameters.len == 0) return f;
        }
        for (self.initializer_functions) |f| {
            if (containsString(f.custom_attributes, "private")) return f;
        }
        return self.initializer_functions[0];
    }

    fn computeArtifactHash(self: *ContractAbi, allocator: std.mem.Allocator) !F {
        return try shaHashTuple(allocator, .{
            self.private_function_tree_root.to_buf(),
            self.unconstrained_function_tree_root.to_buf(),
            self.computeMetadataHash().to_buf(),
        });
    }

    fn computeMetadataHash(contract: *ContractAbi) F {
        var buf: [256]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&buf);
        return shaHashTuple(allocator.allocator(), .{ "{\"name\":\"", contract.name, "\"}" }) catch unreachable;
    }
};

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

fn filterFunctions(allocator: std.mem.Allocator, functions: []const Function, attr: []const u8) ![]Function {
    var result = try std.ArrayList(Function).initCapacity(allocator, functions.len);
    for (functions) |f| {
        if (containsString(f.custom_attributes, attr)) {
            try result.append(f);
        }
    }
    std.mem.sort(Function, result.items, {}, Function.cmp);
    return result.toOwnedSlice();
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

fn computePublicBytecodeCommitment(bytecode: []const u8) !F {
    const max_len = constants.MAX_PACKED_PUBLIC_BYTECODE_SIZE_IN_FIELDS * 31;
    if (bytecode.len > max_len) {
        std.debug.print("Public bytecode too long: {d} (max: {d})\n", .{ bytecode.len, max_len });
        return error.PublicBytecodeTooLong;
    }

    // +1 for domain separator.
    var fields = [_]F{F.zero} ** (constants.MAX_PACKED_PUBLIC_BYTECODE_SIZE_IN_FIELDS + 1);
    fields[0] = F.from_int(constants.GeneratorIndex.public_bytecode);

    // TODO: There seem to be 2 ways to hash bytes. Unify?
    // This way is:
    // [0,b0,b1,b2,...]
    // The poseidon2.hashBytes way is:
    // [0,...,b2,b1,b0]
    for (fields[1..], 0..) |*field, i| {
        const start = i * 31;
        if (start >= bytecode.len) {
            break;
        }
        const end = @min(start + 31, bytecode.len);
        var chunk: [32]u8 = [_]u8{0} ** 32;
        std.mem.copyForwards(u8, chunk[1..], bytecode[start..end]);
        field.* = F.from_buf(chunk);
    }

    return poseidon2.hash(&fields);
}

const token_contract_abi_path = "aztec-packages/noir-projects/noir-contracts/target/token_contract-Token.json";

test "parse contract abi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const abi = try ContractAbi.load(arena.allocator(), token_contract_abi_path);
    try std.testing.expectEqualDeep("Token", abi.name);
    try std.testing.expectEqual(37, abi.functions.len);
    try std.testing.expectEqual(1, abi.initializer_functions.len);
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

// test "compute metadata hash" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const abi = try ContractAbi.load(arena.allocator(), token_contract_abi_path);
//     const h = abi.computeMetadataHash();
//     std.debug.print("metadata hash: {x}\n", .{h});
// }

test "compute function selector" {
    const selector = func_fixture.computeSelector();
    std.debug.print("function selector: {x}\n", .{selector});
}

test "compute private function tree root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f2 = func_fixture;
    f2.name = "my_function2";
    var f3 = func_fixture;
    f3.name = "my_function3";
    const root = try computeFunctionTreeRoot(arena.allocator(), &[_]Function{ func_fixture, f2, f3 });
    std.debug.print("private function tree root: {x}\n", .{root});
}

test "compute artifact hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const abi = try ContractAbi.load(arena.allocator(), token_contract_abi_path);
    std.debug.print("artifact hash: {x}\n", .{abi.artifact_hash});
}
