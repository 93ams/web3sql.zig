//! Aave WadRayMath.sol. Mul and div round half up and fail exactly where the Solidity reverts:
//! a 256-bit intermediate overflow is an error even when the final quotient would fit.
const std = @import("std");
const math = @import("../../core/math/root.zig");
const fuzz = @import("../../core/fuzz.zig");

pub const WAD: u256 = 1_000_000_000_000_000_000; // 1e18
pub const RAY: u256 = 1_000_000_000_000_000_000_000_000_000; // 1e27
pub const HALF_WAD: u256 = WAD / 2;
pub const HALF_RAY: u256 = RAY / 2;

pub const LendingError = math.MathError;

const MAX = std.math.maxInt(u256);

/// (a * b + half) / unit, rejecting overflow of the numerator.
pub fn mulHalfUp(a: u256, b: u256, half: u256, unit: u256) LendingError!u256 {
    if (b != 0 and a > (MAX - half) / b) return LendingError.Overflow;
    return (a * b + half) / unit;
}

fn divHalfUp(a: u256, b: u256, unit: u256) LendingError!u256 {
    if (b == 0) return LendingError.DivisionByZero;
    if (a > (MAX - b / 2) / unit) return LendingError.Overflow;
    return (a * unit + b / 2) / b;
}

/// a * b in wad, rounded half up.
pub fn wadMul(a: u256, b: u256) LendingError!u256 {
    return mulHalfUp(a, b, HALF_WAD, WAD);
}

/// a / b in wad, rounded half up.
pub fn wadDiv(a: u256, b: u256) LendingError!u256 {
    return divHalfUp(a, b, WAD);
}

/// a * b in ray, rounded half up.
pub fn rayMul(a: u256, b: u256) LendingError!u256 {
    return mulHalfUp(a, b, HALF_RAY, RAY);
}

/// a / b in ray, rounded half up.
pub fn rayDiv(a: u256, b: u256) LendingError!u256 {
    return divHalfUp(a, b, RAY);
}

/// x^n in ray by squaring. Aave v3 dropped this; the source is v1 aave-protocol WadRayMath.sol.
pub fn rayPow(x: u256, n: u256) LendingError!u256 {
    var base = x;
    var exp = n / 2;
    var z = if (n % 2 != 0) x else RAY;
    while (exp != 0) : (exp /= 2) {
        base = try rayMul(base, base);
        if (exp % 2 != 0) z = try rayMul(z, base);
    }
    return z;
}

test "REQ-PROT-03 wad and ray match aave-v3-core wadraymath.spec.ts" {
    // Inputs from the spec; expected values from its formulas in helpers/utils/wadraymath.ts.
    const a: u256 = 134534543232342353231234;
    const b: u256 = 13265462389132757665657;
    try std.testing.expectEqual((a * b + HALF_WAD) / WAD, try wadMul(a, b));
    try std.testing.expectEqual((a * WAD + b / 2) / b, try wadDiv(a, b));
    try std.testing.expectEqual((a * b + HALF_RAY) / RAY, try rayMul(a, b));
    try std.testing.expectEqual((a * RAY + b / 2) / b, try rayDiv(a, b));
    try std.testing.expectEqual(@as(u256, 0), try wadMul(0, b));
    try std.testing.expectEqual(@as(u256, 0), try rayMul(a, 0));
    try std.testing.expectEqual(6 * WAD, try wadMul(2 * WAD, 3 * WAD));
}

test "REQ-PROT-03 overflow fails at the Solidity boundary" {
    const b: u256 = 13265462389132757665657;
    const wad_limit = (MAX - HALF_WAD) / b;
    _ = try wadMul(wad_limit, b);
    try std.testing.expectError(LendingError.Overflow, wadMul(wad_limit + 1, b));
    const ray_limit = (MAX - HALF_RAY) / b;
    _ = try rayMul(ray_limit, b);
    try std.testing.expectError(LendingError.Overflow, rayMul(ray_limit + 1, b));
    const wad_div_limit = (MAX - b / 2) / WAD;
    _ = try wadDiv(wad_div_limit, b);
    try std.testing.expectError(LendingError.Overflow, wadDiv(wad_div_limit + 1, b));
    const ray_div_limit = (MAX - b / 2) / RAY;
    _ = try rayDiv(ray_div_limit, b);
    try std.testing.expectError(LendingError.Overflow, rayDiv(ray_div_limit + 1, b));
    try std.testing.expectError(LendingError.DivisionByZero, wadDiv(1, 0));
    try std.testing.expectError(LendingError.DivisionByZero, rayDiv(1, 0));
}

test "REQ-PROT-03 half rounds up at the exact boundary" {
    try std.testing.expectEqual(@as(u256, 0), try rayMul(1, HALF_RAY - 1));
    try std.testing.expectEqual(@as(u256, 1), try rayMul(1, HALF_RAY));
    try std.testing.expectEqual(@as(u256, 0), try wadMul(1, HALF_WAD - 1));
    try std.testing.expectEqual(@as(u256, 1), try wadMul(1, HALF_WAD));
    // rayDiv(1, b) is exactly one half at b = 2 * RAY, and below it just past that.
    try std.testing.expectEqual(@as(u256, 1), try rayDiv(1, 2 * RAY));
    try std.testing.expectEqual(@as(u256, 0), try rayDiv(1, 2 * RAY + 2));
    try std.testing.expectEqual(@as(u256, 1), try wadDiv(1, 2 * WAD));
    try std.testing.expectEqual(@as(u256, 0), try wadDiv(1, 2 * WAD + 2));
}

test "REQ-PROT-03 rayPow" {
    const x = RAY + RAY / 100; // 1.01
    try std.testing.expectEqual(RAY, try rayPow(x, 0));
    try std.testing.expectEqual(x, try rayPow(x, 1));
    try std.testing.expectEqual(10201 * RAY / 10000, try rayPow(x, 2));
    try std.testing.expectEqual(1030301 * RAY / 1000000, try rayPow(x, 3));
    try std.testing.expectEqual(RAY, try rayPow(RAY, MAX));
    try std.testing.expectEqual(@as(u256, 0), try rayPow(0, 5));
    try std.testing.expectError(LendingError.Overflow, rayPow(MAX, 2));
}

fn exercise(_: void, bytes: []const u8) void {
    var input: [64]u8 = @splat(0);
    const n = @min(bytes.len, input.len);
    @memcpy(input[0..n], bytes[0..n]);
    const a = std.mem.readInt(u256, input[0..32], .little);
    const b = std.mem.readInt(u256, input[32..64], .little);

    // Oracle: the checks must reject exactly what the 512-bit formula cannot fit in 256 bits.
    const product = @as(u512, a) * b + HALF_RAY;
    if (rayMul(a, b)) |c| {
        std.debug.assert(c == product / RAY);
    } else |_| {
        std.debug.assert(product > MAX);
    }
    if (b != 0) {
        const scaled = @as(u512, a) * RAY + b / 2;
        if (rayDiv(a, b)) |c| {
            std.debug.assert(c == scaled / b);
        } else |_| {
            std.debug.assert(scaled > MAX);
        }
    }
    _ = wadMul(a, b) catch {};
    _ = wadDiv(a, b) catch {};
    _ = rayPow(a, b) catch {};
}

test "REQ-PROT-03 ray and wad fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [64]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-03 ray and wad stress" {
    var seed: [64]u8 = @splat(0);
    std.mem.writeInt(u256, seed[0..32], RAY, .little);
    std.mem.writeInt(u256, seed[32..64], 3 * RAY / 2, .little);
    fuzz.stress(200_000, &.{&seed}, {}, exercise);
}
