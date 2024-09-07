const std = @import("std");
const Parameters = @import("parameters.zig").Parameters;

fn Permutation(comptime Params: type) type {
    const State = [4]Params.Fr;
    const RoundConstants = [4]Params.Fr;
    const NumRounds = Params.rounds_f + Params.rounds_p;
    return struct {
        fn matrix_multiplication_4x4(input: *State) void {
            // hardcoded algorithm that evaluates matrix multiplication using the following MDS matrix:
            // /         \
            // | 5 7 1 3 |
            // | 4 6 1 1 |
            // | 1 3 5 7 |
            // | 1 1 4 6 |
            // \         /
            //
            // Algorithm is taken directly from the Poseidon2 paper.
            const t0 = input[0].add(input[1]); // A + B
            const t1 = input[2].add(input[3]); // C + D
            var t2 = input[1].add(input[1]); // 2B
            t2 = t2.add(t1); // 2B + C + D
            var t3 = input[3].add(input[3]); // 2D
            t3 = t3.add(t0); // 2D + A + B
            var t4 = t1.add(t1);
            t4 = t4.add(t4);
            t4 = t4.add(t3); // A + B + 4C + 6D
            var t5 = t0.add(t0);
            t5 = t5.add(t5);
            t5 = t5.add(t2); // 4A + 6B + C + D
            const t6 = t3.add(t5); // 5A + 7B + C + 3D
            const t7 = t2.add(t4); // A + 3B + 5C + 7D
            input[0] = t6;
            input[1] = t5;
            input[2] = t7;
            input[3] = t4;
        }

        fn add_round_constants(input: *State, comptime rc: RoundConstants) void {
            for (0..Params.t) |i| {
                input[i] = input[i].add(rc[i]);
            }
        }

        fn matrix_multiplication_internal(input: *State) void {
            // for t = 4
            var sum = input[0];
            for (1..Params.t) |i| {
                sum = sum.add(input[i]);
            }
            inline for (0..Params.t) |i| {
                input[i] = input[i].mul(Params.internal_matrix_diagonal[i]);
                input[i] = input[i].add(sum);
            }
        }

        fn matrix_multiplication_external(input: *State) void {
            if (Params.t != 4) {
                unreachable;
            }
            matrix_multiplication_4x4(input);
        }

        fn apply_single_sbox(input: *Params.Fr) void {
            // hardcoded assumption that d = 5. should fix this or not make d configurable
            const xx = input.sqr();
            const xxxx = xx.sqr();
            input.* = input.mul(xxxx);
        }

        fn apply_sbox(input: *State) void {
            for (0..4) |i| {
                apply_single_sbox(&input[i]);
            }
        }

        // Native form of Poseidon2 permutation from https://eprint.iacr.org/2023/323.
        // The permutation consists of one initial linear layer, then a set of external rounds, a set of internal
        // rounds, and a set of external rounds.
        pub fn permutation(input: State) State {
            var current_state = input;

            // Apply 1st linear layer
            matrix_multiplication_external(&current_state);

            // First set of external rounds
            const rounds_f_beginning = Params.rounds_f / 2;
            inline for (0..rounds_f_beginning) |i| {
                add_round_constants(&current_state, Params.round_constants[i]);
                apply_sbox(&current_state);
                matrix_multiplication_external(&current_state);
            }

            // Internal rounds
            const p_end = rounds_f_beginning + Params.rounds_p;
            inline for (rounds_f_beginning..p_end) |i| {
                current_state[0] = current_state[0].add(Params.round_constants[i][0]);
                apply_single_sbox(&current_state[0]);
                matrix_multiplication_internal(&current_state);
            }

            // Remaining external rounds
            inline for (p_end..NumRounds) |i| {
                add_round_constants(&current_state, Params.round_constants[i]);
                apply_sbox(&current_state);
                matrix_multiplication_external(&current_state);
            }
            return current_state;
        }
    };
}

pub const Poseidon2 = Permutation(Parameters);

test "hash_consistency" {
    const input = .{
        Parameters.Fr.from_int(0x0000000000000000000000000000000000000000000000000000000000000000),
        Parameters.Fr.from_int(0x0000000000000000000000000000000000000000000000000000000000000001),
        Parameters.Fr.from_int(0x0000000000000000000000000000000000000000000000000000000000000002),
        Parameters.Fr.from_int(0x0000000000000000000000000000000000000000000000000000000000000003),
    };

    const expected = .{
        Parameters.Fr.from_int(0x01bd538c2ee014ed5141b29e9ae240bf8db3fe5b9a38629a9647cf8d76c01737),
        Parameters.Fr.from_int(0x239b62e7db98aa3a2a8f6a0d2fa1709e7a35959aa6c7034814d9daa90cbac662),
        Parameters.Fr.from_int(0x04cbb44c61d928ed06808456bf758cbf0c18d1e15a7b6dbc8245fa7515d5e3cb),
        Parameters.Fr.from_int(0x2e11c5cff2a22c64d01304b778d78f6998eff1ab73163a35603f54794c30847a),
    };

    const result = Poseidon2.permutation(input);

    inline for (0..4) |i| {
        try std.testing.expect(result[i].eql(expected[i]));
    }
}
