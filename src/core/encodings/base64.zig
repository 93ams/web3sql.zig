const std = @import("std");

pub const Base64Error = error{
    BufferTooSmall,
    InvalidCharacter,
    InvalidPadding,
};

/// RFC 4648 §4 (`standard`) and §5 (`url`), with or without `=` padding.
pub const Variant = enum {
    standard,
    standard_no_pad,
    url,
    url_no_pad,

    fn codecs(self: Variant) *const std.base64.Codecs {
        return switch (self) {
            .standard => &std.base64.standard,
            .standard_no_pad => &std.base64.standard_no_pad,
            .url => &std.base64.url_safe,
            .url_no_pad => &std.base64.url_safe_no_pad,
        };
    }
};

pub fn encode(variant: Variant, src: []const u8, dest: []u8) Base64Error![]const u8 {
    const encoder = variant.codecs().Encoder;
    const req_len = encoder.calcSize(src.len);
    if (dest.len < req_len) return Base64Error.BufferTooSmall;
    return encoder.encode(dest[0..req_len], src);
}

/// Strict decode: rejects bad alphabet, bad padding and non-zero trailing bits.
pub fn decode(variant: Variant, src: []const u8, dest: []u8) Base64Error![]u8 {
    const decoder = variant.codecs().Decoder;
    const req_len = decoder.calcSizeForSlice(src) catch return Base64Error.InvalidPadding;
    if (dest.len < req_len) return Base64Error.BufferTooSmall;
    decoder.decode(dest[0..req_len], src) catch |err| return switch (err) {
        error.InvalidCharacter => Base64Error.InvalidCharacter,
        error.InvalidPadding => Base64Error.InvalidPadding,
        error.NoSpaceLeft => Base64Error.BufferTooSmall,
    };
    return dest[0..req_len];
}

/// Encodes raw bytes using standard Base64 encoder.
pub fn encodeBase64(src: []const u8, dest: []u8) Base64Error![]const u8 {
    return encode(.standard, src, dest);
}

/// Decodes standard Base64 string into dest buffer.
pub fn decodeBase64(src: []const u8, dest: []u8) Base64Error![]u8 {
    return decode(.standard, src, dest);
}

test "base64 encode and decode" {
    const msg = "web3sql base64 test";
    var enc_buf: [64]u8 = undefined;
    const enc = try encodeBase64(msg, &enc_buf);
    var dec_buf: [64]u8 = undefined;
    const dec = try decodeBase64(enc, &dec_buf);
    try std.testing.expectEqualStrings(msg, dec);
}

test "REQ-CORE-02 base64 RFC 4648 section 10 vectors" {
    const cases = [_][2][]const u8{
        .{ "", "" },
        .{ "f", "Zg==" },
        .{ "fo", "Zm8=" },
        .{ "foo", "Zm9v" },
        .{ "foob", "Zm9vYg==" },
        .{ "fooba", "Zm9vYmE=" },
        .{ "foobar", "Zm9vYmFy" },
    };
    var txt: [16]u8 = undefined;
    var bin: [16]u8 = undefined;
    for (cases) |c| {
        try std.testing.expectEqualStrings(c[1], try encode(.standard, c[0], &txt));
        try std.testing.expectEqualStrings(c[0], try decode(.standard, c[1], &bin));
        const unpadded = std.mem.trimEnd(u8, c[1], "=");
        try std.testing.expectEqualStrings(unpadded, try encode(.url_no_pad, c[0], &txt));
        try std.testing.expectEqualStrings(c[0], try decode(.url_no_pad, unpadded, &bin));
    }
}

test "REQ-CORE-02 base64 url alphabet and strictness" {
    var txt: [16]u8 = undefined;
    var bin: [16]u8 = undefined;
    const raw = [_]u8{ 0xfb, 0xff };
    try std.testing.expectEqualStrings("+/8=", try encode(.standard, &raw, &txt));
    try std.testing.expectEqualStrings("-_8=", try encode(.url, &raw, &txt));
    try std.testing.expectError(Base64Error.InvalidCharacter, decode(.standard, "-_8=", &bin));
    try std.testing.expectError(Base64Error.InvalidCharacter, decode(.url, "+/8=", &bin));
    try std.testing.expectError(Base64Error.InvalidPadding, decode(.standard, "Zg", &bin));
    try std.testing.expectError(Base64Error.InvalidPadding, decode(.standard, "Zg=", &bin));
    // "Zh==" carries non-zero trailing bits: same byte as "Zg==" but not canonical.
    try std.testing.expectError(Base64Error.InvalidPadding, decode(.standard, "Zh==", &bin));
    try std.testing.expectError(Base64Error.BufferTooSmall, decode(.standard, "Zm9vYmFy", bin[0..5]));
}

test "base64 fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [128]u8 = undefined;
            var out: [128]u8 = undefined;
            const n = smith.slice(&buf);
            for (std.enums.values(Variant)) |v| _ = decode(v, buf[0..n], &out) catch {};
        }
    }.f, .{});
}
