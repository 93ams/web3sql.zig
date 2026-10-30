//! Uniswap v3/v4 Q64.96 math: exact ports of v3-core TickMath.sol and SqrtPriceMath.sol.
const std = @import("std");
const math = @import("../../core/math/root.zig");
const fuzz = @import("../../core/fuzz.zig");
const price = @import("price.zig");
const vectors = @import("tick_vectors.zig");

pub const ClmmError = price.ClmmError;

pub const Q96: u256 = @as(u256, 1) << 96;
pub const MIN_TICK: i32 = -887272;
pub const MAX_TICK: i32 = 887272;
pub const MIN_SQRT_RATIO: u160 = 4295128739;
pub const MAX_SQRT_RATIO: u160 = 1461446703485210103287273052203988822378723970342;

/// TickMath.sol factors for tick bits 1..19. Each is sqrt(1.0001)^-(2^bit) in Q128.128.
const RATIOS = [_]u256{
    0xfff97272373d413259a46990580e213a,
    0xfff2e50f5f656932ef12357cf3c7fdcc,
    0xffe5caca7e10e4e61c3624eaa0941cd0,
    0xffcb9843d60f6159c9db58835c926644,
    0xff973b41fa98c081472e6896dfb254c0,
    0xff2ea16466c96a3843ec78b326b52861,
    0xfe5dee046a99a2a811c461f1969c3053,
    0xfcbe86c7900a88aedcffc83b479aa3a4,
    0xf987a7253ac413176f2b074cf7815e54,
    0xf3392b0822b70005940c7a398e4b70f3,
    0xe7159475a2c29b7443b29c7fa6e889d9,
    0xd097f3bdfd2022b8845ad8f792aa5825,
    0xa9f746462d870fdf8a65dc1f90e061e5,
    0x70d869a156d2a1b890bb3df62baf32f7,
    0x31be135f97d08fd981231505542fcfa6,
    0x9aa508b5b7a84e1c677de54f3e99bc9,
    0x5d6af8dedb81196699c329225ee604,
    0x2216e584f5fa1ea926041bedfe98,
    0x48a170391f7dc42444e8fa2,
};

/// sqrt(1.0001^tick) as Q64.96. TickOutOfRange when |tick| > 887272.
pub fn getSqrtRatioAtTick(tick: i32) ClmmError!u160 {
    const abs_tick = @abs(tick);
    if (abs_tick > MAX_TICK) return ClmmError.TickOutOfRange;

    var ratio: u256 = if (abs_tick & 1 != 0) 0xfffcb933bd6fad37aa2d162d1a594001 else @as(u256, 1) << 128;
    for (RATIOS, 1..) |factor, bit| {
        if ((abs_tick >> @intCast(bit)) & 1 != 0) ratio = (ratio * factor) >> 128;
    }
    if (tick > 0) ratio = std.math.maxInt(u256) / ratio;

    // Rounds up so that getTickAtSqrtRatio of the output is consistent.
    return @intCast((ratio >> 32) + @intFromBool(ratio & 0xffffffff != 0));
}

/// Greatest tick whose ratio is <= `sqrt_price_x96`. MAX_SQRT_RATIO itself is rejected, as in TickMath.sol.
pub fn getTickAtSqrtRatio(sqrt_price_x96: u160) ClmmError!i32 {
    if (sqrt_price_x96 < MIN_SQRT_RATIO or sqrt_price_x96 >= MAX_SQRT_RATIO) return ClmmError.SqrtPriceOutOfRange;
    const ratio = @as(u256, sqrt_price_x96) << 32;
    const msb: u8 = @intCast(255 - @as(u16, @clz(ratio)));

    var r: u256 = if (msb >= 128) ratio >> (msb - 127) else ratio << (127 - msb);
    var log_2: i256 = (@as(i256, msb) - 128) << 64;
    var bit: u8 = 63;
    while (bit >= 50) : (bit -= 1) {
        r = (r * r) >> 127;
        const f: u8 = @intCast(r >> 128);
        log_2 |= @as(i256, f) << bit;
        r >>= f;
    }

    const log_sqrt10001 = log_2 * 255738958999603826347141; // Q128.128
    const tick_low: i32 = @intCast((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128);
    const tick_high: i32 = @intCast((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128);
    if (tick_low == tick_high) return tick_low;
    return if (try getSqrtRatioAtTick(tick_high) <= sqrt_price_x96) tick_high else tick_low;
}

/// SqrtPriceMath.getAmount0Delta: liquidity * (sqrtB - sqrtA) / (sqrtA * sqrtB), sorted inputs.
pub fn getAmount0Delta(sqrt_a: u160, sqrt_b: u160, liquidity: u128, round_up: bool) ClmmError!u256 {
    const lower = @min(sqrt_a, sqrt_b);
    const upper = @max(sqrt_a, sqrt_b);
    if (lower == 0) return ClmmError.DivisionByZero;
    const numerator1 = @as(u256, liquidity) << 96;
    const numerator2: u256 = upper - lower;
    if (round_up) {
        const x = try math.mulDivRoundingUp(numerator1, numerator2, upper);
        return x / lower + @intFromBool(x % lower != 0);
    }
    return try math.mulDiv(numerator1, numerator2, upper) / lower;
}

/// SqrtPriceMath.getAmount1Delta: liquidity * (sqrtB - sqrtA), sorted inputs.
pub fn getAmount1Delta(sqrt_a: u160, sqrt_b: u160, liquidity: u128, round_up: bool) ClmmError!u256 {
    const diff: u256 = @max(sqrt_a, sqrt_b) - @min(sqrt_a, sqrt_b);
    if (round_up) return math.mulDivRoundingUp(liquidity, diff, Q96);
    return math.mulDiv(liquidity, diff, Q96);
}

/// Signed helper: positive liquidity rounds up, negative rounds down and negates.
pub fn getAmount0DeltaSigned(sqrt_a: u160, sqrt_b: u160, liquidity: i128) ClmmError!i256 {
    return signed(try getAmount0Delta(sqrt_a, sqrt_b, @abs(liquidity), liquidity >= 0), liquidity);
}

/// Signed helper: positive liquidity rounds up, negative rounds down and negates.
pub fn getAmount1DeltaSigned(sqrt_a: u160, sqrt_b: u160, liquidity: i128) ClmmError!i256 {
    return signed(try getAmount1Delta(sqrt_a, sqrt_b, @abs(liquidity), liquidity >= 0), liquidity);
}

fn signed(amount: u256, liquidity: i128) ClmmError!i256 {
    const value = std.math.cast(i256, amount) orelse return ClmmError.Overflow;
    return if (liquidity < 0) -value else value;
}

/// Raw price as Q128.128: sqrtPriceX96^2 >> 64.
pub fn sqrtPriceX96ToPriceX128(sqrt_price_x96: u160) u256 {
    const wide: u320 = sqrt_price_x96;
    return @intCast((wide * wide) >> 64);
}

/// Price of token0 in token1 units as a decimal with `scale` fractional digits, truncated.
pub fn sqrtPriceX96ToDecimal(sqrt_price_x96: u160, decimals0: u8, decimals1: u8, scale: u8, dest: []u8) ClmmError![]const u8 {
    const wide: u320 = sqrt_price_x96;
    const square = wide * wide;
    const frac: u192 = @truncate(square);
    return price.renderPrice(@intCast(square >> 192), frac, 192, decimals0, decimals1, scale, dest);
}

/// Price at `tick`, rendered as `sqrtPriceX96ToDecimal` does.
pub fn tickToDecimal(tick: i32, decimals0: u8, decimals1: u8, scale: u8, dest: []u8) ClmmError![]const u8 {
    return sqrtPriceX96ToDecimal(try getSqrtRatioAtTick(tick), decimals0, decimals1, scale, dest);
}

test "REQ-PROT-01 getSqrtRatioAtTick matches the Uniswap snapshot" {
    for (vectors.SQRT_AT_TICK) |v| try std.testing.expectEqual(v.sqrt, try getSqrtRatioAtTick(v.tick));
    // v3-core test/TickMath.spec.ts boundary cases.
    try std.testing.expectEqual(@as(u160, 4295128739), try getSqrtRatioAtTick(MIN_TICK));
    try std.testing.expectEqual(@as(u160, 4295343490), try getSqrtRatioAtTick(MIN_TICK + 1));
    try std.testing.expectEqual(@as(u160, 1461373636630004318706518188784493106690254656249), try getSqrtRatioAtTick(MAX_TICK - 1));
    try std.testing.expectEqual(MAX_SQRT_RATIO, try getSqrtRatioAtTick(MAX_TICK));
    try std.testing.expectError(ClmmError.TickOutOfRange, getSqrtRatioAtTick(MIN_TICK - 1));
    try std.testing.expectError(ClmmError.TickOutOfRange, getSqrtRatioAtTick(MAX_TICK + 1));
    try std.testing.expectError(ClmmError.TickOutOfRange, getSqrtRatioAtTick(std.math.minInt(i32)));
}

test "REQ-PROT-01 getTickAtSqrtRatio matches the Uniswap snapshot" {
    for (vectors.TICK_AT_SQRT) |v| try std.testing.expectEqual(v.tick, try getTickAtSqrtRatio(v.sqrt));
    // v3-core test/TickMath.spec.ts boundary cases.
    try std.testing.expectEqual(MIN_TICK, try getTickAtSqrtRatio(MIN_SQRT_RATIO));
    try std.testing.expectEqual(MIN_TICK + 1, try getTickAtSqrtRatio(4295343490));
    try std.testing.expectEqual(MAX_TICK - 1, try getTickAtSqrtRatio(1461373636630004318706518188784493106690254656249));
    try std.testing.expectEqual(MAX_TICK - 1, try getTickAtSqrtRatio(MAX_SQRT_RATIO - 1));
    try std.testing.expectError(ClmmError.SqrtPriceOutOfRange, getTickAtSqrtRatio(MIN_SQRT_RATIO - 1));
    try std.testing.expectError(ClmmError.SqrtPriceOutOfRange, getTickAtSqrtRatio(MAX_SQRT_RATIO));
}

// shortcut: strided to keep Debug tests fast, the lane report records a one-off exhaustive run.
test "REQ-PROT-01 tick round trip brackets every sampled ratio" {
    var tick: i32 = MIN_TICK;
    while (tick < MAX_TICK) : (tick += 997) {
        const ratio = try getSqrtRatioAtTick(tick);
        const next = try getSqrtRatioAtTick(tick + 1);
        try std.testing.expect(ratio < next);
        try std.testing.expectEqual(tick, try getTickAtSqrtRatio(ratio));
        try std.testing.expectEqual(tick, try getTickAtSqrtRatio(next - 1));
    }
}

// encodePriceSqrt(121, 100) from v3-core test/shared/utilities.ts: floor(sqrt(1.21) * 2^96) is 1.1 * 2^96.
const SQRT_1_21: u160 = 87150978765690771352898345369;
const E18: u128 = 1_000_000_000_000_000_000;

test "REQ-PROT-01 getAmount deltas match SqrtPriceMath.spec.ts" {
    const one: u160 = @intCast(Q96);
    try std.testing.expectEqual(@as(u256, 90909090909090910), try getAmount0Delta(one, SQRT_1_21, E18, true));
    try std.testing.expectEqual(@as(u256, 90909090909090909), try getAmount0Delta(one, SQRT_1_21, E18, false));
    try std.testing.expectEqual(@as(u256, 100000000000000000), try getAmount1Delta(one, SQRT_1_21, E18, true));
    try std.testing.expectEqual(@as(u256, 99999999999999999), try getAmount1Delta(one, SQRT_1_21, E18, false));
    try std.testing.expectEqual(@as(u256, 0), try getAmount0Delta(one, SQRT_1_21, 0, true));
    try std.testing.expectEqual(try getAmount0Delta(one, SQRT_1_21, E18, true), try getAmount0Delta(SQRT_1_21, one, E18, true));
    try std.testing.expectError(ClmmError.DivisionByZero, getAmount0Delta(0, one, E18, true));

    try std.testing.expectEqual(@as(i256, 90909090909090910), try getAmount0DeltaSigned(one, SQRT_1_21, E18));
    try std.testing.expectEqual(@as(i256, -90909090909090909), try getAmount0DeltaSigned(one, SQRT_1_21, -@as(i128, E18)));
    try std.testing.expectEqual(@as(i256, 100000000000000000), try getAmount1DeltaSigned(one, SQRT_1_21, E18));
    try std.testing.expectEqual(@as(i256, -99999999999999999), try getAmount1DeltaSigned(one, SQRT_1_21, -@as(i128, E18)));
    _ = try getAmount1DeltaSigned(one, SQRT_1_21, std.math.minInt(i128));
}

test "REQ-PROT-01 mulDivRoundingUp rounds only inexact quotients" {
    // v3-core test/FullMath.spec.ts shape: exact quotient stays, remainder adds one.
    try std.testing.expectEqual(@as(u256, 2), try math.mulDivRoundingUp(1, 2, 1));
    try std.testing.expectEqual(@as(u256, 1), try math.mulDivRoundingUp(1, 1, 3));
    try std.testing.expectEqual(@as(u256, 0), try math.mulDiv(1, 1, 3));
}

test "REQ-PROT-01 sqrtPriceX96 renders exact scaled decimals" {
    var buf: [128]u8 = undefined;
    const one: u160 = @intCast(Q96);
    try std.testing.expectEqualStrings("1.0000", try sqrtPriceX96ToDecimal(one, 18, 18, 4, &buf));
    try std.testing.expectEqualStrings("2.25", try sqrtPriceX96ToDecimal(one + one / 2, 6, 6, 2, &buf));
    try std.testing.expectEqualStrings("1000000000000.0", try sqrtPriceX96ToDecimal(one, 18, 6, 1, &buf));
    try std.testing.expectEqualStrings("0.000001", try sqrtPriceX96ToDecimal(one, 6, 12, 6, &buf));
    try std.testing.expectEqual(@as(u256, 1) << 128, sqrtPriceX96ToPriceX128(one));
    try std.testing.expectError(ClmmError.BufferTooSmall, sqrtPriceX96ToDecimal(one, 18, 18, 18, buf[0..4]));
}

fn expectNear(text: []const u8, expected_e18: u256) !void {
    var digits: [80]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '.') continue;
        digits[n] = c;
        n += 1;
    }
    const value = try math.parseDecimal(digits[0..n]);
    const diff = @max(value, expected_e18) - @min(value, expected_e18);
    try std.testing.expect(diff <= expected_e18 / 10_000); // the source rounds to 5 significant digits
}

test "REQ-PROT-01 tick to price matches v3-sdk priceTickConversions.test.ts" {
    var buf: [128]u8 = undefined;
    try expectNear(try tickToDecimal(74959, 18, 18, 18, &buf), 1800 * E18);
    try expectNear(try tickToDecimal(-74959, 18, 18, 18, &buf), 555560000000000);
    try expectNear(try tickToDecimal(-276225, 18, 6, 18, &buf), 1010000000000000000);
    try expectNear(try tickToDecimal(-276423, 18, 6, 18, &buf), 990150000000000000);
}

fn exercise(_: void, bytes: []const u8) void {
    var input: [64]u8 = @splat(0);
    const n = @min(bytes.len, input.len);
    @memcpy(input[0..n], bytes[0..n]);
    const tick = std.mem.readInt(i32, input[0..4], .little);
    const sqrt_a = std.mem.readInt(u160, input[4..24], .little);
    const sqrt_b = std.mem.readInt(u160, input[24..44], .little);
    const liquidity = std.mem.readInt(i128, input[44..60], .little);

    // Small ticks and in-range ratios reach the deep paths; raw values cover rejection.
    const near_tick = @rem(tick, MAX_TICK + 2);
    if (getSqrtRatioAtTick(near_tick)) |ratio| {
        if (near_tick < MAX_TICK) std.debug.assert((getTickAtSqrtRatio(ratio) catch @panic("oracle: valid input rejected")) == near_tick);
    } else |_| {}
    const in_range = MIN_SQRT_RATIO + sqrt_a % (MAX_SQRT_RATIO - MIN_SQRT_RATIO);
    const found = getTickAtSqrtRatio(in_range) catch @panic("oracle: valid input rejected");
    std.debug.assert((getSqrtRatioAtTick(found) catch @panic("oracle: valid input rejected")) <= in_range);
    _ = getTickAtSqrtRatio(sqrt_a) catch {};
    _ = getSqrtRatioAtTick(tick) catch {};
    _ = getAmount0DeltaSigned(sqrt_a, sqrt_b, liquidity) catch {};
    _ = getAmount1DeltaSigned(sqrt_a, sqrt_b, liquidity) catch {};

    var dest: [700]u8 = undefined;
    _ = sqrtPriceX96ToDecimal(sqrt_a, input[60], input[61], input[62], &dest) catch @panic("oracle: valid input rejected");
    _ = sqrtPriceX96ToDecimal(sqrt_a, input[60], input[61], input[62], dest[0 .. input[63] % 64]) catch {};
    _ = tickToDecimal(near_tick, input[60], input[61], input[62], &dest) catch {};
}

test "REQ-PROT-01 q64.96 fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [64]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-01 q64.96 stress" {
    var seed: [64]u8 = @splat(0);
    std.mem.writeInt(i32, seed[0..4], -276225, .little);
    std.mem.writeInt(u160, seed[4..24], MIN_SQRT_RATIO, .little);
    std.mem.writeInt(u160, seed[24..44], MAX_SQRT_RATIO - 1, .little);
    std.mem.writeInt(i128, seed[44..60], @as(i128, E18), .little);
    seed[60] = 18;
    seed[61] = 6;
    seed[62] = 18;
    seed[63] = 40;
    fuzz.stress(200_000, &.{&seed}, {}, exercise);
}
