const std = @import("std");

pub const Base58Error = error{
    InvalidCharacter,
    BufferTooSmall,
    InvalidChecksum,
};

pub const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Encodes raw bytes into Base58 string into dest buffer.
pub fn encodeBase58(src: []const u8, dest: []u8) Base58Error![]const u8 {
    var zeroes: usize = 0;
    while (zeroes < src.len and src[zeroes] == 0) : (zeroes += 1) {}

    var b58: [512]u8 = @splat(0);
    if (src.len * 138 / 100 + 1 > b58.len) return Base58Error.BufferTooSmall;
    var length: usize = 0;

    for (src[zeroes..]) |byte| {
        var carry: u32 = byte;
        var i: usize = 0;
        while (i < length or carry != 0) : (i += 1) {
            if (i >= b58.len) return Base58Error.BufferTooSmall;
            carry += @as(u32, b58[i]) << 8;
            b58[i] = @intCast(carry % 58);
            carry /= 58;
        }
        length = i;
    }

    const total_len = zeroes + length;
    if (dest.len < total_len) return Base58Error.BufferTooSmall;

    for (0..zeroes) |i| {
        dest[i] = '1';
    }
    for (0..length) |i| {
        dest[zeroes + i] = ALPHABET[b58[length - 1 - i]];
    }

    return dest[0..total_len];
}

test "base58 encode smoke test" {
    var buf: [64]u8 = undefined;
    const res = try encodeBase58("Hello World", &buf);
    try std.testing.expectEqualStrings("JxF12TrwUP45BMd", res);
}
