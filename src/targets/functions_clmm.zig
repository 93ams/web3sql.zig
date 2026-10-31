//! Catalogue entries for concentrated-liquidity math. SQL carries 128+ bit values as decimal text.
const std = @import("std");
const math = @import("../core/math/root.zig");
const q96 = @import("../protocols/clmm/q64_96.zig");
const q64 = @import("../protocols/clmm/q64_64.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;

fn parseAs(comptime T: type, text: []const u8) error{ Overflow, InvalidCharacter, DivisionByZero, BufferTooSmall }!T {
    return std.math.cast(T, try math.parseDecimal(text)) orelse error.Overflow;
}

fn sqrtRatioAtTick(tick: i32, dest: []u8) ![]const u8 {
    return math.formatDecimal(try q96.getSqrtRatioAtTick(tick), dest);
}
fn tickAtSqrtRatio(sqrt: []const u8) !i32 {
    return q96.getTickAtSqrtRatio(try parseAs(u160, sqrt));
}
fn sqrtPriceX96ToDecimal(sqrt: []const u8, d0: u8, d1: u8, scale: u8, dest: []u8) ![]const u8 {
    return q96.sqrtPriceX96ToDecimal(try parseAs(u160, sqrt), d0, d1, scale, dest);
}
fn amount0Delta(a: []const u8, b: []const u8, liquidity: []const u8, round_up: bool, dest: []u8) ![]const u8 {
    return math.formatDecimal(try q96.getAmount0Delta(try parseAs(u160, a), try parseAs(u160, b), try parseAs(u128, liquidity), round_up), dest);
}
fn amount1Delta(a: []const u8, b: []const u8, liquidity: []const u8, round_up: bool, dest: []u8) ![]const u8 {
    return math.formatDecimal(try q96.getAmount1Delta(try parseAs(u160, a), try parseAs(u160, b), try parseAs(u128, liquidity), round_up), dest);
}

fn x64FromTick(comptime f: fn (i32) q64.ClmmError!u128) fn (i32, []u8) anyerror![]const u8 {
    return struct {
        fn g(tick: i32, dest: []u8) anyerror![]const u8 {
            return math.formatDecimal(try f(tick), dest);
        }
    }.g;
}
fn tickFromX64(comptime f: fn (u128) q64.ClmmError!i32) fn ([]const u8) anyerror!i32 {
    return struct {
        fn g(sqrt: []const u8) anyerror!i32 {
            return f(try parseAs(u128, sqrt));
        }
    }.g;
}
fn sqrtPriceX64ToDecimal(sqrt: []const u8, da: u8, db: u8, scale: u8, dest: []u8) ![]const u8 {
    return q64.sqrtPriceX64ToDecimal(try parseAs(u128, sqrt), da, db, scale, dest);
}

const price_args = &[_]catalog.ArgType{ .text, .int, .int, .int };
const delta_args = &[_]catalog.ArgType{ .text, .text, .text, .boolean };

pub const entries = [_]catalog.Function{
    func("web3_uni_sqrt_ratio_at_tick", "Uniswap TickMath.getSqrtRatioAtTick", &.{.int}, .text, sqrtRatioAtTick),
    func("web3_uni_tick_at_sqrt_ratio", "Uniswap TickMath.getTickAtSqrtRatio", &.{.text}, .int, tickAtSqrtRatio),
    func("web3_uni_sqrt_price_to_price", "Price from sqrtPriceX96 (sqrt, decimals0, decimals1, scale)", price_args, .text, sqrtPriceX96ToDecimal),
    func("web3_uni_tick_to_price", "Price from a tick (tick, decimals0, decimals1, scale)", &.{ .int, .int, .int, .int }, .text, q96.tickToDecimal),
    func("web3_uni_amount0_delta", "SqrtPriceMath.getAmount0Delta (sqrtA, sqrtB, liquidity, round_up)", delta_args, .text, amount0Delta),
    func("web3_uni_amount1_delta", "SqrtPriceMath.getAmount1Delta (sqrtA, sqrtB, liquidity, round_up)", delta_args, .text, amount1Delta),
    func("web3_orca_sqrt_price_from_tick", "Orca Q64.64 sqrt price of a tick", &.{.int}, .text, x64FromTick(q64.orcaSqrtPriceFromTick)),
    func("web3_raydium_sqrt_price_from_tick", "Raydium Q64.64 sqrt price of a tick", &.{.int}, .text, x64FromTick(q64.raydiumSqrtPriceFromTick)),
    func("web3_cetus_sqrt_price_from_tick", "Cetus Q64.64 sqrt price of a tick", &.{.int}, .text, x64FromTick(q64.cetusSqrtPriceFromTick)),
    func("web3_orca_tick_from_sqrt_price", "Orca tick of a Q64.64 sqrt price", &.{.text}, .int, tickFromX64(q64.orcaTickFromSqrtPrice)),
    func("web3_raydium_tick_from_sqrt_price", "Raydium tick of a Q64.64 sqrt price", &.{.text}, .int, tickFromX64(q64.raydiumTickFromSqrtPrice)),
    func("web3_cetus_tick_from_sqrt_price", "Cetus tick of a Q64.64 sqrt price", &.{.text}, .int, tickFromX64(q64.cetusTickFromSqrtPrice)),
    func("web3_x64_sqrt_price_to_price", "Price from a Q64.64 sqrt price (sqrt, decimalsA, decimalsB, scale)", price_args, .text, sqrtPriceX64ToDecimal),
};
