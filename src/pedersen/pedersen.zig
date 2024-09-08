const generators = @import("../pedersen/generators.zig");

pub fn commit(comptime G1: type, inputs: []G1.Fq, generator_offset: u32) G1.Element {
    const gen = generators.default_generators[generator_offset..inputs.len];

    var acc = G1.Element.infinity;
    for (0..inputs.len) |i| {
        acc = acc.add(gen[i].mul(G1.Fr.from_int(inputs[i].to_int())));
    }

    return acc.normalize();
}

pub fn hash(comptime G1: type, inputs: []G1.Fq, generator_offset: u32) G1.Fq {
    const acc = commit(G1, inputs, generator_offset);
    return generators.length_generator.mul(G1.Fr.from_int(inputs.len)).add(acc).normalize().x;
}
