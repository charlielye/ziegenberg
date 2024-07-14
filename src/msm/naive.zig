const std = @import("std");

pub fn msm(comptime G1: type, scalars: []G1.Fr, points: []G1.Element) G1.Element {
    if (scalars.len != points.len) unreachable;

    var accumulator = G1.Element.one;
    for (0..scalars.len) |i| {
        accumulator = accumulator.add(points[i].mul(scalars[i]));
    }

    return accumulator;
}

test "msm" {
    const num: usize = 128;
    const G1 = @import("../bn254/g1.zig").G1;
    const FileSrs = @import("../srs/package.zig").FileSrs;
    const srs = try FileSrs(G1).init(num, "/mnt/user-data/charlie/.bb-crs");
    const points = srs.getG1Data();

    const allocator = std.heap.page_allocator;
    const scalars = try allocator.alloc(G1.Fr, num);
    defer allocator.free(scalars);
    var prng = std.Random.DefaultPrng.init(12345);
    for (scalars) |*fr| {
        fr.* = G1.Fr.pseudo_random(&prng);
    }

    const r = msm(G1, scalars, points);

    r.normalize().print();
}
