pub fn msm(comptime G1Element: type, comptime Fr: type, scalars: []Fr, points: []G1Element) G1Element {
    if (scalars.len != points.len) unreachable;

    var accumulator = G1Element.one;
    for (0..scalars.len) |i| {
        accumulator = accumulator.add(points[i].mul(scalars[i]));
    }

    return accumulator;
}
