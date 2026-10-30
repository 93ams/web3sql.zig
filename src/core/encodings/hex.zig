const std = @import("std");

pub const HexError = error{
    InvalidLength,
    InvalidCharacter,
    BufferTooSmall,
};

pub const HEX_LOWER = "0123456789abcdef";

const V16 = @Vector(16, u8);

fn nibblesToAscii(n: V16) V16 {
    const is_letter = n > @as(V16, @splat(9));
    return n +% @as(V16, @splat('0')) +% @select(u8, is_letter, @as(V16, @splat('a' - '0' - 10)), @as(V16, @splat(0)));
}

const INTERLEAVE_LOW: @Vector(16, i32) = .{ 0, ~@as(i32, 0), 1, ~@as(i32, 1), 2, ~@as(i32, 2), 3, ~@as(i32, 3), 4, ~@as(i32, 4), 5, ~@as(i32, 5), 6, ~@as(i32, 6), 7, ~@as(i32, 7) };
const INTERLEAVE_HIGH: @Vector(16, i32) = .{ 8, ~@as(i32, 8), 9, ~@as(i32, 9), 10, ~@as(i32, 10), 11, ~@as(i32, 11), 12, ~@as(i32, 12), 13, ~@as(i32, 13), 14, ~@as(i32, 14), 15, ~@as(i32, 15) };
const EVENS: @Vector(16, i32) = .{ 0, 2, 4, 6, 8, 10, 12, 14, ~@as(i32, 0), ~@as(i32, 2), ~@as(i32, 4), ~@as(i32, 6), ~@as(i32, 8), ~@as(i32, 10), ~@as(i32, 12), ~@as(i32, 14) };
const ODDS: @Vector(16, i32) = .{ 1, 3, 5, 7, 9, 11, 13, 15, ~@as(i32, 1), ~@as(i32, 3), ~@as(i32, 5), ~@as(i32, 7), ~@as(i32, 9), ~@as(i32, 11), ~@as(i32, 13), ~@as(i32, 15) };

/// Encodes raw bytes to lowercase hexadecimal string.
pub fn encodeHex(src: []const u8, dest: []u8) HexError![]const u8 {
    const out_len = src.len * 2;
    if (dest.len < out_len) return HexError.BufferTooSmall;
    var i: usize = 0;
    while (i + 16 <= src.len) : (i += 16) {
        const v: V16 = src[i..][0..16].*;
        const hi = nibblesToAscii(v >> @splat(4));
        const lo = nibblesToAscii(v & @as(V16, @splat(0x0F)));
        dest[i * 2 ..][0..16].* = @shuffle(u8, hi, lo, INTERLEAVE_LOW);
        dest[i * 2 + 16 ..][0..16].* = @shuffle(u8, hi, lo, INTERLEAVE_HIGH);
    }
    for (src[i..], i..) |byte, j| {
        dest[j * 2] = HEX_LOWER[byte >> 4];
        dest[j * 2 + 1] = HEX_LOWER[byte & 0x0F];
    }
    return dest[0..out_len];
}

/// Maps ASCII hex to nibbles; any invalid character maps to 0xFF.
fn asciiToNibbles(c: V16) V16 {
    const digit = c -% @as(V16, @splat('0'));
    const letter = (c | @as(V16, @splat(0x20))) -% @as(V16, @splat('a'));
    const letter_val = @select(u8, letter < @as(V16, @splat(6)), letter +% @as(V16, @splat(10)), @as(V16, @splat(0xFF)));
    return @select(u8, digit < @as(V16, @splat(10)), digit, letter_val);
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

    var i: usize = 0;
    while (i + 16 <= out_len) : (i += 16) {
        const a = asciiToNibbles(raw[i * 2 ..][0..16].*);
        const b = asciiToNibbles(raw[i * 2 + 16 ..][0..16].*);
        if (@reduce(.Max, a | b) > 0x0F) return HexError.InvalidCharacter;
        const hi = @shuffle(u8, a, b, EVENS);
        const lo = @shuffle(u8, a, b, ODDS);
        dest[i..][0..16].* = (hi << @splat(4)) | lo;
    }
    while (i < out_len) : (i += 1) {
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

test "REQ-CORE-02 hex simd matches scalar on every byte value and length" {
    var src: [256]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    var enc: [512]u8 = undefined;
    var dec: [256]u8 = undefined;
    for (0..257) |n| {
        const e = try encodeHex(src[0..n], &enc);
        for (src[0..n], 0..) |b, i| {
            try std.testing.expectEqual(HEX_LOWER[b >> 4], e[i * 2]);
            try std.testing.expectEqual(HEX_LOWER[b & 0xF], e[i * 2 + 1]);
        }
        try std.testing.expectEqualSlices(u8, src[0..n], try decodeHex(e, &dec));
    }
    var upper: [512]u8 = undefined;
    const up = std.ascii.upperString(&upper, try encodeHex(&src, &enc));
    try std.testing.expectEqualSlices(u8, &src, try decodeHex(up, &dec));
}

test "REQ-CORE-02 hex rejects each invalid byte at every simd lane" {
    var enc: [64]u8 = @splat('a');
    var dec: [32]u8 = undefined;
    for (0..256) |c| {
        const valid = std.ascii.isHex(@intCast(c));
        for (0..enc.len) |pos| {
            enc[pos] = @intCast(c);
            if (valid) {
                _ = try decodeHex(&enc, &dec);
            } else {
                try std.testing.expectError(HexError.InvalidCharacter, decodeHex(&enc, &dec));
            }
            enc[pos] = 'a';
        }
    }
    try std.testing.expectError(HexError.InvalidLength, decodeHex("abc", &dec));
    try std.testing.expectError(HexError.BufferTooSmall, decodeHex(&enc, dec[0..31]));
}

test "hex fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [128]u8 = undefined;
            var out: [64]u8 = undefined;
            _ = decodeHex(buf[0..smith.slice(&buf)], &out) catch {};
        }
    }.f, .{});
}
