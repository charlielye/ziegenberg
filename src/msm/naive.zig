const std = @import("std");
const rdtsc = @import("../timer/rdtsc.zig").rdtsc;

pub fn msm(comptime G1: type, scalars: []G1.Fr, points: []const G1.Element) G1.Element {
    if (scalars.len != points.len) unreachable;

    var accumulator = G1.Element.infinity;
    for (0..scalars.len) |i| {
        accumulator = accumulator.add(points[i].mul(scalars[i]));
    }

    return accumulator;
}

// Optimisations that get us a lot of the benefits of pippenger, without being pippenger.
// Stupid multithreading.
// Endomorphism and strauss. Halves doublings.
// Batch affine

// test "msm" {
//     const num: usize = 1 << 16;
//     const G1 = @import("../bn254/g1.zig").G1;
//     const FileSrs = @import("../srs/package.zig").FileSrs;
//     const srs = try FileSrs(G1).init(num, "/mnt/user-data/charlie/.bb-crs");
//     const points = srs.getG1Data();

//     const allocator = std.heap.page_allocator;
//     const scalars = try allocator.alloc(G1.Fr, num);
//     defer allocator.free(scalars);
//     var prng = std.Random.DefaultPrng.init(12345);
//     for (scalars) |*fr| {
//         fr.* = G1.Fr.pseudo_random(&prng);
//     }

//     const cycles = rdtsc();
//     var t = try std.time.Timer.start();
//     const r = msm(G1, scalars, points);
//     std.debug.print("time taken: {}ns\n", .{t.read()});
//     std.debug.print("cycles per mul: {}\n", .{(rdtsc() - cycles) / num});

//     r.normalize().print();
// }
