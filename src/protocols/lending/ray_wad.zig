const std = @import("std");
const math = @import("../../core/math/root.zig");

pub const WAD: u256 = 1_000_000_000_000_000_000; // 1e18
pub const RAY: u256 = 1_000_000_000_000_000_000_000_000_000; // 1e27
pub const HALF_WAD: u256 = WAD / 2;
pub const HALF_RAY: u256 = RAY / 2;

pub const LendingError = error{
    DivisionByZero,
    Overflow,
};

/// Multiplies two WAD numbers with rounding to half: (a * b + HALF_WAD) / WAD.
pub fn wadMul(a: u256, b: u256) LendingError!u256 {
    const wide_a: u512 = a;
    const wide_b: u512 = b;
    const prod: u512 = wide_a * wide_b + HALF_WAD;
    const res = prod / WAD;
    if (res > std.math.maxInt(u256)) return LendingError.Overflow;
    return @intCast(res);
}

/// Multiplies two RAY numbers with rounding to half: (a * b + HALF_RAY) / RAY.
pub fn rayMul(a: u256, b: u256) LendingError!u256 {
    const wide_a: u512 = a;
    const wide_b: u512 = b;
    const prod: u512 = wide_a * wide_b + HALF_RAY;
    const res = prod / RAY;
    if (res > std.math.maxInt(u256)) return LendingError.Overflow;
    return @intCast(res);
}

test "ray and wad math" {
    const a = 2 * WAD;
    const b = 3 * WAD;
    const res = try wadMul(a, b);
    try std.testing.expectEqual(6 * WAD, res);
}
