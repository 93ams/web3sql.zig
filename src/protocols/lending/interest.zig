//! Aave MathUtils.sol and the ReserveLogic index getters. Rates and indices are in ray.
//!
//! The compounded formula changed in v3.4 (aave-v3-origin, 2025): `calculateCompoundedInterest` is
//! the current one, `calculateCompoundedInterestLegacy` is v3.0 to v3.3 (aave-v3-core). They give
//! different values, so replaying history needs the formula live at that block.
const std = @import("std");
const math = @import("../../core/math/root.zig");
const fuzz = @import("../../core/fuzz.zig");
const ray_wad = @import("ray_wad.zig");

const RAY = ray_wad.RAY;
const rayMul = ray_wad.rayMul;

pub const LendingError = ray_wad.LendingError;

/// Ignores leap years, as MathUtils does.
pub const SECONDS_PER_YEAR: u256 = 365 * 24 * 60 * 60;

/// RAY + rate * dt / year. A timestamp running backwards is Overflow, as the checked subtraction reverts.
pub fn calculateLinearInterest(rate: u256, last_update: u64, now: u64) LendingError!u256 {
    const elapsed = try math.checkedSub(now, last_update);
    return math.checkedAdd(RAY, try math.checkedMul(rate, @as(u256, elapsed)) / SECONDS_PER_YEAR);
}

/// Third-order binomial approximation of (1 + r)^n, v3.4 and later. The Solidity runs this
/// unchecked, assuming rate < 2^128; beyond that this returns Overflow instead of wrapping.
pub fn calculateCompoundedInterest(rate: u256, last_update: u64, now: u64) LendingError!u256 {
    const elapsed: u256 = try math.checkedSub(now, last_update);
    if (elapsed == 0) return RAY;
    const x = try math.checkedMul(rate, elapsed) / SECONDS_PER_YEAR;
    const tail = try rayMul(x, try math.checkedAdd(x / 2, try rayMul(x, x / 6)));
    return math.checkedAdd(try math.checkedAdd(RAY, x), tail);
}

/// Same approximation as computed by v3.0 to v3.3, dividing before multiplying.
pub fn calculateCompoundedInterestLegacy(rate: u256, last_update: u64, now: u64) LendingError!u256 {
    const exp: u256 = try math.checkedSub(now, last_update);
    if (exp == 0) return RAY;
    const exp_minus_one = exp - 1;
    const exp_minus_two = if (exp > 2) exp - 2 else 0;
    const base_power_two = try rayMul(rate, rate) / (SECONDS_PER_YEAR * SECONDS_PER_YEAR);
    const base_power_three = try rayMul(base_power_two, rate) / SECONDS_PER_YEAR;

    const pairs = exp * exp_minus_one; // both fit in 64 bits
    const second_term = try math.checkedMul(pairs, base_power_two) / 2;
    const third_term = try math.checkedMul(try math.checkedMul(pairs, exp_minus_two), base_power_three) / 6;

    var result = try math.checkedAdd(RAY, try math.checkedMul(rate, exp) / SECONDS_PER_YEAR);
    result = try math.checkedAdd(result, second_term);
    return math.checkedAdd(result, third_term);
}

/// ReserveLogic.getNormalizedIncome.
pub fn getNormalizedIncome(liquidity_rate: u256, liquidity_index: u256, last_update: u64, now: u64) LendingError!u256 {
    if (last_update == now) return liquidity_index;
    return rayMul(try calculateLinearInterest(liquidity_rate, last_update, now), liquidity_index);
}

/// ReserveLogic.getNormalizedDebt, v3.4 and later.
pub fn getNormalizedDebt(borrow_rate: u256, borrow_index: u256, last_update: u64, now: u64) LendingError!u256 {
    if (last_update == now) return borrow_index;
    return rayMul(try calculateCompoundedInterest(borrow_rate, last_update, now), borrow_index);
}

/// ReserveLogic.getNormalizedDebt, v3.0 to v3.3.
pub fn getNormalizedDebtLegacy(borrow_rate: u256, borrow_index: u256, last_update: u64, now: u64) LendingError!u256 {
    if (last_update == now) return borrow_index;
    return rayMul(try calculateCompoundedInterestLegacy(borrow_rate, last_update, now), borrow_index);
}

const YEAR: u64 = 365 * 24 * 60 * 60;
const RATE_8PCT = 8 * RAY / 100;
const RATE_5PCT = 5 * RAY / 100;

test "REQ-PROT-03 interest matches aave-v3-origin MathUtils.t.sol" {
    try std.testing.expectEqual(156 * RAY / 100, try calculateLinearInterest(RATE_8PCT, 0, 7 * YEAR));
    try std.testing.expectEqual(RAY, try calculateCompoundedInterest(RATE_8PCT, 7 * YEAR, 7 * YEAR));
    try std.testing.expectEqual(
        @as(u256, 166666716666676666667666666666666600000000000000),
        try calculateCompoundedInterest(1000 * RAY, 0, 10_000 * YEAR),
    );
    // test_calculateCompoundInterest_1: within 0.3% of e^0.56.
    const ideal: u256 = 1750672500296101082549976435;
    for ([_]u256{
        try calculateCompoundedInterest(RATE_8PCT, 0, 7 * YEAR),
        try calculateCompoundedInterestLegacy(RATE_8PCT, 0, 7 * YEAR),
    }) |value| {
        try std.testing.expect(@max(value, ideal) - @min(value, ideal) < ideal * 3 / 1000);
    }
}

test "REQ-PROT-03 compounded formulas diverge across Aave versions" {
    // Both computed from the two MathUtils.sol sources with Python integers; no published exact vector.
    try std.testing.expectEqual(@as(u256, 1000136995684421674802557900), try calculateCompoundedInterest(RATE_5PCT, 0, 86400));
    try std.testing.expectEqual(@as(u256, 1000136995684207123907444230), try calculateCompoundedInterestLegacy(RATE_5PCT, 0, 86400));
    try std.testing.expectEqual(@as(u256, 1745486836363624056433536000), try calculateCompoundedInterestLegacy(RATE_8PCT, 0, 7 * YEAR));
    try std.testing.expectEqual(RAY, try calculateCompoundedInterestLegacy(RATE_5PCT, 5, 5));
}

test "REQ-PROT-03 normalised income and debt follow ReserveLogic" {
    const index = 2 * RAY;
    try std.testing.expectEqual(index, try getNormalizedIncome(RATE_8PCT, index, 9, 9));
    try std.testing.expectEqual(index, try getNormalizedDebt(RATE_8PCT, index, 9, 9));
    try std.testing.expectEqual(index, try getNormalizedDebtLegacy(RATE_8PCT, index, 9, 9));
    try std.testing.expectEqual(312 * RAY / 100, try getNormalizedIncome(RATE_8PCT, index, 0, 7 * YEAR));
    try std.testing.expectEqual(
        try rayMul(try calculateCompoundedInterest(RATE_5PCT, 0, 86400), index),
        try getNormalizedDebt(RATE_5PCT, index, 0, 86400),
    );
    try std.testing.expectEqual(
        try rayMul(try calculateCompoundedInterestLegacy(RATE_5PCT, 0, 86400), index),
        try getNormalizedDebtLegacy(RATE_5PCT, index, 0, 86400),
    );
    try std.testing.expectError(LendingError.Overflow, getNormalizedIncome(RATE_5PCT, index, 2, 1));
    try std.testing.expectError(LendingError.Overflow, getNormalizedDebt(RATE_5PCT, index, 2, 1));
}

fn exercise(_: void, bytes: []const u8) void {
    var input: [80]u8 = @splat(0);
    const n = @min(bytes.len, input.len);
    @memcpy(input[0..n], bytes[0..n]);
    const rate = std.mem.readInt(u256, input[0..32], .little);
    const index = std.mem.readInt(u256, input[32..64], .little);
    const last = std.mem.readInt(u64, input[64..72], .little);
    const now = std.mem.readInt(u64, input[72..80], .little);
    _ = getNormalizedIncome(rate, index, last, now) catch {};
    _ = getNormalizedDebt(rate, index, last, now) catch {};
    _ = getNormalizedDebtLegacy(rate, index, last, now) catch {};
    // A narrow rate and a forward clock must reach the arithmetic rather than fail early.
    const small_rate = rate >> 160;
    _ = getNormalizedDebt(small_rate, RAY, @min(last, now), @max(last, now)) catch {};
    _ = getNormalizedDebtLegacy(small_rate, RAY, @min(last, now), @max(last, now)) catch {};
}

test "REQ-PROT-03 interest fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [80]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-03 interest stress" {
    var seed: [80]u8 = @splat(0);
    std.mem.writeInt(u256, seed[0..32], RATE_5PCT, .little);
    std.mem.writeInt(u256, seed[32..64], RAY, .little);
    std.mem.writeInt(u64, seed[64..72], 1_700_000_000, .little);
    std.mem.writeInt(u64, seed[72..80], 1_700_086_400, .little);
    fuzz.stress(200_000, &.{&seed}, {}, exercise);
}
