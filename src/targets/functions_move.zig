//! Catalogue entries for Aptos and Sui.
const std = @import("std");
const move = @import("../chains/move/root.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;

fn normalizeAddress(address: []const u8, dest: []u8) move.address.AddressError![]const u8 {
    return move.address.format(try move.address.parseCanonicalAddress(address), .sui, dest);
}
fn shortAddress(address: []const u8, dest: []u8) move.address.AddressError![]const u8 {
    return move.address.format(try move.address.parseCanonicalAddress(address), .aptos, dest);
}
fn typeTag(text: []const u8, dest: []u8) move.typetag.TypeTagError![]const u8 {
    return move.typetag.render(text, .sui, dest);
}
fn parseSchema(gpa: std.mem.Allocator, text: []const u8) !*const move.schema.Node {
    return move.schema.parse(gpa, text);
}
fn decode(schema: *const move.schema.Node, bytes: []const u8, dest: []u8) move.bcs.BcsError![]const u8 {
    return move.schema.renderJson(schema, bytes, true, dest);
}

pub const entries = [_]catalog.Function{
    func("web3_move_address", "Canonical 32-byte 0x address", &.{.text}, .text, normalizeAddress),
    func("web3_move_address_short", "Aptos display form of an address", &.{.text}, .text, shortAddress),
    func("web3_move_type_tag", "Canonical Move TypeTag string", &.{.text}, .text, typeTag),
    catalog.schemaFunc("web3_bcs_decode", "JSON from BCS bytes and a text schema; strict", &.{ .text, .bytes }, .text, parseSchema, decode),
};
