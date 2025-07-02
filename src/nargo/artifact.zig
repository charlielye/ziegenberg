const std = @import("std");
const pretty = @import("../fmt/pretty.zig");
const cvm = @import("../cvm/io.zig");
// const poseidon2 = @import("../poseidon2/poseidon2.zig");
// const F = @import("../bn254/fr.zig").Fr;
// const mt = @import("../merkle_tree/package.zig");

pub const Kind = enum {
    integer,
    string,
    array,
    field,
    boolean,
    @"struct",
    tuple,
};

pub const Type = struct {
    name: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    sign: ?[]const u8 = null,
    width: ?u32 = null,
    type: ?*Type = null,
    path: ?[]const u8 = null,
    fields: ?[]Type = null,
};

pub const Parameter = struct {
    name: []const u8,
    type: Type,
    visibility: ?[]const u8 = null,
};

const Abi = struct {
    parameters: []const Parameter,
};

// pub const Function = struct {
//     name: []const u8,
//     is_unconstrained: bool,
//     custom_attributes: []const []const u8,
//     abi: Abi,
//     selector: FunctionSelector = 0,

//     pub fn cmp(_: void, a: Function, b: Function) bool {
//         return a.selector < b.selector;
//     }
// };

pub const ArtifactAbi = struct {
    noir_version: []const u8,
    hash: []const u8,
    abi: Abi,
    bytecode: []const u8,
    // functions: []Function,

    /// Base 64 decode, gunzip, and return the bytecode.
    pub fn getBytecode(self: *const ArtifactAbi, allocator: std.mem.Allocator) ![]const u8 {
        const decoder = std.base64.standard.Decoder;
        const buf = try allocator.alloc(u8, try decoder.calcSizeUpperBound(self.bytecode.len));
        defer allocator.free(buf);
        try decoder.decode(buf, self.bytecode);
        var reader_stream = std.io.fixedBufferStream(buf);
        // var decom = std.compress.gzip.decompressor(reader_stream.reader());
        // return decom.reader().any();
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try std.compress.gzip.decompress(reader_stream.reader(), buffer.writer());
        return buffer.toOwnedSlice();
    }

    // pub fn getBytecode(self: *const ArtifactAbi, allocator: std.mem.Allocator) ![]const u8 {
    //     var buffer = std.ArrayList(u8).init(allocator);
    //     defer buffer.deinit();
    //     const reader = try getBytecodeReader(self, allocator);
    //     try reader.readAllArrayList(&buffer, 1024 * 1024 * 10);
    //     return buffer.toOwnedSlice();
    // }
};

/// Load the abi from the json file.
pub fn load(allocator: std.mem.Allocator, contract_path: []const u8) !ArtifactAbi {
    var file = try std.fs.cwd().openFile(contract_path, .{});
    defer file.close();
    var json_reader = std.json.reader(allocator, file.reader());
    var diagnostics = std.json.Diagnostics{};
    json_reader.enableDiagnostics(&diagnostics);
    const parsed = std.json.parseFromTokenSource(
        ArtifactAbi,
        allocator,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.debug.print("Error parsing JSON at line {}:{}: {}\n", .{
            diagnostics.getLine(),
            diagnostics.getColumn(),
            err,
        });
        return err;
    };
    const abi = parsed.value;
    return abi;
}

test "parse abi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const abi = try load(arena.allocator(), "./aztec-packages/noir/noir-repo/test_programs/execution_success/a_1_mul/target/a_1_mul.json");
    try std.testing.expectStringStartsWith(abi.noir_version, "1.0.0-beta.");
}

test "execute abi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const abi = try load(arena.allocator(), "./aztec-packages/noir/noir-repo/test_programs/execution_success/a_1_mul/target/a_1_mul.json");
    const bytecode = try abi.getBytecode(arena.allocator());
    const program = try cvm.deserialize(arena.allocator(), bytecode);
    try std.testing.expectEqual(1, program.functions.len);
}
