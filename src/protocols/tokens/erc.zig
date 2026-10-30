//! Fast-path decoders for ERC-20, ERC-721 and ERC-1155 logs, without ABI parsing.
//! `topics` is the log's topics concatenated, 32 bytes each. Topic count and data length are exact,
//! which keeps ERC-20 and ERC-721 apart: they share topic0 and differ only in shape.
//! shortcut: non-standard logs (such as CryptoKitties, with an unindexed ERC-721 Transfer) are rejected, use the ABI decoder for those.
const std = @import("std");
const hex = @import("../../core/encodings/hex.zig");
const keccak = @import("../../core/crypto/keccak.zig");
const fuzz = @import("../../core/fuzz.zig");
const json = @import("json.zig");

pub const TokenError = error{
    UnknownEvent,
    InvalidTopicCount,
    InvalidDataLength,
    InvalidAddress,
    BufferTooSmall,
};

pub const Address = [20]u8;

pub const Erc20Transfer = struct { from: Address, to: Address, value: u256 };
pub const Erc20Approval = struct { owner: Address, spender: Address, value: u256 };
pub const Erc721Transfer = struct { from: Address, to: Address, token_id: u256 };
pub const Erc721Approval = struct { owner: Address, approved: Address, token_id: u256 };
pub const Erc1155TransferSingle = struct { operator: Address, from: Address, to: Address, id: u256, value: u256 };

fn topicHash(comptime text: *const [64]u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable; // comptime literal
    return out;
}

/// keccak256("Transfer(address,address,uint256)")
pub const TRANSFER_TOPIC = topicHash("ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef");
/// keccak256("Approval(address,address,uint256)")
pub const APPROVAL_TOPIC = topicHash("8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925");
/// keccak256("TransferSingle(address,address,address,uint256,uint256)")
pub const TRANSFER_SINGLE_TOPIC = topicHash("c3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62");

fn check(topics: []const u8, data: []const u8, signature: *const [32]u8, topic_count: usize, data_len: usize) TokenError!void {
    if (topics.len != topic_count * 32) return TokenError.InvalidTopicCount;
    if (!std.mem.eql(u8, topics[0..32], signature)) return TokenError.UnknownEvent;
    if (data.len != data_len) return TokenError.InvalidDataLength;
}

fn word(bytes: []const u8, index: usize) u256 {
    return std.mem.readInt(u256, bytes[index * 32 ..][0..32], .big);
}

fn address(topics: []const u8, index: usize) TokenError!Address {
    const value = topics[index * 32 ..][0..32];
    if (!std.mem.allEqual(u8, value[0..12], 0)) return TokenError.InvalidAddress;
    return value[12..32].*;
}

/// ERC-20 Transfer: 3 topics, 32 bytes of data.
pub fn decodeErc20Transfer(topics: []const u8, data: []const u8) TokenError!Erc20Transfer {
    try check(topics, data, &TRANSFER_TOPIC, 3, 32);
    return .{ .from = try address(topics, 1), .to = try address(topics, 2), .value = word(data, 0) };
}

/// ERC-20 Approval: 3 topics, 32 bytes of data.
pub fn decodeErc20Approval(topics: []const u8, data: []const u8) TokenError!Erc20Approval {
    try check(topics, data, &APPROVAL_TOPIC, 3, 32);
    return .{ .owner = try address(topics, 1), .spender = try address(topics, 2), .value = word(data, 0) };
}

/// ERC-721 Transfer: 4 topics, no data.
pub fn decodeErc721Transfer(topics: []const u8, data: []const u8) TokenError!Erc721Transfer {
    try check(topics, data, &TRANSFER_TOPIC, 4, 0);
    return .{ .from = try address(topics, 1), .to = try address(topics, 2), .token_id = word(topics, 3) };
}

/// ERC-721 Approval: 4 topics, no data.
pub fn decodeErc721Approval(topics: []const u8, data: []const u8) TokenError!Erc721Approval {
    try check(topics, data, &APPROVAL_TOPIC, 4, 0);
    return .{ .owner = try address(topics, 1), .approved = try address(topics, 2), .token_id = word(topics, 3) };
}

/// ERC-1155 TransferSingle: 4 topics, 64 bytes of data.
pub fn decodeErc1155TransferSingle(topics: []const u8, data: []const u8) TokenError!Erc1155TransferSingle {
    try check(topics, data, &TRANSFER_SINGLE_TOPIC, 4, 64);
    return .{
        .operator = try address(topics, 1),
        .from = try address(topics, 2),
        .to = try address(topics, 3),
        .id = word(data, 0),
        .value = word(data, 1),
    };
}

fn field(out: *json.Out, comptime name: []const u8, value: anytype) TokenError!void {
    try out.raw(",\"" ++ name ++ "\":");
    if (@TypeOf(value) == Address) return out.bytes(&value);
    return out.int(value);
}

/// Picks the decoder from topic0 and the topic count and writes the event as compact JSON.
pub fn renderJson(topics: []const u8, data: []const u8, dest: []u8) TokenError![]const u8 {
    if (topics.len < 32) return TokenError.InvalidTopicCount;
    const signature = topics[0..32];
    var out: json.Out = .{ .dest = dest };
    if (std.mem.eql(u8, signature, &TRANSFER_TOPIC)) {
        if (topics.len == 4 * 32) {
            const e = try decodeErc721Transfer(topics, data);
            try out.raw("{\"event\":\"erc721_transfer\"");
            try field(&out, "from", e.from);
            try field(&out, "to", e.to);
            try field(&out, "token_id", e.token_id);
        } else {
            const e = try decodeErc20Transfer(topics, data);
            try out.raw("{\"event\":\"erc20_transfer\"");
            try field(&out, "from", e.from);
            try field(&out, "to", e.to);
            try field(&out, "value", e.value);
        }
    } else if (std.mem.eql(u8, signature, &APPROVAL_TOPIC)) {
        if (topics.len == 4 * 32) {
            const e = try decodeErc721Approval(topics, data);
            try out.raw("{\"event\":\"erc721_approval\"");
            try field(&out, "owner", e.owner);
            try field(&out, "approved", e.approved);
            try field(&out, "token_id", e.token_id);
        } else {
            const e = try decodeErc20Approval(topics, data);
            try out.raw("{\"event\":\"erc20_approval\"");
            try field(&out, "owner", e.owner);
            try field(&out, "spender", e.spender);
            try field(&out, "value", e.value);
        }
    } else if (std.mem.eql(u8, signature, &TRANSFER_SINGLE_TOPIC)) {
        const e = try decodeErc1155TransferSingle(topics, data);
        try out.raw("{\"event\":\"erc1155_transfer_single\"");
        try field(&out, "operator", e.operator);
        try field(&out, "from", e.from);
        try field(&out, "to", e.to);
        try field(&out, "id", e.id);
        try field(&out, "value", e.value);
    } else {
        return TokenError.UnknownEvent;
    }
    try out.raw("}");
    return out.written();
}

// Real Ethereum mainnet logs from eth_getLogs at block 0x1916dca (publicnode RPC), by transaction:
const TOPIC_TRANSFER_HEX = "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const TOPIC_APPROVAL_HEX = "8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925";
const ZERO_WORD_HEX = "0000000000000000000000000000000000000000000000000000000000000000";
// USDC, tx 0x7b7c556baa650872ecf696bf9790b9c6271bd6c298ae1761416d40e40de56972 log 0x0
const ERC20_TRANSFER_TOPICS = TOPIC_TRANSFER_HEX ++ "000000000000000000000000000000000004444c5dc75cb358380d2e3de08a90" ++ "0000000000000000000000000000000aa232009084bd71a5797d089aa4edfad4";
const ERC20_TRANSFER_DATA = "00000000000000000000000000000000000000000000000000000000000899fa";
// USDC, tx 0x54a82659eb307de19203b8d4a1a685e549cb903e094df9f1e5159135fb4ee97b log 0x75
const ERC20_APPROVAL_TOPICS = TOPIC_APPROVAL_HEX ++ "0000000000000000000000004c460e929bb565d31a8c66268a8b65b42841b4a1" ++ "0000000000000000000000001231deb6f5749ef6ce6943a275a1d3e7486f4eae";
// tx 0x13f0b8b9ce6dc808680b0d68d3f3689526b48aa8d89e93086877039f61bb8864 log 0x6d
const ERC721_TRANSFER_TOPICS = TOPIC_TRANSFER_HEX ++ "000000000000000000000000a86bacbec2c12ca845df0e372290440f194c2e05" ++ "000000000000000000000000c1996901eba8ad733edb287ced03a138a1da1f90" ++ "0000000000000000000000000000000000000000000000000000000000019d54";
// tx 0x5f3cce6a592e72df46f69b4bdf00745edc3cf2e59f80123fb68247de8110b8e2 log 0x77
const ERC721_APPROVAL_TOPICS = TOPIC_APPROVAL_HEX ++ "000000000000000000000000cc41288ad740addb522b16b94597691f473898bf" ++ ZERO_WORD_HEX ++ "000000000000000000000000000000000000000000000000000000000000004e";
// tx 0xd76a3bb02df6b43f8a5545115241f18c2710dda838059e69619d39342551092a log 0x65
const ERC1155_TOPICS = "c3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62" ++ "00000000000000000000000061b9beb9dce12a510c402a705b3109f9df22f549" ++ ZERO_WORD_HEX ++ "00000000000000000000000061b9beb9dce12a510c402a705b3109f9df22f549";
const ERC1155_DATA = "0000000000000000000000000000000000000000000000000000000000000016" ++ "0000000000000000000000000000000000000000000000000000000000000001";

fn unhex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = hex.decodeHex(text, &out) catch unreachable; // test literal
    return out;
}

test "REQ-PROT-02 topic hashes are the keccak of the EIP signatures" {
    var out: [32]u8 = undefined;
    keccak.hash("Transfer(address,address,uint256)", &out);
    try std.testing.expectEqualSlices(u8, &out, &TRANSFER_TOPIC);
    keccak.hash("Approval(address,address,uint256)", &out);
    try std.testing.expectEqualSlices(u8, &out, &APPROVAL_TOPIC);
    keccak.hash("TransferSingle(address,address,address,uint256,uint256)", &out);
    try std.testing.expectEqualSlices(u8, &out, &TRANSFER_SINGLE_TOPIC);
}

test "REQ-PROT-02 ERC-20 Transfer and Approval decode real logs" {
    const topics = unhex(ERC20_TRANSFER_TOPICS);
    const data = unhex(ERC20_TRANSFER_DATA);
    const e = try decodeErc20Transfer(&topics, &data);
    try std.testing.expectEqualSlices(u8, &unhex("000000000004444c5dc75cb358380d2e3de08a90"), &e.from);
    try std.testing.expectEqualSlices(u8, &unhex("0000000aa232009084bd71a5797d089aa4edfad4"), &e.to);
    try std.testing.expectEqual(@as(u256, 0x899fa), e.value);

    const approval_topics = unhex(ERC20_APPROVAL_TOPICS);
    const zero = unhex(ZERO_WORD_HEX);
    const a = try decodeErc20Approval(&approval_topics, &zero);
    try std.testing.expectEqualSlices(u8, &unhex("4c460e929bb565d31a8c66268a8b65b42841b4a1"), &a.owner);
    try std.testing.expectEqualSlices(u8, &unhex("1231deb6f5749ef6ce6943a275a1d3e7486f4eae"), &a.spender);
    try std.testing.expectEqual(@as(u256, 0), a.value);
}

test "REQ-PROT-02 ERC-721 and ERC-1155 decode real logs" {
    const t721 = unhex(ERC721_TRANSFER_TOPICS);
    const e = try decodeErc721Transfer(&t721, "");
    try std.testing.expectEqualSlices(u8, &unhex("c1996901eba8ad733edb287ced03a138a1da1f90"), &e.to);
    try std.testing.expectEqual(@as(u256, 0x19d54), e.token_id);

    const a721 = unhex(ERC721_APPROVAL_TOPICS);
    const a = try decodeErc721Approval(&a721, "");
    try std.testing.expectEqualSlices(u8, &unhex("cc41288ad740addb522b16b94597691f473898bf"), &a.owner);
    try std.testing.expectEqual(@as(u256, 0x4e), a.token_id);

    const t1155 = unhex(ERC1155_TOPICS);
    const d1155 = unhex(ERC1155_DATA);
    const s = try decodeErc1155TransferSingle(&t1155, &d1155);
    try std.testing.expectEqualSlices(u8, &unhex("61b9beb9dce12a510c402a705b3109f9df22f549"), &s.operator);
    try std.testing.expectEqual(@as(Address, @splat(0)), s.from);
    try std.testing.expectEqual(@as(u256, 0x16), s.id);
    try std.testing.expectEqual(@as(u256, 1), s.value);
}

test "REQ-PROT-02 a log decodes as one standard only" {
    const t20 = unhex(ERC20_TRANSFER_TOPICS);
    const d20 = unhex(ERC20_TRANSFER_DATA);
    const t721 = unhex(ERC721_TRANSFER_TOPICS);
    try std.testing.expectError(TokenError.InvalidTopicCount, decodeErc721Transfer(&t20, &d20));
    try std.testing.expectError(TokenError.InvalidTopicCount, decodeErc20Transfer(&t721, ""));
    try std.testing.expectError(TokenError.InvalidDataLength, decodeErc20Transfer(&t20, ""));
    try std.testing.expectError(TokenError.InvalidDataLength, decodeErc721Transfer(&t721, &d20));
    try std.testing.expectError(TokenError.UnknownEvent, decodeErc20Approval(&t20, &d20));
    try std.testing.expectError(TokenError.InvalidTopicCount, decodeErc20Transfer(t20[0..95], &d20));

    var dirty = t20;
    dirty[32] = 1; // nonzero address padding
    try std.testing.expectError(TokenError.InvalidAddress, decodeErc20Transfer(&dirty, &d20));
}

test "REQ-PROT-02 ERC renderJson" {
    var buf: [256]u8 = undefined;
    const t20 = unhex(ERC20_TRANSFER_TOPICS);
    const d20 = unhex(ERC20_TRANSFER_DATA);
    try std.testing.expectEqualStrings(
        "{\"event\":\"erc20_transfer\",\"from\":\"0x000000000004444c5dc75cb358380d2e3de08a90\",\"to\":\"0x0000000aa232009084bd71a5797d089aa4edfad4\",\"value\":563706}",
        try renderJson(&t20, &d20, &buf),
    );
    const big: [32]u8 = @splat(0xff);
    const rendered = try renderJson(&t20, &big, &buf);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "\"value\":\"115792089237316195423570985008687907853269984665640564039457584007913129639935\"}"));

    const t721 = unhex(ERC721_TRANSFER_TOPICS);
    try std.testing.expect(std.mem.endsWith(u8, try renderJson(&t721, "", &buf), "\"token_id\":105812}"));
    const a721 = unhex(ERC721_APPROVAL_TOPICS);
    try std.testing.expect(std.mem.startsWith(u8, try renderJson(&a721, "", &buf), "{\"event\":\"erc721_approval\""));
    const a20 = unhex(ERC20_APPROVAL_TOPICS);
    try std.testing.expect(std.mem.endsWith(u8, try renderJson(&a20, &big, &buf), "\"}"));
    const t1155 = unhex(ERC1155_TOPICS);
    const d1155 = unhex(ERC1155_DATA);
    try std.testing.expect(std.mem.endsWith(u8, try renderJson(&t1155, &d1155, &buf), "\"id\":22,\"value\":1}"));

    try std.testing.expectError(TokenError.BufferTooSmall, renderJson(&t20, &d20, buf[0..40]));
    try std.testing.expectError(TokenError.InvalidTopicCount, renderJson("", "", &buf));
    try std.testing.expectError(TokenError.UnknownEvent, renderJson(&unhex(ZERO_WORD_HEX), "", &buf));
}

/// First input byte splits the rest into topics and data, so mutants reach every shape.
fn exercise(_: void, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const split = @min(@as(usize, bytes[0]) * 8, bytes.len - 1);
    const topics = bytes[1..][0..split];
    const data = bytes[1 + split ..];
    _ = decodeErc20Transfer(topics, data) catch {};
    _ = decodeErc20Approval(topics, data) catch {};
    _ = decodeErc721Transfer(topics, data) catch {};
    _ = decodeErc721Approval(topics, data) catch {};
    _ = decodeErc1155TransferSingle(topics, data) catch {};
    var dest: [300]u8 = undefined;
    _ = renderJson(topics, data, &dest) catch {};
    _ = renderJson(topics, data, dest[0 .. bytes.len % 128]) catch {};
}

test "REQ-PROT-02 ERC fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [256]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-02 ERC stress" {
    const seeds = [_][]const u8{
        &([_]u8{12} ++ unhex(ERC20_TRANSFER_TOPICS) ++ unhex(ERC20_TRANSFER_DATA)),
        &([_]u8{12} ++ unhex(ERC20_APPROVAL_TOPICS) ++ unhex(ERC20_TRANSFER_DATA)),
        &([_]u8{16} ++ unhex(ERC721_TRANSFER_TOPICS)),
        &([_]u8{16} ++ unhex(ERC721_APPROVAL_TOPICS)),
        &([_]u8{16} ++ unhex(ERC1155_TOPICS) ++ unhex(ERC1155_DATA)),
    };
    fuzz.stress(200_000, &seeds, {}, exercise);
}
