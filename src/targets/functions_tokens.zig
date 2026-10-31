//! Catalogue entries for the token fast paths.
const tokens = @import("../protocols/tokens/root.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;

pub const entries = [_]catalog.Function{
    func("web3_erc_decode", "ERC-20/721/1155 Transfer or Approval as JSON (concatenated topics, data)", &.{ .bytes, .bytes }, .text, tokens.erc.renderJson),
    func("web3_spl_decode", "SPL Token instruction as JSON", &.{.bytes}, .text, tokens.spl.renderJson),
};
