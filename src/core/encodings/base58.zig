const std = @import("std");
const sha256 = @import("../crypto/sha256.zig");
const vectors = @import("base58_vectors.zig");

pub const Base58Error = error{
    InvalidCharacter,
    BufferTooSmall,
    InvalidChecksum,
    InputTooLarge,
};

pub const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Largest binary input to encode; covers every on-chain address, pubkey and signature form.
pub const MAX_DECODED_LEN: usize = 128;
/// Base58 length of MAX_DECODED_LEN bytes of 0xFF, and the largest accepted text input.
pub const MAX_ENCODED_LEN: usize = 176;

// 58^5 fits in 30 bits, so limb arithmetic stays in u64 where division by a constant is a
// multiply. The roadmap's 58^10 limbs would need u128 division, which is a libcall.
const LIMB_DIGITS = 5;
const LIMB_BASE: u64 = 656_356_768;
const LIMB_COUNT = MAX_ENCODED_LEN / LIMB_DIGITS + 1;

const DECODE_MAP: [256]u8 = blk: {
    var map: [256]u8 = @splat(0xFF);
    for (ALPHABET, 0..) |c, i| map[c] = i;
    break :blk map;
};

/// Encodes raw bytes into Base58 string into dest buffer.
pub fn encodeBase58(src: []const u8, dest: []u8) Base58Error![]const u8 {
    if (src.len > MAX_DECODED_LEN) return Base58Error.InputTooLarge;
    var zeroes: usize = 0;
    while (zeroes < src.len and src[zeroes] == 0) : (zeroes += 1) {}

    // Little-endian limbs in base 58^5, fed 32 bits at a time.
    var limbs: [LIMB_COUNT]u32 = undefined;
    var used: usize = 0;
    var rest = src[zeroes..];
    while (rest.len > 0) {
        const take = if (rest.len % 4 == 0) 4 else rest.len % 4;
        var carry: u64 = 0;
        for (rest[0..take]) |b| carry = (carry << 8) | b;
        rest = rest[take..];
        const shift: u6 = @intCast(take * 8);
        for (limbs[0..used]) |*limb| {
            const acc = (@as(u64, limb.*) << shift) + carry;
            limb.* = @intCast(acc % LIMB_BASE);
            carry = acc / LIMB_BASE;
        }
        while (carry != 0) {
            limbs[used] = @intCast(carry % LIMB_BASE);
            carry /= LIMB_BASE;
            used += 1;
        }
    }

    var digits: [LIMB_COUNT * LIMB_DIGITS]u8 = undefined;
    var at: usize = digits.len;
    for (limbs[0..used]) |limb| {
        var v = limb;
        for (0..LIMB_DIGITS) |_| {
            at -= 1;
            digits[at] = ALPHABET[v % 58];
            v /= 58;
        }
    }
    while (at < digits.len and digits[at] == '1') at += 1;

    const total_len = zeroes + digits.len - at;
    if (dest.len < total_len) return Base58Error.BufferTooSmall;
    @memset(dest[0..zeroes], '1');
    @memcpy(dest[zeroes..total_len], digits[at..]);
    return dest[0..total_len];
}

/// Decodes Base58 text; dest receives the exact binary value, leading '1's becoming zero bytes.
pub fn decodeBase58(src: []const u8, dest: []u8) Base58Error![]u8 {
    if (src.len > MAX_ENCODED_LEN) return Base58Error.InputTooLarge;
    var ones: usize = 0;
    while (ones < src.len and src[ones] == '1') : (ones += 1) {}

    // Little-endian base-2^32 limbs, fed 5 digits at a time.
    var limbs: [MAX_ENCODED_LEN / 5 + 2]u32 = undefined;
    var used: usize = 0;
    var rest = src[ones..];
    while (rest.len > 0) {
        const take = if (rest.len % LIMB_DIGITS == 0) LIMB_DIGITS else rest.len % LIMB_DIGITS;
        var carry: u64 = 0;
        var mul: u64 = 1;
        for (rest[0..take]) |c| {
            const d = DECODE_MAP[c];
            if (d == 0xFF) return Base58Error.InvalidCharacter;
            carry = carry * 58 + d;
            mul *= 58;
        }
        rest = rest[take..];
        for (limbs[0..used]) |*limb| {
            const acc = @as(u64, limb.*) * mul + carry;
            limb.* = @truncate(acc);
            carry = acc >> 32;
        }
        if (carry != 0) {
            limbs[used] = @intCast(carry);
            used += 1;
        }
    }

    var bytes: [limbs.len * 4]u8 = undefined;
    for (limbs[0..used], 0..) |limb, i| {
        std.mem.writeInt(u32, bytes[bytes.len - (i + 1) * 4 ..][0..4], limb, .big);
    }
    var at = bytes.len - used * 4;
    while (at < bytes.len and bytes[at] == 0) at += 1;

    const total_len = ones + bytes.len - at;
    if (dest.len < total_len) return Base58Error.BufferTooSmall;
    @memset(dest[0..ones], 0);
    @memcpy(dest[ones..total_len], bytes[at..]);
    return dest[0..total_len];
}

/// Base58Check: payload || first 4 bytes of SHA256(SHA256(payload)).
pub fn encodeCheck(payload: []const u8, dest: []u8) Base58Error![]const u8 {
    if (payload.len + 4 > MAX_DECODED_LEN) return Base58Error.InputTooLarge;
    var buf: [MAX_DECODED_LEN]u8 = undefined;
    @memcpy(buf[0..payload.len], payload);
    var digest: [32]u8 = undefined;
    sha256.doubleHash(payload, &digest);
    buf[payload.len..][0..4].* = digest[0..4].*;
    return encodeBase58(buf[0 .. payload.len + 4], dest);
}

/// Decodes Base58Check, verifying the checksum. Returns the payload without the checksum.
pub fn decodeCheck(src: []const u8, dest: []u8) Base58Error![]u8 {
    var buf: [MAX_ENCODED_LEN]u8 = undefined;
    const raw = try decodeBase58(src, &buf);
    if (raw.len < 4) return Base58Error.InvalidChecksum;
    const payload = raw[0 .. raw.len - 4];
    var digest: [32]u8 = undefined;
    sha256.doubleHash(payload, &digest);
    if (!std.mem.eql(u8, digest[0..4], raw[payload.len..])) return Base58Error.InvalidChecksum;
    if (dest.len < payload.len) return Base58Error.BufferTooSmall;
    @memcpy(dest[0..payload.len], payload);
    return dest[0..payload.len];
}

test "base58 encode smoke test" {
    var buf: [64]u8 = undefined;
    const res = try encodeBase58("Hello World", &buf);
    try std.testing.expectEqualStrings("JxF12TrwUP45BMd", res);
}

test "REQ-CORE-02 base58 Bitcoin Core vectors" {
    var bin: [MAX_DECODED_LEN]u8 = undefined;
    var txt: [MAX_ENCODED_LEN]u8 = undefined;
    var out: [MAX_DECODED_LEN]u8 = undefined;
    const hex = @import("hex.zig");
    for (vectors.cases) |c| {
        if (c.hex.len / 2 > MAX_DECODED_LEN) continue; // Core's long-input cases exceed the documented bound
        const raw = try hex.decodeHex(c.hex, &bin);
        try std.testing.expectEqualStrings(c.b58, try encodeBase58(raw, &txt));
        try std.testing.expectEqualSlices(u8, raw, try decodeBase58(c.b58, &out));
    }
}

test "REQ-CORE-02 base58 bounds and malformed input" {
    var out: [MAX_DECODED_LEN]u8 = undefined;
    var txt: [MAX_ENCODED_LEN]u8 = undefined;
    try std.testing.expectError(Base58Error.InvalidCharacter, decodeBase58("0OIl", &out));
    try std.testing.expectError(Base58Error.InvalidCharacter, decodeBase58("abc def", &out));
    try std.testing.expectError(Base58Error.BufferTooSmall, decodeBase58("JxF12TrwUP45BMd", out[0..4]));
    const max: [MAX_DECODED_LEN]u8 = @splat(0xFF);
    const enc = try encodeBase58(&max, &txt);
    try std.testing.expect(enc.len <= MAX_ENCODED_LEN);
    try std.testing.expectEqualSlices(u8, &max, try decodeBase58(enc, &out));
    const zeros: [MAX_DECODED_LEN]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zeros, try decodeBase58(try encodeBase58(&zeros, &txt), &out));
    const too_long: [MAX_DECODED_LEN + 1]u8 = @splat(1);
    try std.testing.expectError(Base58Error.InputTooLarge, encodeBase58(&too_long, &txt));
    const long_txt: [MAX_ENCODED_LEN + 1]u8 = @splat('z');
    try std.testing.expectError(Base58Error.InputTooLarge, decodeBase58(&long_txt, &out));
    // 176 'z' overflows MAX_DECODED_LEN but must only ever yield BufferTooSmall.
    try std.testing.expectError(Base58Error.BufferTooSmall, decodeBase58(long_txt[1..], &out));
}

test "REQ-CORE-02 base58check known address" {
    // Bitcoin wiki "Technical background of version 1 Bitcoin addresses".
    var out: [32]u8 = undefined;
    var txt: [64]u8 = undefined;
    const addr = "16UwLL9Risc3QfPqBUvKofHmBQ7wMtjvM";
    const payload = try decodeCheck(addr, &out);
    try std.testing.expectEqual(@as(usize, 21), payload.len);
    try std.testing.expectEqualStrings(addr, try encodeCheck(payload, &txt));
    try std.testing.expectError(Base58Error.InvalidChecksum, decodeCheck("16UwLL9Risc3QfPqBUvKofHmBQ7wMtjvN", &out));
    try std.testing.expectError(Base58Error.InvalidChecksum, decodeCheck("1", &out));
}

test "base58 fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [200]u8 = undefined;
            var out: [MAX_DECODED_LEN]u8 = undefined;
            const n = smith.slice(&buf);
            _ = decodeBase58(buf[0..n], &out) catch {};
            _ = decodeCheck(buf[0..n], &out) catch {};
        }
    }.f, .{});
}
