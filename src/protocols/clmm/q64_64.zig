//! Q64.64 CLMM math for Orca Whirlpools, Cetus and Raydium CLMM.
//!
//! The three diverge, so each keeps its own entry points:
//! - Tick to sqrt price: Orca and Cetus share constants and results. Raydium uses truncated 64-bit
//!   factors and a final u128::MAX division, so its values differ, including MAX_SQRT_PRICE.
//! - Sqrt price to tick: log-base constant is 59543866431248 (Orca, Raydium) or 59543866431366 (Cetus);
//!   precision is 14 bits (Orca, Cetus) or 16 bits (Raydium).
//! - Upper bound of sqrt price to tick: Raydium excludes MAX, Cetus includes it, Orca checks nothing.
//!   Here Orca's documented range [MIN, MAX] is enforced, and errors replace on-chain aborts.
const std = @import("std");
const fuzz = @import("../../core/fuzz.zig");
const price = @import("price.zig");
const vectors = @import("tick_vectors.zig");

pub const ClmmError = price.ClmmError;

pub const Q64: u128 = @as(u128, 1) << 64;
pub const MIN_TICK: i32 = -443636;
pub const MAX_TICK: i32 = 443636;
pub const MIN_SQRT_PRICE_X64: u128 = 4295048016;
/// Orca and Cetus upper bound.
pub const MAX_SQRT_PRICE_X64: u128 = 79226673515401279992447579055;
/// Raydium upper bound.
pub const RAYDIUM_MAX_SQRT_PRICE_X64: u128 = 79226673521066979257578248091;

/// Orca tick_math.rs get_sqrt_price_positive_tick factors for bits 1..18, identical in Cetus tick_math.move.
const POSITIVE = [_]u128{
    79236085330515764027303304731,
    79244008939048815603706035061,
    79259858533276714757314932305,
    79291567232598584799939703904,
    79355022692464371645785046466,
    79482085999252804386437311141,
    79736823300114093921829183326,
    80248749790819932309965073892,
    81282483887344747381513967011,
    83390072131320151908154831281,
    87770609709833776024991924138,
    97234110755111693312479820773,
    119332217159966728226237229890,
    179736315981702064433883588727,
    407748233172238350107850275304,
    2098478828474011932436660412517,
    55581415166113811149459800483533,
    38992368544603139932233054999993551,
};

/// Orca tick_math.rs get_sqrt_price_negative_tick factors for bits 1..18, identical in Cetus tick_math.move.
const NEGATIVE = [_]u128{
    18444899583751176498,
    18443055278223354162,
    18439367220385604838,
    18431993317065449817,
    18417254355718160513,
    18387811781193591352,
    18329067761203520168,
    18212142134806087854,
    17980523815641551639,
    17526086738831147013,
    16651378430235024244,
    15030750278693429944,
    12247334978882834399,
    8131365268884726200,
    3584323654723342297,
    696457651847595233,
    26294789957452057,
    37481735321082,
};

/// Raydium tick_math.rs factors for bits 1..18.
const RAYDIUM = [_]u128{
    0xfff97272373d4000,
    0xfff2e50f5f657000,
    0xffe5caca7e10f000,
    0xffcb9843d60f7000,
    0xff973b41fa98e800,
    0xff2ea16466c9b000,
    0xfe5dee046a9a3800,
    0xfcbe86c7900bb000,
    0xf987a7253ac65800,
    0xf3392b0822bb6000,
    0xe7159475a2caf000,
    0xd097f3bdfd2f2000,
    0xa9f746462d9f8000,
    0x70d869a156f31c00,
    0x31be135f97ed3200,
    0x9aa508b5b85a500,
    0x5d6af8dedc582c,
    0x2216e584f5fa,
};

/// Orca `sqrt_price_from_tick_index`. Also Cetus `get_sqrt_price_at_tick`, which has the same tables.
pub fn orcaSqrtPriceFromTick(tick: i32) ClmmError!u128 {
    const abs_tick = @abs(tick);
    if (abs_tick > MAX_TICK) return ClmmError.TickOutOfRange;
    if (tick >= 0) {
        var ratio: u256 = if (abs_tick & 1 != 0) 79232123823359799118286999567 else 79228162514264337593543950336;
        for (POSITIVE, 1..) |factor, bit| {
            if ((abs_tick >> @intCast(bit)) & 1 != 0) ratio = (ratio * factor) >> 96;
        }
        return @intCast(ratio >> 32);
    }
    var ratio: u128 = if (abs_tick & 1 != 0) 18445821805675392311 else Q64;
    for (NEGATIVE, 1..) |factor, bit| {
        if ((abs_tick >> @intCast(bit)) & 1 != 0) ratio = (ratio * factor) >> 64;
    }
    return ratio;
}

pub const cetusSqrtPriceFromTick = orcaSqrtPriceFromTick;

/// Raydium `get_sqrt_price_at_tick`.
pub fn raydiumSqrtPriceFromTick(tick: i32) ClmmError!u128 {
    const abs_tick = @abs(tick);
    if (abs_tick > MAX_TICK) return ClmmError.TickOutOfRange;
    var ratio: u128 = if (abs_tick & 1 != 0) 0xfffcb933bd6fb800 else Q64;
    for (RAYDIUM, 1..) |factor, bit| {
        if ((abs_tick >> @intCast(bit)) & 1 != 0) ratio = (ratio * factor) >> 64;
    }
    return if (tick > 0) std.math.maxInt(u128) / ratio else ratio;
}

/// Shared log2 search: integer part from the msb, then `precision` squarings, then a two-candidate check.
fn tickFromSqrtPrice(
    sqrt_price: u128,
    precision: u8,
    log_b_2_x32: i128,
    comptime sqrtAt: fn (i32) ClmmError!u128,
) ClmmError!i32 {
    const msb: u7 = @intCast(127 - @as(u16, @clz(sqrt_price)));
    var r: u128 = if (msb >= 64) sqrt_price >> (msb - 63) else sqrt_price << (63 - msb);
    var fraction_x64: i128 = 0;
    var bit: i128 = 0x8000_0000_0000_0000;
    for (0..precision) |_| {
        r *= r;
        const more_than_two: u8 = @intCast(r >> 127);
        r >>= @intCast(63 + more_than_two);
        fraction_x64 += bit * more_than_two;
        bit >>= 1;
    }
    const log2_x32 = ((@as(i128, msb) - 64) << 32) + (fraction_x64 >> 32);
    const log_b_x64 = log2_x32 * log_b_2_x32;
    const tick_low: i32 = @intCast((log_b_x64 - 184467440737095516) >> 64);
    const tick_high: i32 = @intCast((log_b_x64 + 15793534762490258745) >> 64);
    if (tick_low == tick_high) return tick_low;
    return if (try sqrtAt(tick_high) <= sqrt_price) tick_high else tick_low;
}

/// Orca `tick_index_from_sqrt_price`, range [MIN, MAX].
pub fn orcaTickFromSqrtPrice(sqrt_price_x64: u128) ClmmError!i32 {
    if (sqrt_price_x64 < MIN_SQRT_PRICE_X64 or sqrt_price_x64 > MAX_SQRT_PRICE_X64) return ClmmError.SqrtPriceOutOfRange;
    return tickFromSqrtPrice(sqrt_price_x64, 14, 59543866431248, orcaSqrtPriceFromTick);
}

/// Cetus `get_tick_at_sqrt_price`, range [MIN, MAX].
pub fn cetusTickFromSqrtPrice(sqrt_price_x64: u128) ClmmError!i32 {
    if (sqrt_price_x64 < MIN_SQRT_PRICE_X64 or sqrt_price_x64 > MAX_SQRT_PRICE_X64) return ClmmError.SqrtPriceOutOfRange;
    return tickFromSqrtPrice(sqrt_price_x64, 14, 59543866431366, cetusSqrtPriceFromTick);
}

/// Raydium `get_tick_at_sqrt_price`, range [MIN, MAX).
pub fn raydiumTickFromSqrtPrice(sqrt_price_x64: u128) ClmmError!i32 {
    if (sqrt_price_x64 < MIN_SQRT_PRICE_X64 or sqrt_price_x64 >= RAYDIUM_MAX_SQRT_PRICE_X64) return ClmmError.SqrtPriceOutOfRange;
    return tickFromSqrtPrice(sqrt_price_x64, 16, 59543866431248, raydiumSqrtPriceFromTick);
}

/// Cetus stores ticks as integer_mate::i32 `{ bits: u32 }`, plain two's complement.
pub fn cetusTickFromBits(bits: u32) i32 {
    return @bitCast(bits);
}

/// Raw price as Q64.64: sqrtPriceX64^2 >> 64.
pub fn sqrtPriceX64ToPriceX64(sqrt_price_x64: u128) ClmmError!u128 {
    const wide: u256 = sqrt_price_x64;
    return std.math.cast(u128, (wide * wide) >> 64) orelse ClmmError.Overflow;
}

/// Price of token A in token B units as a decimal with `scale` fractional digits, truncated.
pub fn sqrtPriceX64ToDecimal(sqrt_price_x64: u128, decimals_a: u8, decimals_b: u8, scale: u8, dest: []u8) ClmmError![]const u8 {
    const wide: u256 = sqrt_price_x64;
    const square = wide * wide;
    const frac: u128 = @truncate(square);
    return price.renderPrice(@intCast(square >> 128), frac, 128, decimals_a, decimals_b, scale, dest);
}

test "REQ-PROT-01 Orca sqrt price matches test_exact_bit_values" {
    for (vectors.ORCA_BITS) |v| {
        try std.testing.expectEqual(v.positive, try orcaSqrtPriceFromTick(v.tick));
        try std.testing.expectEqual(v.negative, try orcaSqrtPriceFromTick(-v.tick));
    }
    try std.testing.expectEqual(MAX_SQRT_PRICE_X64, try orcaSqrtPriceFromTick(MAX_TICK));
    try std.testing.expectEqual(MIN_SQRT_PRICE_X64, try orcaSqrtPriceFromTick(MIN_TICK));
    try std.testing.expectError(ClmmError.TickOutOfRange, orcaSqrtPriceFromTick(MAX_TICK + 1));
    try std.testing.expectError(ClmmError.TickOutOfRange, orcaSqrtPriceFromTick(std.math.minInt(i32)));
}

test "REQ-PROT-01 Orca tick from sqrt price matches tick_math.rs tests" {
    try std.testing.expectEqual(MAX_TICK, try orcaTickFromSqrtPrice(MAX_SQRT_PRICE_X64));
    try std.testing.expectEqual(MIN_TICK, try orcaTickFromSqrtPrice(MIN_SQRT_PRICE_X64));
    try std.testing.expectEqual(MIN_TICK, try orcaTickFromSqrtPrice(MIN_SQRT_PRICE_X64 + 1));
    try std.testing.expectEqual(MAX_TICK - 1, try orcaTickFromSqrtPrice(MAX_SQRT_PRICE_X64 - 1));
    try std.testing.expectEqual(@as(i32, 0), try orcaTickFromSqrtPrice(Q64));
    try std.testing.expectEqual(@as(i32, 0), try orcaTickFromSqrtPrice(Q64 + 1));
    try std.testing.expectEqual(@as(i32, -1), try orcaTickFromSqrtPrice(Q64 - 1));
    try std.testing.expectError(ClmmError.SqrtPriceOutOfRange, orcaTickFromSqrtPrice(0));
    try std.testing.expectError(ClmmError.SqrtPriceOutOfRange, orcaTickFromSqrtPrice(MAX_SQRT_PRICE_X64 + 1));
}

test "REQ-PROT-01 Cetus matches tick_math_tests.move" {
    try std.testing.expectEqual(@as(u128, 6469134034), try cetusSqrtPriceFromTick(-435444));
    try std.testing.expectEqual(@as(u128, 13561044167458152057771544136), try cetusSqrtPriceFromTick(408332));
    try std.testing.expectEqual(@as(i32, -435444), try cetusTickFromSqrtPrice(6469134034));
    try std.testing.expectEqual(@as(i32, 408332), try cetusTickFromSqrtPrice(13561044167458152057771544136));
    var tick: i32 = 400800;
    while (tick <= 401200) : (tick += 1) {
        try std.testing.expectEqual(tick, try cetusTickFromSqrtPrice(try cetusSqrtPriceFromTick(tick)));
    }
    try std.testing.expectError(ClmmError.TickOutOfRange, cetusSqrtPriceFromTick(MAX_TICK + 1));
    try std.testing.expectError(ClmmError.SqrtPriceOutOfRange, cetusTickFromSqrtPrice(MAX_SQRT_PRICE_X64 + 1));
    try std.testing.expectError(ClmmError.SqrtPriceOutOfRange, cetusTickFromSqrtPrice(MIN_SQRT_PRICE_X64 - 1));
    try std.testing.expectEqual(MAX_TICK, try cetusTickFromSqrtPrice(MAX_SQRT_PRICE_X64));
}

test "REQ-PROT-01 Cetus I32 bits are two's complement" {
    // integer_mate i32.move neg_from(v) = (~v + 1) | (1 << 31).
    try std.testing.expectEqual(@as(i32, -443636), cetusTickFromBits((~@as(u32, 443636) +% 1) | (1 << 31)));
    try std.testing.expectEqual(@as(i32, 443636), cetusTickFromBits(443636));
}

test "REQ-PROT-01 Raydium matches tick_math.rs tests" {
    try std.testing.expectEqual(MIN_SQRT_PRICE_X64, try raydiumSqrtPriceFromTick(MIN_TICK));
    try std.testing.expectEqual(RAYDIUM_MAX_SQRT_PRICE_X64, try raydiumSqrtPriceFromTick(MAX_TICK));
    try std.testing.expectEqual(MIN_TICK, try raydiumTickFromSqrtPrice(MIN_SQRT_PRICE_X64));
    try std.testing.expectEqual(MAX_TICK - 1, try raydiumTickFromSqrtPrice(RAYDIUM_MAX_SQRT_PRICE_X64 - 1));
    try std.testing.expectError(ClmmError.SqrtPriceOutOfRange, raydiumTickFromSqrtPrice(RAYDIUM_MAX_SQRT_PRICE_X64));
    try std.testing.expectError(ClmmError.TickOutOfRange, raydiumSqrtPriceFromTick(MIN_TICK - 1));

    // tick_round_down
    for ([_]i32{ -28861, 28861 }) |tick| {
        const sqrt = try raydiumSqrtPriceFromTick(tick);
        try std.testing.expectEqual(tick, try raydiumTickFromSqrtPrice(sqrt));
        try std.testing.expectEqual(tick, try raydiumTickFromSqrtPrice(sqrt + 1));
        try std.testing.expectEqual(tick, try raydiumTickFromSqrtPrice(try raydiumSqrtPriceFromTick(tick + 1) - 1));
        try std.testing.expectEqual(tick - 1, try raydiumTickFromSqrtPrice(sqrt - 1));
    }
}

test "REQ-PROT-01 protocols diverge where the sources say they do" {
    try std.testing.expect(RAYDIUM_MAX_SQRT_PRICE_X64 != MAX_SQRT_PRICE_X64);
    try std.testing.expect(try raydiumSqrtPriceFromTick(1) != try orcaSqrtPriceFromTick(1));
    try std.testing.expect(try raydiumSqrtPriceFromTick(-1) != try orcaSqrtPriceFromTick(-1));
}

// shortcut: strided to keep Debug tests fast, the lane report records a one-off exhaustive run.
test "REQ-PROT-01 q64.64 round trip brackets every sampled tick" {
    var tick: i32 = MIN_TICK;
    while (tick < MAX_TICK) : (tick += 499) {
        const orca = try orcaSqrtPriceFromTick(tick);
        const ray = try raydiumSqrtPriceFromTick(tick);
        try std.testing.expectEqual(tick, try orcaTickFromSqrtPrice(orca));
        try std.testing.expectEqual(tick, try cetusTickFromSqrtPrice(orca));
        try std.testing.expectEqual(tick, try raydiumTickFromSqrtPrice(ray));
        try std.testing.expectEqual(tick, try orcaTickFromSqrtPrice(try orcaSqrtPriceFromTick(tick + 1) - 1));
        try std.testing.expectEqual(tick, try cetusTickFromSqrtPrice(try orcaSqrtPriceFromTick(tick + 1) - 1));
        try std.testing.expectEqual(tick, try raydiumTickFromSqrtPrice(try raydiumSqrtPriceFromTick(tick + 1) - 1));
    }
}

test "REQ-PROT-01 sqrtPriceX64 renders exact scaled decimals" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(Q64, try sqrtPriceX64ToPriceX64(Q64));
    try std.testing.expectError(ClmmError.Overflow, sqrtPriceX64ToPriceX64(std.math.maxInt(u128)));
    try std.testing.expectEqualStrings("1.00", try sqrtPriceX64ToDecimal(Q64, 6, 6, 2, &buf));
    try std.testing.expectEqualStrings("2.25", try sqrtPriceX64ToDecimal(Q64 + Q64 / 2, 9, 9, 2, &buf));
    // Orca price-math.ts sqrtPriceX64ToPrice: decimalsA - decimalsB scales the price up.
    try std.testing.expectEqualStrings("1000.000", try sqrtPriceX64ToDecimal(Q64, 9, 6, 3, &buf));
    try std.testing.expectEqualStrings("0.001", try sqrtPriceX64ToDecimal(Q64, 6, 9, 3, &buf));
}

fn exercise(_: void, bytes: []const u8) void {
    var input: [32]u8 = @splat(0);
    const n = @min(bytes.len, input.len);
    @memcpy(input[0..n], bytes[0..n]);
    const tick = std.mem.readInt(i32, input[0..4], .little);
    const sqrt = std.mem.readInt(u128, input[4..20], .little);

    const near_tick = @rem(tick, MAX_TICK + 2);
    if (orcaSqrtPriceFromTick(near_tick)) |value| {
        std.debug.assert((orcaTickFromSqrtPrice(value) catch @panic("oracle: valid input rejected")) == near_tick);
        std.debug.assert((cetusTickFromSqrtPrice(value) catch @panic("oracle: valid input rejected")) == near_tick);
    } else |_| {}
    if (raydiumSqrtPriceFromTick(near_tick)) |value| {
        if (near_tick < MAX_TICK) std.debug.assert((raydiumTickFromSqrtPrice(value) catch @panic("oracle: valid input rejected")) == near_tick);
    } else |_| {}

    const in_range = MIN_SQRT_PRICE_X64 + sqrt % (MAX_SQRT_PRICE_X64 - MIN_SQRT_PRICE_X64);
    _ = orcaTickFromSqrtPrice(in_range) catch @panic("oracle: valid input rejected");
    _ = cetusTickFromSqrtPrice(in_range) catch @panic("oracle: valid input rejected");
    _ = raydiumTickFromSqrtPrice(in_range) catch @panic("oracle: valid input rejected");
    _ = orcaTickFromSqrtPrice(sqrt) catch {};
    _ = cetusTickFromSqrtPrice(sqrt) catch {};
    _ = raydiumTickFromSqrtPrice(sqrt) catch {};
    _ = sqrtPriceX64ToPriceX64(sqrt) catch {};
    _ = cetusTickFromBits(@bitCast(tick));

    var dest: [700]u8 = undefined;
    _ = sqrtPriceX64ToDecimal(sqrt, input[20], input[21], input[22], &dest) catch @panic("oracle: valid input rejected");
    _ = sqrtPriceX64ToDecimal(sqrt, input[20], input[21], input[22], dest[0 .. input[23] % 64]) catch {};
}

test "REQ-PROT-01 q64.64 fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [32]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-01 q64.64 stress" {
    var seed: [32]u8 = @splat(0);
    std.mem.writeInt(i32, seed[0..4], -28861, .little);
    std.mem.writeInt(u128, seed[4..20], Q64, .little);
    seed[20] = 9;
    seed[21] = 6;
    seed[22] = 18;
    seed[23] = 40;
    fuzz.stress(200_000, &.{&seed}, {}, exercise);
}
