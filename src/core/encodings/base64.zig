const std = @import("std");

pub const Base64Error = error{
    BufferTooSmall,
    InvalidCharacter,
    InvalidPadding,
};

/// Encodes raw bytes using standard Base64 encoder.
pub fn encodeBase64(src: []const u8, dest: []u8) Base64Error![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const req_len = encoder.calcSize(src.len);
    if (dest.len < req_len) return Base64Error.BufferTooSmall;
    return encoder.encode(dest[0..req_len], src);
}

/// Decodes standard Base64 string into dest buffer.
pub fn decodeBase64(src: []const u8, dest: []u8) Base64Error![]u8 {
    const decoder = std.base64.standard.Decoder;
    const req_len = decoder.calcSizeForSlice(src) catch return Base64Error.InvalidPadding;
    if (dest.len < req_len) return Base64Error.BufferTooSmall;
    decoder.decode(dest[0..req_len], src) catch return Base64Error.InvalidCharacter;
    return dest[0..req_len];
}

test "base64 encode and decode" {
    const msg = "web3sql base64 test";
    var enc_buf: [64]u8 = undefined;
    const enc = try encodeBase64(msg, &enc_buf);
    var dec_buf: [64]u8 = undefined;
    const dec = try decodeBase64(enc, &dec_buf);
    try std.testing.expectEqualStrings(msg, dec);
}
