//! Catalogue entries for Cosmos.
const cosmos = @import("../chains/cosmos/root.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;

fn isValid(address: []const u8) bool {
    cosmos.bech32.validate(address, null) catch return false;
    return true;
}
fn baseDenom(trace: []const u8, dest: []u8) cosmos.ibc.IbcError![]const u8 {
    const denom = (try cosmos.ibc.parseTrace(trace)).base_denom;
    if (dest.len < denom.len) return error.BufferTooSmall;
    @memcpy(dest[0..denom.len], denom);
    return dest[0..denom.len];
}

pub const entries = [_]catalog.Function{
    func("web3_cosmos_convert_hrp", "Re-encode a Bech32 address under a new prefix", &.{ .text, .text }, .text, cosmos.bech32.convertHrp),
    func("web3_cosmos_is_valid", "True for a valid Bech32 address", &.{.text}, .boolean, isValid),
    func("web3_ibc_denom", "ibc/<SHA256> hash of a denom trace", &.{.text}, .text, cosmos.ibc.deriveIbcDenom),
    func("web3_ibc_base_denom", "Base denom of a denom trace", &.{.text}, .text, baseDenom),
};
