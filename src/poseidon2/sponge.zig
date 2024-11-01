const Params = @import("./parameters.zig").Parameters;
const Poseidon2 = @import("./permutation.zig").Poseidon2;

pub fn FieldSponge(comptime FF: type, comptime rate: usize, comptime capacity: usize, comptime Permutation: type) type {
    const t = rate + capacity;

    const Mode = enum {
        Absorb,
        Squeeze,
    };

    return struct {
        const Self = @This();
        state: [t]FF = undefined,
        cache: [rate]FF = undefined,
        cache_size: usize = 0,
        mode: Mode = .Absorb,

        pub fn init(domain_iv: FF) Self {
            var self = Self{
                .state = undefined,
                .cache = undefined,
                .cache_size = 0,
                .mode = .Absorb,
            };

            // Initialize state
            for (self.state[0..rate]) |*item| {
                item.* = FF.zero;
            }
            self.state[rate] = domain_iv;

            // Initialize cache
            for (self.cache[0..]) |*item| {
                item.* = FF.zero;
            }

            return self;
        }

        fn perform_duplex(self: *Self) [rate]FF {
            // Zero-pad the cache
            for (self.cache_size..rate) |i| {
                self.cache[i] = FF.zero;
            }
            // Add the cache into the sponge state
            for (0..rate) |i| {
                self.state[i] = self.state[i].add(self.cache[i]);
            }
            self.state = Permutation.permutation(self.state);
            // Return `rate` number of field elements from the sponge state
            var output: [rate]FF = undefined;
            for (0..rate) |i| {
                output[i] = self.state[i];
            }
            return output;
        }

        pub fn absorb(self: *Self, input: FF) void {
            if (self.mode == .Absorb and self.cache_size == rate) {
                // If we're absorbing and the cache is full, apply the sponge permutation to compress the cache
                _ = self.perform_duplex();
                self.cache[0] = input;
                self.cache_size = 1;
            } else if (self.mode == .Absorb and self.cache_size < rate) {
                // If we're absorbing and the cache is not full, add the input into the cache
                self.cache[self.cache_size] = input;
                self.cache_size += 1;
            } else if (self.mode == .Squeeze) {
                // If we're in squeeze mode, switch to absorb mode and add the input into the cache
                // Note: This code path might not be reachable
                self.cache[0] = input;
                self.cache_size = 1;
                self.mode = .Absorb;
            }
        }

        pub fn squeeze(self: *Self) FF {
            if (self.mode == .Squeeze and self.cache_size == 0) {
                // Switch to absorb mode
                self.mode = .Absorb;
                self.cache_size = 0;
            }
            if (self.mode == .Absorb) {
                // Apply sponge permutation to compress the cache
                const new_output_elements = self.perform_duplex();
                self.mode = .Squeeze;
                for (0..rate) |i| {
                    self.cache[i] = new_output_elements[i];
                }
                self.cache_size = rate;
            }
            // Pop one item off the top of the cache and return it
            const result = self.cache[0];
            for (1..self.cache_size) |i| {
                self.cache[i - 1] = self.cache[i];
            }
            self.cache_size -= 1;
            self.cache[self.cache_size] = FF.zero;
            return result;
        }

        fn hash_internal(comptime out_len: usize, comptime is_variable_length: bool, input: []const FF) [out_len]FF {
            const in_len: u256 = input.len;
            const iv = FF.from_int((in_len << 64) + out_len - 1);
            var sponge = Self.init(iv);

            for (input) |item| {
                sponge.absorb(item);
            }

            if (is_variable_length) {
                sponge.absorb(FF.one());
            }

            var output: [out_len]FF = undefined;
            for (0..out_len) |i| {
                output[i] = sponge.squeeze();
            }
            return output;
        }

        pub fn hash_fixed_length(comptime out_len: usize, input: []const FF) [out_len]FF {
            return Self.hash_internal(out_len, false, input);
        }

        pub fn hash_fixed_length_one(input: []const FF) FF {
            return Self.hash_fixed_length(1, input)[0];
        }

        pub fn hash_variable_length(comptime out_len: usize, input: []const FF) [out_len]FF {
            return Self.hash_internal(out_len, true, input);
        }

        pub fn hash_variable_length_one(input: []const FF) FF {
            return Self.hash_variable_length(1, input)[0];
        }
    };
}

pub const Poseidon2Sponge = FieldSponge(Params.Fr, Params.t - 1, 1, Poseidon2);
