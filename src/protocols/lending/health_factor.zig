const std = @import("std");
const fuzz = @import("../../core/fuzz.zig");
const ray_wad = @import("ray_wad.zig");

pub const LendingError = ray_wad.LendingError;

/// Aave PercentageMath.percentMul, rounded half up. `percentage` is in basis points.
pub fn percentMul(value: u256, percentage: u256) LendingError!u256 {
    return ray_wad.mulHalfUp(value, percentage, 5_000, 10_000);
}

/// Aave GenericLogic health factor in wad: collateral.percentMul(threshold).wadDiv(debt).
/// Zero debt returns maxInt(u256), as the protocol does.
pub fn calculateHealthFactor(
    collateral: u256,
    liquidation_threshold_bps: u64, // e.g. 8000 for 80.00%
    debt: u256,
) LendingError!u256 {
    if (debt == 0) return std.math.maxInt(u256);
    return ray_wad.wadDiv(try percentMul(collateral, liquidation_threshold_bps), debt);
}

test "REQ-PROT-03 percentMul matches aave-v3-origin PercentageMath.t.sol" {
    const e18 = ray_wad.WAD;
    try std.testing.expectEqual(e18 / 2, try percentMul(e18, 50_00));
    try std.testing.expectEqual(@as(u256, 10605966300000000000), try percentMul(14251500000000000000, 74_42));
    try std.testing.expectEqual(@as(u256, 1211338689600000000000000000000000), try percentMul(9087312 * ray_wad.RAY, 13_33));
}

test "REQ-PROT-03 health factor rounds as GenericLogic does" {
    // Collateral $10000, 80% threshold -> $8000 borrowing power. Debt $4000 -> HF = 2.0.
    try std.testing.expectEqual(2 * ray_wad.WAD, try calculateHealthFactor(10000, 8000, 4000));
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u256)), try calculateHealthFactor(1, 8000, 0));
    // percentMul(3, 8000) rounds 2.4 down to 2; a single division would give 0.8e18.
    try std.testing.expectEqual(@as(u256, 666666666666666667), try calculateHealthFactor(3, 8000, 3));
}

fn exercise(_: void, bytes: []const u8) void {
    var input: [48]u8 = @splat(0);
    const n = @min(bytes.len, input.len);
    @memcpy(input[0..n], bytes[0..n]);
    const collateral = std.mem.readInt(u128, input[0..16], .little);
    const extra = std.mem.readInt(u128, input[16..32], .little);
    const debt = std.mem.readInt(u128, input[32..48], .little);
    const threshold = @as(u64, std.mem.readInt(u16, input[0..2], .little));

    const low = calculateHealthFactor(collateral, threshold, debt) catch return;
    const high = calculateHealthFactor(@as(u256, collateral) + extra, threshold, debt) catch return;
    std.debug.assert(low <= high);
}

test "REQ-PROT-03 health factor is monotone in collateral fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [48]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-03 health factor is monotone in collateral stress" {
    var seed: [48]u8 = @splat(0);
    std.mem.writeInt(u128, seed[0..16], 10_000_000_000_000_000_000, .little);
    std.mem.writeInt(u128, seed[16..32], 1, .little);
    std.mem.writeInt(u128, seed[32..48], 4_000_000_000_000_000_000, .little);
    std.mem.writeInt(u16, seed[0..2], 8000, .little);
    fuzz.stress(200_000, &.{&seed}, {}, exercise);
}
