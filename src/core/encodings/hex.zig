const std = @import("std");

pub const HexError = error{
    InvalidLength,
    InvalidCharacter,
    BufferTooSmall,
};

pub const HEX_LOWER = "0123456789abcdef";

/// Encodes raw bytes to lowercase hexadecimal string.
pub fn encodeHex(src: []const u8, dest: []u8) HexError![]const u8 {
    const out_len = src.len * 2;
    if (dest.len < out_len) return HexError.BufferTooSmall;
    for (src, 0..) |byte, i| {
        dest[i * 2] = HEX_LOWER[byte >> 4];
        dest[i * 2 + 1] = HEX_LOWER[byte & 0x0F];
    }
    return dest[0..out_len];
}

/// Decodes hex string (optionally prefixed with "0x" or "0X") into raw bytes.
pub fn decodeHex(src: []const u8, dest: []u8) HexError![]u8 {
    var raw = src;
    if (raw.len >= 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
        raw = raw[2..];
    }
    if (raw.len % 2 != 0) return HexError.InvalidLength;
    const out_len = raw.len / 2;
    if (dest.len < out_len) return HexError.BufferTooSmall;

    for (0..out_len) |i| {
        const hi: u8 = try charToNibble(raw[i * 2]);
        const lo: u8 = try charToNibble(raw[i * 2 + 1]);
        dest[i] = (hi << 4) | lo;
    }
    return dest[0..out_len];
}

fn charToNibble(c: u8) HexError!u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => HexError.InvalidCharacter,
    };
}

test "hex encode and decode" {
    const input = "hello web3";
    var hex_buf: [32]u8 = undefined;
    const encoded = try encodeHex(input, &hex_buf);
    try std.testing.expectEqualStrings("68656c6c6f2077656233", encoded);

    var dec_buf: [32]u8 = undefined;
    const decoded = try decodeHex("0x68656c6c6f2077656233", &dec_buf);
    try std.testing.expectEqualStrings(input, decoded);
}
