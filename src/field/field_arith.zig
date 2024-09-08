const std = @import("std");

pub fn to_limbs(data: u256) [4]u64 {
    // @setRuntimeSafety(false);
    return @bitCast(data);
}

pub fn to_montgomery_form(comptime params: anytype, data: [4]u64) [4]u64 {
    @setEvalBranchQuota(20000);
    // @setRuntimeSafety(false);
    var d = data;
    d = reduce(params, d);
    d = reduce(params, d);
    d = reduce(params, d);
    d = montgomery_mul(params, d, params.r_squared);
    d = reduce(params, d);
    return d;
}

pub fn from_montgomery_form(comptime params: anytype, data: [4]u64) [4]u64 {
    // @setRuntimeSafety(false);
    var d = data;
    d = montgomery_mul(params, d, .{ 1, 0, 0, 0 });
    d = reduce(params, d);
    return d;
}

inline fn mul_wide(a: u64, b: u64) [2]u64 {
    // @setRuntimeSafety(false);
    const res: u128 = @as(u128, a) * @as(u128, b);
    return [2]u64{ @truncate(res), @intCast(res >> 64) };
}

inline fn mac(a: u64, b: u64, c: u64, carry_in: u64, out: *u64, carry_out: *u64) void {
    // @setRuntimeSafety(false);
    const res: u128 = ((@as(u128, b) * c) + a) + carry_in;
    out.* = @truncate(res);
    carry_out.* = @intCast(res >> 64);
}

inline fn mac_mini(a: u64, b: u64, c: u64, carry_out: *u64) u64 {
    // @setRuntimeSafety(false);
    const res: u128 = ((@as(u128, b) * c) + a);
    carry_out.* = @intCast(res >> 64);
    return @truncate(res);
}

inline fn mac_mini_full(a: u64, b: u64, c: u64, out: *u64, carry_out: *u64) void {
    // @setRuntimeSafety(false);
    const res = (@as(u128, b) * c) + a;
    out.* = @truncate(res);
    carry_out.* = @intCast(res >> 64);
}

inline fn mac_discard_lo(a: u64, b: u64, c: u64) u64 {
    // @setRuntimeSafety(false);
    const res: u128 = (@as(u128, b) * c) + a;
    return @intCast(res >> 64);
}

inline fn addc(a: u64, b: u64, carry_in: u64, carry_out: *u64) u64 {
    // @setRuntimeSafety(false);
    const res: u128 = @as(u128, a) + b + carry_in;
    carry_out.* = @intCast(res >> 64);
    return @truncate(res);
}

inline fn sbb(a: u64, b: u64, borrow_in: u64, borrow_out: *u64) u64 {
    // @setRuntimeSafety(false);
    const res: u128 = @bitCast(@as(i128, a) - (@as(i128, b) + (@as(i128, borrow_in) >> 63)));
    borrow_out.* = @intCast(res >> 64);
    return @truncate(res);
}

pub fn reduce(comptime params: anytype, data: [4]u64) [4]u64 {
    // @setRuntimeSafety(false);
    const not_modulus = params.not_modulus;
    const t0, var c: u64 = @addWithOverflow(data[0], not_modulus[0]);
    // std.debug.print("t0 {} c {}\n", .{ t0, c });
    const t1 = addc(data[1], not_modulus[1], c, &c);
    const t2 = addc(data[2], not_modulus[2], c, &c);
    const t3 = addc(data[3], not_modulus[3], c, &c);
    const selection_mask: u64 = if (c > 0) 0xFFFFFFFFFFFFFFFF else 0;
    const selection_mask_inverse = ~selection_mask;
    return [_]u64{
        (data[0] & selection_mask_inverse) | (t0 & selection_mask),
        (data[1] & selection_mask_inverse) | (t1 & selection_mask),
        (data[2] & selection_mask_inverse) | (t2 & selection_mask),
        (data[3] & selection_mask_inverse) | (t3 & selection_mask),
    };
}

pub inline fn montgomery_mul(comptime params: anytype, data: [4]u64, other: [4]u64) [4]u64 {
    // @setRuntimeSafety(false);
    const r_inv = params.r_inv;
    const modulus = params.modulus;
    var t0: u64 = undefined;
    var t1: u64 = undefined;
    var t2: u64 = undefined;
    var t3: u64 = undefined;
    var c: u64 = undefined;
    var a: u64 = undefined;
    var k: u64 = undefined;

    // First iteration
    {
        t0, c = mul_wide(data[0], other[0]);
        // k = @mulWithOverflow(t0, r_inv)[0];
        k = t0 *% r_inv;
        a = mac_discard_lo(t0, k, modulus[0]);
        t1 = mac_mini(a, data[0], other[1], &a);
        mac(t1, k, modulus[1], c, &t0, &c);
        t2 = mac_mini(a, data[0], other[2], &a);
        mac(t2, k, modulus[2], c, &t1, &c);
        t3 = mac_mini(a, data[0], other[3], &a);
        mac(t3, k, modulus[3], c, &t2, &c);
        t3 = c + a;
    }

    // Second iteration
    {
        mac_mini_full(t0, data[1], other[0], &t0, &a);
        k = t0 *% r_inv;
        c = mac_discard_lo(t0, k, modulus[0]);
        mac(t1, data[1], other[1], a, &t1, &a);
        mac(t1, k, modulus[1], c, &t0, &c);
        mac(t2, data[1], other[2], a, &t2, &a);
        mac(t2, k, modulus[2], c, &t1, &c);
        mac(t3, data[1], other[3], a, &t3, &a);
        mac(t3, k, modulus[3], c, &t2, &c);
        t3 = c + a;
    }

    // Third iteration
    {
        mac_mini_full(t0, data[2], other[0], &t0, &a);
        k = t0 *% r_inv;
        c = mac_discard_lo(t0, k, modulus[0]);
        mac(t1, data[2], other[1], a, &t1, &a);
        mac(t1, k, modulus[1], c, &t0, &c);
        mac(t2, data[2], other[2], a, &t2, &a);
        mac(t2, k, modulus[2], c, &t1, &c);
        mac(t3, data[2], other[3], a, &t3, &a);
        mac(t3, k, modulus[3], c, &t2, &c);
        t3 = c + a;
    }

    // Fourth iteration
    {
        mac_mini_full(t0, data[3], other[0], &t0, &a);
        k = t0 *% r_inv;
        c = mac_discard_lo(t0, k, modulus[0]);
        mac(t1, data[3], other[1], a, &t1, &a);
        mac(t1, k, modulus[1], c, &t0, &c);
        mac(t2, data[3], other[2], a, &t2, &a);
        mac(t2, k, modulus[2], c, &t1, &c);
        mac(t3, data[3], other[3], a, &t3, &a);
        mac(t3, k, modulus[3], c, &t2, &c);
        t3 = c + a;
    }

    return [_]u64{ t0, t1, t2, t3 };
}

inline fn square_accumulate(a: u64, b: u64, c: u64, carry_in_lo: u64, carry_in_hi: u64, carry_out_lo: *u64, carry_out_hi: *u64) u64 {
    // @setRuntimeSafety(false);
    const product = @mulWithOverflow(@as(u128, b), c)[0];
    const r0: u64 = @truncate(product);
    const r1: u64 = @truncate(product >> 64);
    var out = @addWithOverflow(r0, r0)[0];

    var carry_lo: u64 = @intFromBool(out < r0);
    out = @addWithOverflow(out, a)[0];
    carry_lo += @intFromBool(out < a);
    out = @addWithOverflow(out, carry_in_lo)[0];
    carry_lo += @intFromBool(out < carry_in_lo);
    carry_lo, var carry_hi = @addWithOverflow(carry_lo, r1);

    carry_lo = @addWithOverflow(carry_lo, r1)[0];
    carry_hi += @intFromBool(carry_lo < r1);

    carry_lo = @addWithOverflow(carry_lo, carry_in_hi)[0];
    carry_hi = carry_hi +% @intFromBool(carry_lo < carry_in_hi);

    carry_out_lo.* = carry_lo;
    carry_out_hi.* = carry_hi;
    return out;
}

pub fn montgomery_square(comptime params: anytype, data: [4]u64) [4]u64 {
    const r_inv = params.r_inv;
    const modulus = params.modulus;
    var t0: u64 = undefined;
    var t1: u64 = undefined;
    var t2: u64 = undefined;
    var t3: u64 = undefined;
    var c_hi: u64 = 0;
    var c_lo: u64 = 0;
    var round_carry: u64 = undefined;
    var k: u64 = undefined;

    t0, c_lo = mul_wide(data[0], data[0]);
    t1 = square_accumulate(0, data[1], data[0], c_lo, c_hi, &c_lo, &c_hi);
    t2 = square_accumulate(0, data[2], data[0], c_lo, c_hi, &c_lo, &c_hi);
    t3 = square_accumulate(0, data[3], data[0], c_lo, c_hi, &c_lo, &c_hi);

    round_carry = c_lo;
    k = t0 *% r_inv;
    c_lo = mac_discard_lo(t0, k, modulus[0]);
    mac(t1, k, modulus[1], c_lo, &t0, &c_lo);
    mac(t2, k, modulus[2], c_lo, &t1, &c_lo);
    mac(t3, k, modulus[3], c_lo, &t2, &c_lo);
    t3 = @addWithOverflow(c_lo, round_carry)[0];

    t1 = mac_mini(t1, data[1], data[1], &c_lo);
    c_hi = 0;
    t2 = square_accumulate(t2, data[2], data[1], c_lo, c_hi, &c_lo, &c_hi);
    t3 = square_accumulate(t3, data[3], data[1], c_lo, c_hi, &c_lo, &c_hi);
    round_carry = c_lo;
    k = t0 *% r_inv;
    c_lo = mac_discard_lo(t0, k, modulus[0]);
    mac(t1, k, modulus[1], c_lo, &t0, &c_lo);
    mac(t2, k, modulus[2], c_lo, &t1, &c_lo);
    mac(t3, k, modulus[3], c_lo, &t2, &c_lo);
    t3 = @addWithOverflow(c_lo, round_carry)[0];

    t2 = mac_mini(t2, data[2], data[2], &c_lo);
    c_hi = 0;
    t3 = square_accumulate(t3, data[3], data[2], c_lo, c_hi, &c_lo, &c_hi);
    round_carry = c_lo;
    k = t0 *% r_inv;
    c_lo = mac_discard_lo(t0, k, modulus[0]);
    mac(t1, k, modulus[1], c_lo, &t0, &c_lo);
    mac(t2, k, modulus[2], c_lo, &t1, &c_lo);
    mac(t3, k, modulus[3], c_lo, &t2, &c_lo);
    t3 = @addWithOverflow(c_lo, round_carry)[0];

    t3 = mac_mini(t3, data[3], data[3], &c_lo);
    k = t0 *% r_inv;
    round_carry = c_lo;
    c_lo = mac_discard_lo(t0, k, modulus[0]);
    mac(t1, k, modulus[1], c_lo, &t0, &c_lo);
    mac(t2, k, modulus[2], c_lo, &t1, &c_lo);
    mac(t3, k, modulus[3], c_lo, &t2, &c_lo);
    t3 = @addWithOverflow(c_lo, round_carry)[0];

    return .{ t0, t1, t2, t3 };
}

pub fn add(comptime params: anytype, data: [4]u64, other: [4]u64) [4]u64 {
    // @setRuntimeSafety(false);
    const twice_not_modulus = params.twice_not_modulus;
    // var c: u64 = 0;
    // const r0 = addc(data[0], other[0], c, &c);
    const r0, var c: u64 = @addWithOverflow(data[0], other[0]);
    const r1 = addc(data[1], other[1], c, &c);
    const r2 = addc(data[2], other[2], c, &c);
    // const r3 = addc(data[3], other[3], c, &c);
    // TODO: Not sure about this. We discard the final carry?
    const r3 = @addWithOverflow(data[3], other[3])[0] + c;
    // const r3: u64 = @truncate(@as(u128, data[3]) + other[3] + c);

    const t0, c = @addWithOverflow(r0, twice_not_modulus[0]);
    // const t0 = addc(r0, twice_not_modulus[0], 0, &c);
    const t1 = addc(r1, twice_not_modulus[1], c, &c);
    const t2 = addc(r2, twice_not_modulus[2], c, &c);
    const t3 = addc(r3, twice_not_modulus[3], c, &c);
    const selection_mask = @subWithOverflow(0, c)[0];
    // std.debug.print("{} {x}", .{ c, selection_mask });
    const selection_mask_inverse = ~selection_mask;

    return .{
        (r0 & selection_mask_inverse) | (t0 & selection_mask),
        (r1 & selection_mask_inverse) | (t1 & selection_mask),
        (r2 & selection_mask_inverse) | (t2 & selection_mask),
        (r3 & selection_mask_inverse) | (t3 & selection_mask),
    };
}

pub fn sub(comptime params: anytype, data: [4]u64, other: [4]u64) [4]u64 {
    // @setRuntimeSafety(false);
    const modulus = params.modulus;
    var borrow: u64 = 0;

    var r0 = sbb(data[0], other[0], borrow, &borrow);
    var r1 = sbb(data[1], other[1], borrow, &borrow);
    var r2 = sbb(data[2], other[2], borrow, &borrow);
    var r3 = sbb(data[3], other[3], borrow, &borrow);

    // std.debug.print("r0 {x:0>16}\n", .{r0});
    // std.debug.print("r1 {x:0>16}\n", .{r1});
    // std.debug.print("r2 {x:0>16}\n", .{r2});
    // std.debug.print("r3 {x:0>16}\n", .{r3});

    r0 += (modulus[0] & borrow);
    var carry: u64 = @intFromBool(r0 < (modulus[0] & borrow));
    r1 = addc(r1, modulus[1] & borrow, carry, &carry);
    r2 = addc(r2, modulus[2] & borrow, carry, &carry);
    r3 = addc(r3, modulus[3] & borrow, carry, &carry);

    // The value being subtracted is in [0, 2**256), if we subtract 0 - 2*255 and then add p, the value will stay
    // negative. If we are adding p, we need to check that we've overflown 2**256. If not, we should add p again.
    if (carry == 0) {
        r0 += (modulus[0] & borrow);
        carry = @intFromBool(r0 < (modulus[0] & borrow));
        r1 = addc(r1, modulus[1] & borrow, carry, &carry);
        r2 = addc(r2, modulus[2] & borrow, carry, &carry);
        r3 = addc(r3, modulus[3] & borrow, carry, &carry);
    }

    return .{ r0, r1, r2, r3 };
}

pub fn sub_coarse(comptime params: anytype, data: [4]u64, other: [4]u64) [4]u64 {
    // @setRuntimeSafety(false);
    const twice_modulus = params.twice_modulus;
    var borrow: u64 = 0;

    var r0 = sbb(data[0], other[0], borrow, &borrow);
    var r1 = sbb(data[1], other[1], borrow, &borrow);
    var r2 = sbb(data[2], other[2], borrow, &borrow);
    var r3 = sbb(data[3], other[3], borrow, &borrow);

    r0, var carry: u64 = @addWithOverflow(r0, twice_modulus[0] & borrow);
    // var carry: u64 = @intFromBool(r0 < (twice_modulus[0] & borrow));
    r1 = addc(r1, twice_modulus[1] & borrow, carry, &carry);
    r2 = addc(r2, twice_modulus[2] & borrow, carry, &carry);
    r3 = @addWithOverflow(r3, (twice_modulus[3] & borrow) + carry)[0];

    // std.debug.print("r0 {x:0>16}\n", .{r0});
    // std.debug.print("r1 {x:0>16}\n", .{r1});
    // std.debug.print("r2 {x:0>16}\n", .{r2});
    // std.debug.print("r3 {x:0>16}\n", .{r3});

    return .{ r0, r1, r2, r3 };
}

pub fn debugPrintArray(array: [4]u64) void {
    for (0.., array) |i, elem| {
        std.debug.print("{x}", .{elem});
        if (i < array.len - 1) {
            std.debug.print(", ", .{});
        } else {
            std.debug.print("\n", .{});
        }
    }
}

// test "one to montgomery" {
//     try std.testing.expectEqual(.{ 0xd35d438dc58f0d9d, 0xa78eb28f5c70b3d, 0x666ea36f7879462c, 0xe0a77c19a07df2f }, one);
// }
// test "one from montgomery" {
//     try std.testing.expectEqual(.{ 1, 0, 0, 0 }, from_montgomery_form(one));
// }

// test "add" {
//     const x = [_]u64{
//         0x3C208C16D87CFD46,
//         0x97816a916871ca8d,
//         0xb85045b68181585d,
//         0x30644e72e131a029,
//     };
//     // debugPrintArray(x);
//     const y = to_montgomery_form(x);
//     // debugPrintArray(y);
//     const z = add(y, one);
//     // debugPrintArray(z);
//     const a = from_montgomery_form(z);

//     try std.testing.expectEqual(.{ 0, 0, 0, 0 }, a);
// }
