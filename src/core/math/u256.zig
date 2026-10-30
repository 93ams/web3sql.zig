const std = @import("std");

pub const U256 = u256;
pub const I256 = i256;
pub const U128 = u128;
pub const I128 = i128;

pub const MathError = error{
    Overflow,
    DivisionByZero,
};

/// Computes (a * b) / c with intermediate u512 precision to prevent intermediate overflow.
pub fn mulDiv(a: u256, b: u256, c: u256) MathError!u256 {
    if (c == 0) return MathError.DivisionByZero;
    const wide_a: u512 = a;
    const wide_b: u512 = b;
    const prod: u512 = wide_a * wide_b;
    const res: u512 = prod / c;
    if (res > std.math.maxInt(u256)) return MathError.Overflow;
    return @intCast(res);
}

/// Checked addition returning MathError on overflow.
pub fn checkedAdd(a: u256, b: u256) MathError!u256 {
    const res, const ov = @addWithOverflow(a, b);
    if (ov != 0) return MathError.Overflow;
    return res;
}

/// Checked subtraction returning MathError on overflow/underflow.
pub fn checkedSub(a: u256, b: u256) MathError!u256 {
    const res, const ov = @subWithOverflow(a, b);
    if (ov != 0) return MathError.Overflow;
    return res;
}

/// Checked multiplication returning MathError on overflow.
pub fn checkedMul(a: u256, b: u256) MathError!u256 {
    const res, const ov = @mulWithOverflow(a, b);
    if (ov != 0) return MathError.Overflow;
    return res;
}

test "u256 checked arithmetic" {
    const a: u256 = 1000;
    const b: u256 = 2000;
    try std.testing.expectEqual(@as(u256, 3000), try checkedAdd(a, b));
    try std.testing.expectEqual(@as(u256, 1000), try checkedSub(b, a));
    try std.testing.expectError(MathError.Overflow, checkedSub(a, b));
}

test "u256 mulDiv" {
    const a: u256 = 1 << 200;
    const b: u256 = 1 << 50;
    const c: u256 = 1 << 50;
    try std.testing.expectEqual(a, try mulDiv(a, b, c));
    try std.testing.expectError(MathError.DivisionByZero, mulDiv(a, b, 0));
}
