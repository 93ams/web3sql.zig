//! Compound v2 CToken.sol. Unlike Aave's half-up wad math, Compound truncates.
const std = @import("std");
const math = @import("../../core/math/root.zig");
const fuzz = @import("../../core/fuzz.zig");
const ray_wad = @import("ray_wad.zig");

pub const LendingError = ray_wad.LendingError;

const EXP_SCALE = ray_wad.WAD;

/// exchangeRateStoredInternal: (cash + borrows - reserves) * 1e18 / supply, or the initial rate when
/// supply is zero. Reserves above cash plus borrows are Overflow, as the checked subtraction reverts.
pub fn exchangeRate(total_cash: u256, total_borrows: u256, total_reserves: u256, total_supply: u256, initial_rate: u256) LendingError!u256 {
    if (total_supply == 0) return initial_rate;
    const net = try math.checkedSub(try math.checkedAdd(total_cash, total_borrows), total_reserves);
    return try math.checkedMul(net, EXP_SCALE) / total_supply;
}

test "REQ-PROT-03 exchange rate matches compound-protocol cTokenTest.js" {
    const e18 = EXP_SCALE;
    try std.testing.expectEqual(2 * e18, try exchangeRate(9, 9, 0, 0, 2 * e18));
    try std.testing.expectEqual(e18, try exchangeRate(0, 1, 0, 1, 2 * e18));
    try std.testing.expectEqual(e18 / 10, try exchangeRate(0, 10 * e18, 0, 100 * e18, 2 * e18));
    try std.testing.expectEqual(100 * e18, try exchangeRate(500 * e18, 0, 0, 5 * e18, 2 * e18));
    try std.testing.expectEqual(199 * e18 / 100, try exchangeRate(500 * e18, 500 * e18, 5 * e18, 500 * e18, 2 * e18));
}

test "REQ-PROT-03 exchange rate truncates and reverts like CToken" {
    try std.testing.expectEqual(@as(u256, 666666666666666666), try exchangeRate(2, 0, 0, 3, 0));
    try std.testing.expectError(LendingError.Overflow, exchangeRate(1, 0, 2, 1, 0));
    try std.testing.expectError(LendingError.Overflow, exchangeRate(std.math.maxInt(u256), 1, 0, 1, 0));
    try std.testing.expectError(LendingError.Overflow, exchangeRate(std.math.maxInt(u256), 0, 0, 1, 0));
}

fn exercise(_: void, bytes: []const u8) void {
    var input: [64]u8 = @splat(0);
    const n = @min(bytes.len, input.len);
    @memcpy(input[0..n], bytes[0..n]);
    const cash = std.mem.readInt(u128, input[0..16], .little);
    const borrows = std.mem.readInt(u128, input[16..32], .little);
    const reserves = std.mem.readInt(u128, input[32..48], .little);
    const supply = std.mem.readInt(u128, input[48..64], .little);
    _ = exchangeRate(cash, borrows, reserves, supply, EXP_SCALE) catch {};
    _ = exchangeRate(std.mem.readInt(u256, input[0..32], .little), std.mem.readInt(u256, input[32..64], .little), reserves, supply, 0) catch {};
}

test "REQ-PROT-03 exchange rate fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [64]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-03 exchange rate stress" {
    var seed: [64]u8 = @splat(0);
    std.mem.writeInt(u128, seed[0..16], 500_000_000_000_000_000_000, .little);
    std.mem.writeInt(u128, seed[16..32], 500_000_000_000_000_000_000, .little);
    std.mem.writeInt(u128, seed[32..48], 5_000_000_000_000_000_000, .little);
    std.mem.writeInt(u128, seed[48..64], 500_000_000_000_000_000_000, .little);
    fuzz.stress(200_000, &.{&seed}, {}, exercise);
}
