//! Catalogue entries for Bitcoin and Litecoin.
const std = @import("std");
const utxo = @import("../chains/utxo/root.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;

fn scriptType(script: []const u8) []const u8 {
    return @tagName(utxo.script.classifyScript(script));
}
fn address(network_name: []const u8, script: []const u8, dest: []u8) ![]const u8 {
    const net = utxo.network.byName(network_name) orelse return error.UnknownNetwork;
    return utxo.script.deriveAddress(net, script, dest);
}
fn scriptJson(network_name: []const u8, script: []const u8, dest: []u8) ![]const u8 {
    const net = utxo.network.byName(network_name) orelse return error.UnknownNetwork;
    return utxo.script.renderJson(net, script, dest);
}

pub const entries = [_]catalog.Function{
    func("web3_btc_script_type", "scriptPubKey class, e.g. p2wpkh", &.{.bytes}, .text, scriptType),
    func("web3_btc_address", "Address of a scriptPubKey on a named network", &.{ .text, .bytes }, .text, address),
    func("web3_btc_script", "Classification and address as JSON", &.{ .text, .bytes }, .text, scriptJson),
    func("web3_btc_op_return", "OP_RETURN payload bytes", &.{.bytes}, .bytes, utxo.op_return.extractPayload),
    func("web3_btc_runestone", "Runestone tag/value pairs as JSON", &.{.bytes}, .text, utxo.runes.renderJson),
    func("web3_btc_inscription", "Ordinals inscription in a witness script as JSON", &.{.bytes}, .text, utxo.ordinals.renderJson),
};
