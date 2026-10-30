const std = @import("std");

pub const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
pub const DIGEST_LENGTH: usize = Blake2b256.digest_length;

/// Computes zero-allocation Blake2b-256 hash.
pub fn hash(data: []const u8, out: *[DIGEST_LENGTH]u8) void {
    Blake2b256.hash(data, out, .{});
}

test "blake2b256 smoke test" {
    var out: [DIGEST_LENGTH]u8 = undefined;
    hash("hello web3sql", &out);
    try std.testing.expect(out.len == 32);
}

test "REQ-CORE-03 blake2b-256 known answer" {
    // RFC 7693 appendix family; matches Python hashlib.blake2b(b"abc", digest_size=32).
    var out: [DIGEST_LENGTH]u8 = undefined;
    var expected: [DIGEST_LENGTH]u8 = undefined;
    hash("abc", &out);
    _ = try std.fmt.hexToBytes(&expected, "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}
