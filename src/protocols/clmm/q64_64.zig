const std = @import("std");

pub const Q64: u128 = @as(u128, 1) << 64;

pub const ClmmError = error{
    Overflow,
    DivisionByZero,
};

/// Converts sqrtPriceX64 (used in Orca Whirlpools / Raydium CLMM) to price with Q64.64 precision.
pub fn sqrtPriceX64ToPriceX64(sqrt_price_x64: u128) ClmmError!u128 {
    const wide: u256 = sqrt_price_x64;
    const prod: u256 = wide * wide;
    const res = prod >> 64;
    if (res > std.math.maxInt(u128)) return ClmmError.Overflow;
    return @intCast(res);
}

test "q64_64 conversion smoke test" {
    const sqrt_one: u128 = @as(u128, 1) << 64;
    const p = try sqrtPriceX64ToPriceX64(sqrt_one);
    try std.testing.expectEqual(sqrt_one, p);
}
