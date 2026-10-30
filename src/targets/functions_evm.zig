//! Catalogue entries for the EVM. Log topics arrive as one BLOB of concatenated 32-byte words.
const std = @import("std");
const evm = @import("../chains/evm/root.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;
const schemaFunc = catalog.schemaFunc;

const abi = evm.abi;
const decoder = evm.decoder;

fn word(topics: []const u8) error{InvalidTopics}![]const [32]u8 {
    if (topics.len % 32 != 0) return error.InvalidTopics;
    return @as([*]const [32]u8, @ptrCast(topics.ptr))[0 .. topics.len / 32];
}

fn hasValidChecksum(text: []const u8) bool {
    _ = evm.address.validateChecksumAddress(text) catch return false;
    return true;
}

fn output20(address: evm.address.Address, dest: []u8) error{BufferTooSmall}![]const u8 {
    if (dest.len < 20) return error.BufferTooSmall;
    dest[0..20].* = address;
    return dest[0..20];
}

fn createAddress(sender: []const u8, nonce: u64, dest: []u8) error{ InvalidLength, BufferTooSmall }![]const u8 {
    if (sender.len != 20) return error.InvalidLength;
    return output20(evm.address.deriveCreateAddress(sender[0..20], nonce), dest);
}

fn create2Address(sender: []const u8, salt: []const u8, init_code_hash: []const u8, dest: []u8) error{ InvalidLength, BufferTooSmall }![]const u8 {
    if (sender.len != 20 or salt.len != 32 or init_code_hash.len != 32) return error.InvalidLength;
    return output20(evm.address.deriveCreate2Address(sender[0..20], salt[0..32], init_code_hash[0..32]), dest);
}

fn parseSignature(gpa: std.mem.Allocator, text: []const u8) !*const abi.Fragment {
    const frag = try gpa.create(abi.Fragment);
    frag.* = try abi.parseSignature(gpa, text);
    return frag;
}

fn parseJsonFragment(gpa: std.mem.Allocator, text: []const u8) !*const abi.Fragment {
    const frag = try gpa.create(abi.Fragment);
    frag.* = try evm.abi_json.parseFragment(gpa, text);
    return frag;
}

fn topic0(frag: *const abi.Fragment, dest: []u8) error{BufferTooSmall}![]const u8 {
    if (dest.len < 32) return error.BufferTooSmall;
    dest[0..32].* = frag.topic0();
    return dest[0..32];
}

fn selector(frag: *const abi.Fragment, dest: []u8) error{BufferTooSmall}![]const u8 {
    if (dest.len < 4) return error.BufferTooSmall;
    dest[0..4].* = frag.selector();
    return dest[0..4];
}

fn canonical(frag: *const abi.Fragment, dest: []u8) error{BufferTooSmall}![]const u8 {
    if (dest.len < frag.canonical.len) return error.BufferTooSmall;
    @memcpy(dest[0..frag.canonical.len], frag.canonical);
    return dest[0..frag.canonical.len];
}

fn logJson(frag: *const abi.Fragment, topics: []const u8, data: []const u8, dest: []u8) ![]const u8 {
    return decoder.renderLogJson(frag, try word(topics), data, dest);
}

fn logField(frag: *const abi.Fragment, topics: []const u8, data: []const u8, path: []const u8, dest: []u8) ![]const u8 {
    return decoder.renderJson(try decoder.decodeLogField(frag, try word(topics), data, path), dest);
}

fn calldataJson(frag: *const abi.Fragment, input: []const u8, dest: []u8) ![]const u8 {
    return decoder.renderCalldataJson(frag, input, dest);
}

fn calldataField(frag: *const abi.Fragment, input: []const u8, path: []const u8, dest: []u8) ![]const u8 {
    return decoder.renderJson(try decoder.decodeCalldataField(frag, input, path), dest);
}

pub const entries = [_]catalog.Function{
    func("web3_evm_checksum_address", "EIP-55 text of a 20-byte address", &.{.bytes}, .text, evm.address.checksumAddress),
    func("web3_evm_is_checksummed", "True if text passes EIP-55", &.{.text}, .boolean, hasValidChecksum),
    func("web3_evm_create_address", "CREATE address (sender, nonce)", &.{ .bytes, .int }, .bytes, createAddress),
    func("web3_evm_create2_address", "CREATE2 address (sender, salt, init code hash)", &.{ .bytes, .bytes, .bytes }, .bytes, create2Address),
    schemaFunc("web3_evm_topic0", "Event topic0 of a human-readable signature", &.{.text}, .bytes, parseSignature, topic0),
    schemaFunc("web3_evm_selector", "4-byte selector of a human-readable signature", &.{.text}, .bytes, parseSignature, selector),
    schemaFunc("web3_evm_canonical_signature", "Canonical form of a human-readable signature", &.{.text}, .text, parseSignature, canonical),
    schemaFunc("web3_evm_decode_log", "JSON from (signature, topics, data)", &.{ .text, .bytes, .bytes }, .text, parseSignature, logJson),
    schemaFunc("web3_evm_decode_log_field", "One JSON value from (signature, topics, data, path)", &.{ .text, .bytes, .bytes, .text }, .text, parseSignature, logField),
    schemaFunc("web3_evm_decode_calldata", "JSON from (signature, input)", &.{ .text, .bytes }, .text, parseSignature, calldataJson),
    schemaFunc("web3_evm_decode_calldata_field", "One JSON value from (signature, input, path)", &.{ .text, .bytes, .text }, .text, parseSignature, calldataField),
    catalog.nativeOnly(schemaFunc("web3_evm_decode_log_abi", "JSON from (JSON ABI fragment, topics, data)", &.{ .text, .bytes, .bytes }, .text, parseJsonFragment, logJson)),
    catalog.nativeOnly(schemaFunc("web3_evm_decode_calldata_abi", "JSON from (JSON ABI fragment, input)", &.{ .text, .bytes }, .text, parseJsonFragment, calldataJson)),
};
