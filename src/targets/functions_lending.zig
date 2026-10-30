//! Catalogue entries for Aave and Compound index math. Values are decimal text.
const math = @import("../core/math/root.zig");
const lending = @import("../protocols/lending/root.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;

const Err = lending.ray_wad.LendingError;

fn binary(comptime op: fn (u256, u256) Err!u256) fn ([]const u8, []const u8, []u8) Err![]const u8 {
    return struct {
        fn f(a: []const u8, b: []const u8, dest: []u8) Err![]const u8 {
            return math.formatDecimal(try op(try math.parseDecimal(a), try math.parseDecimal(b)), dest);
        }
    }.f;
}

fn interest(comptime op: fn (u256, u64, u64) Err!u256) fn ([]const u8, u64, u64, []u8) Err![]const u8 {
    return struct {
        fn f(rate: []const u8, last: u64, now: u64, dest: []u8) Err![]const u8 {
            return math.formatDecimal(try op(try math.parseDecimal(rate), last, now), dest);
        }
    }.f;
}

fn index(comptime op: fn (u256, u256, u64, u64) Err!u256) fn ([]const u8, []const u8, u64, u64, []u8) Err![]const u8 {
    return struct {
        fn f(rate: []const u8, idx: []const u8, last: u64, now: u64, dest: []u8) Err![]const u8 {
            return math.formatDecimal(try op(try math.parseDecimal(rate), try math.parseDecimal(idx), last, now), dest);
        }
    }.f;
}

fn healthFactor(collateral: []const u8, threshold_bps: u64, debt: []const u8, dest: []u8) Err![]const u8 {
    return math.formatDecimal(try lending.health_factor.calculateHealthFactor(try math.parseDecimal(collateral), threshold_bps, try math.parseDecimal(debt)), dest);
}

fn exchangeRate(cash: []const u8, borrows: []const u8, reserves: []const u8, supply: []const u8, initial: []const u8, dest: []u8) Err![]const u8 {
    const rate = try lending.compound.exchangeRate(try math.parseDecimal(cash), try math.parseDecimal(borrows), try math.parseDecimal(reserves), try math.parseDecimal(supply), try math.parseDecimal(initial));
    return math.formatDecimal(rate, dest);
}

const interest_args = &[_]catalog.ArgType{ .text, .int, .int };
const index_args = &[_]catalog.ArgType{ .text, .text, .int, .int };

pub const entries = [_]catalog.Function{
    func("web3_wad_mul", "Aave wadMul, half up", &.{ .text, .text }, .text, binary(lending.ray_wad.wadMul)),
    func("web3_wad_div", "Aave wadDiv, half up", &.{ .text, .text }, .text, binary(lending.ray_wad.wadDiv)),
    func("web3_ray_mul", "Aave rayMul, half up", &.{ .text, .text }, .text, binary(lending.ray_wad.rayMul)),
    func("web3_ray_div", "Aave rayDiv, half up", &.{ .text, .text }, .text, binary(lending.ray_wad.rayDiv)),
    func("web3_ray_pow", "Ray exponentiation by squaring", &.{ .text, .text }, .text, binary(lending.ray_wad.rayPow)),
    func("web3_aave_linear_interest", "Aave MathUtils.calculateLinearInterest (rate, last_update, now)", interest_args, .text, interest(lending.interest.calculateLinearInterest)),
    func("web3_aave_compounded_interest", "Compounded interest, Aave v3.4+ (rate, last_update, now)", interest_args, .text, interest(lending.interest.calculateCompoundedInterest)),
    func("web3_aave_compounded_interest_legacy", "Compounded interest, Aave v3.0 to v3.3 (rate, last_update, now)", interest_args, .text, interest(lending.interest.calculateCompoundedInterestLegacy)),
    func("web3_aave_normalized_income", "Reserve normalized income (rate, index, last_update, now)", index_args, .text, index(lending.interest.getNormalizedIncome)),
    func("web3_aave_normalized_debt", "Reserve normalized debt, v3.4+ (rate, index, last_update, now)", index_args, .text, index(lending.interest.getNormalizedDebt)),
    func("web3_aave_normalized_debt_legacy", "Reserve normalized debt, v3.0 to v3.3 (rate, index, last_update, now)", index_args, .text, index(lending.interest.getNormalizedDebtLegacy)),
    func("web3_aave_health_factor", "Health factor (collateral, liquidation threshold in bps, debt)", &.{ .text, .int, .text }, .text, healthFactor),
    func("web3_compound_exchange_rate", "cToken exchange rate (cash, borrows, reserves, supply, initial_rate)", &.{ .text, .text, .text, .text, .text }, .text, exchangeRate),
};
