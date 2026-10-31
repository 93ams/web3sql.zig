//! Catalogue entries over `core`, always present.
const core = @import("../core/root.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;

fn digestFn(comptime len: usize, comptime hash: fn ([]const u8, *[len]u8) void) fn ([]const u8, []u8) error{BufferTooSmall}![]const u8 {
    return struct {
        fn f(data: []const u8, dest: []u8) error{BufferTooSmall}![]const u8 {
            if (dest.len < len) return error.BufferTooSmall;
            hash(data, dest[0..len]);
            return dest[0..len];
        }
    }.f;
}

const enc = core.encodings;
const math = core.math;

fn base64Url(data: []const u8, dest: []u8) enc.base64.Base64Error![]const u8 {
    return enc.base64.encode(.url_no_pad, data, dest);
}
fn base64UrlDecode(text: []const u8, dest: []u8) enc.base64.Base64Error![]u8 {
    return enc.base64.decode(.url_no_pad, text, dest);
}
fn hexDecode(text: []const u8, dest: []u8) enc.hex.HexError![]const u8 {
    return enc.hex.decodeHex(text, dest);
}
fn base58Decode(text: []const u8, dest: []u8) enc.base58.Base58Error![]const u8 {
    return enc.base58.decodeBase58(text, dest);
}
fn base58CheckDecode(text: []const u8, dest: []u8) enc.base58.Base58Error![]const u8 {
    return enc.base58.decodeCheck(text, dest);
}
fn base64Decode(text: []const u8, dest: []u8) enc.base64.Base64Error![]const u8 {
    return enc.base64.decodeBase64(text, dest);
}
fn bigEndianWord(data: []const u8) error{InvalidLength}!u256 {
    if (data.len == 0 or data.len > 32) return error.InvalidLength;
    var word: u256 = 0;
    for (data) |b| word = (word << 8) | b;
    return word;
}
fn u256FromBytes(data: []const u8, dest: []u8) (error{InvalidLength} || math.MathError)![]const u8 {
    return math.formatDecimal(try bigEndianWord(data), dest);
}
fn i256FromBytes(data: []const u8, dest: []u8) (error{InvalidLength} || math.MathError)![]const u8 {
    if (data.len == 0) return error.InvalidLength;
    const word = try bigEndianWord(data);
    const unused: u8 = @intCast(256 - 8 * data.len); // sign-extends a value shorter than 32 bytes
    const signed: i256 = @bitCast(word << unused);
    return math.formatDecimalSigned(signed >> unused, dest);
}
fn u256ToBytes(text: []const u8, dest: []u8) (error{BufferTooSmall} || math.MathError)![]const u8 {
    if (dest.len < 32) return error.BufferTooSmall;
    dest[0..32].* = math.toBytes(try math.parseDecimal(text), .big);
    return dest[0..32];
}
fn mulDivDecimal(a: []const u8, b: []const u8, c: []const u8, dest: []u8) math.MathError![]const u8 {
    return math.formatDecimal(try math.mulDiv(try math.parseDecimal(a), try math.parseDecimal(b), try math.parseDecimal(c)), dest);
}

fn version() []const u8 {
    return @import("root.zig").version;
}

pub const entries = [_]catalog.Function{
    func("web3_version", "Version of this build", &.{}, .text, version),
    func("web3_keccak256", "Keccak-256 digest", &.{.bytes}, .bytes, digestFn(32, core.crypto.keccak.hash)),
    func("web3_sha256", "SHA-256 digest", &.{.bytes}, .bytes, digestFn(32, core.crypto.sha256.hash)),
    func("web3_sha256d", "Double SHA-256 digest", &.{.bytes}, .bytes, digestFn(32, core.crypto.sha256.doubleHash)),
    func("web3_ripemd160", "RIPEMD-160 digest", &.{.bytes}, .bytes, digestFn(20, core.crypto.ripemd160.hash)),
    func("web3_hash160", "Bitcoin HASH160: RIPEMD160(SHA256(x))", &.{.bytes}, .bytes, digestFn(20, core.crypto.ripemd160.hash160)),
    func("web3_blake2b256", "Blake2b-256 digest", &.{.bytes}, .bytes, digestFn(32, core.crypto.blake2b.hash)),
    func("web3_blake3", "Blake3 digest", &.{.bytes}, .bytes, digestFn(32, core.crypto.blake3.hash)),
    func("web3_hex_encode", "Lowercase hex without 0x", &.{.bytes}, .text, enc.hex.encodeHex),
    func("web3_hex_decode", "Bytes from hex, optional 0x", &.{.text}, .bytes, hexDecode),
    func("web3_base58_encode", "Base58", &.{.bytes}, .text, enc.base58.encodeBase58),
    func("web3_base58_decode", "Bytes from Base58", &.{.text}, .bytes, base58Decode),
    func("web3_base58check_encode", "Base58Check", &.{.bytes}, .text, enc.base58.encodeCheck),
    func("web3_base58check_decode", "Payload from Base58Check", &.{.text}, .bytes, base58CheckDecode),
    func("web3_base64_encode", "Base64 with padding", &.{.bytes}, .text, enc.base64.encodeBase64),
    func("web3_base64_decode", "Bytes from padded Base64", &.{.text}, .bytes, base64Decode),
    func("web3_base64url_encode", "Base64URL without padding", &.{.bytes}, .text, base64Url),
    func("web3_base64url_decode", "Bytes from unpadded Base64URL", &.{.text}, .bytes, base64UrlDecode),
    func("web3_u256_from_bytes", "Decimal from up to 32 big-endian bytes", &.{.bytes}, .text, u256FromBytes),
    func("web3_i256_from_bytes", "Signed decimal from up to 32 big-endian bytes, sign-extended", &.{.bytes}, .text, i256FromBytes),
    func("web3_u256_to_bytes", "32 big-endian bytes from decimal", &.{.text}, .bytes, u256ToBytes),
    func("web3_mul_div", "floor(a*b/c) on decimal strings at 512-bit precision", &.{ .text, .text, .text }, .text, mulDivDecimal),
};
