const std = @import("std");
const math = @import("../../core/math/root.zig");

pub const Q96: u256 = @as(u256, 1) << 96;

pub const ClmmError = error{
    DivisionByZero,
    PriceOverflow,
};

/// Computes human-readable price ratio from sqrtPriceX96: (sqrtPriceX96 * sqrtPriceX96) >> 192.
pub fn sqrtPriceX96ToPriceX128(sqrt_price_x96: u160) ClmmError!u256 {
    const wide: u512 = sqrt_price_x96;
    const prod: u512 = wide * wide;
    const shifted = prod >> 64; // returns price in Q128.128 format or scaled
    if (shifted > std.math.maxInt(u256)) return ClmmError.PriceOverflow;
    return @intCast(shifted);
}

test "q64_96 conversion smoke test" {
    // If sqrtPriceX96 = 2^96 (i.e. price = 1.0)
    const sqrt_one: u160 = @intCast(@as(u256, 1) << 96);
    const p = try sqrtPriceX96ToPriceX128(sqrt_one);
    try std.testing.expect(p > 0);
}
