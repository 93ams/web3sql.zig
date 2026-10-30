const std = @import("std");
const ray_wad = @import("ray_wad.zig");

pub const LendingError = error{
    DivisionByZero,
    Overflow,
};

/// Computes health factor (HF = (totalCollateralInBaseCurrency * liquidationThreshold) / totalDebtInBaseCurrency).
/// When totalDebt is zero, returns maxInt(u256) representing infinite health factor.
pub fn calculateHealthFactor(
    collateral: u256,
    liquidation_threshold_bps: u64, // e.g. 8000 for 80.00%
    debt: u256,
) LendingError!u256 {
    if (debt == 0) return std.math.maxInt(u256);
    const wide_c: u512 = collateral;
    const wide_thresh: u512 = liquidation_threshold_bps;
    const prod: u512 = wide_c * wide_thresh;
    const adj_debt: u512 = @as(u512, debt) * 10000;
    const hf: u512 = (prod * ray_wad.WAD) / adj_debt;
    if (hf > std.math.maxInt(u256)) return LendingError.Overflow;
    return @intCast(hf);
}

test "health factor calculation" {
    // Collateral $10000, 80% threshold -> $8000 borrowing power. Debt $4000 -> HF = 2.0 (2 * 1e18)
    const hf = try calculateHealthFactor(10000, 8000, 4000);
    try std.testing.expectEqual(2 * ray_wad.WAD, hf);
}
