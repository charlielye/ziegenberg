const std = @import("std");
pub const fq = @import("bn254/fq.zig");
pub const bn254_g1 = @import("bn254/g1.zig");
pub const grumpkin_g1 = @import("grumpkin/g1.zig");
pub const srs = @import("srs/package.zig");
pub const msm = @import("msm/naive.zig");
pub const field = @import("blackbox/field.zig");
pub const blackbox = @import("blackbox/blackbox.zig");
pub const cvm_execute = @import("cvm/execute.zig");
pub const merkle_tree = @import("merkle_tree/package.zig");
pub const thread_pool = @import("thread/thread_pool.zig");
pub const poseidon2 = @import("poseidon2/poseidon2.zig");
pub const protocol = @import("protocol/package.zig");
pub const nargo = @import("nargo/package.zig");

test {
    // Reference all modules to ensure their tests are included
    std.testing.refAllDecls(@This());
    _ = @import("bn254/fq.zig");
    _ = @import("bn254/g1.zig");
    _ = @import("grumpkin/g1.zig");
    _ = @import("srs/package.zig");
    _ = @import("msm/naive.zig");
    _ = @import("blackbox/field.zig");
    _ = @import("blackbox/blackbox.zig");
    _ = @import("cvm/execute.zig");
    _ = @import("merkle_tree/package.zig");
    _ = @import("thread/thread_pool.zig");
    _ = @import("poseidon2/poseidon2.zig");
    _ = @import("protocol/package.zig");
    _ = @import("nargo/package.zig");
}