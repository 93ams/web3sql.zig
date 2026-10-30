const build_options = @import("build_options");

pub const evm = if (build_options.chain_evm) @import("evm/root.zig") else struct {};
pub const svm = if (build_options.chain_svm) @import("svm/root.zig") else struct {};
pub const move = if (build_options.chain_move) @import("move/root.zig") else struct {};
pub const utxo = if (build_options.chain_utxo) @import("utxo/root.zig") else struct {};
pub const cosmos = if (build_options.chain_cosmos) @import("cosmos/root.zig") else struct {};

test {
    if (build_options.chain_evm) _ = @import("evm/root.zig");
    if (build_options.chain_svm) _ = @import("svm/root.zig");
    if (build_options.chain_move) _ = @import("move/root.zig");
    if (build_options.chain_utxo) _ = @import("utxo/root.zig");
    if (build_options.chain_cosmos) _ = @import("cosmos/root.zig");
}
