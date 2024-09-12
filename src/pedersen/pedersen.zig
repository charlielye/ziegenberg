const generators = @import("../pedersen/generators.zig");
const msm = @import("../msm/naive.zig").msm;

pub fn commit(comptime G1: type, inputs: []const G1.Fr, generator_offset: u32) G1.Element {
    const gen = generators.default_generators[generator_offset..inputs.len];

    // var acc = G1.Element.infinity;
    // for (0..inputs.len) |i| {
    //     acc = acc.add(gen[i].mul(G1.Fr.from_int(inputs[i].to_int())));
    // }

    return msm(G1, inputs, gen[0..inputs.len]).normalize();
}

pub fn hash(comptime G1: type, inputs: []const G1.Fr, generator_offset: u32) G1.Fq {
    const acc = commit(G1, inputs, generator_offset);
    return generators.length_generator.mul(G1.Fr.from_int(inputs.len)).add(acc).normalize().x;
}
