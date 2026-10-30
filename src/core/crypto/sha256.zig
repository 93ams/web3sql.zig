const std = @import("std");

pub const Sha256 = std.crypto.hash.sha2.Sha256;
pub const DIGEST_LENGTH: usize = Sha256.digest_length;

/// Computes single SHA-256 hash.
pub fn hash(data: []const u8, out: *[DIGEST_LENGTH]u8) void {
    Sha256.hash(data, out, .{});
}

/// Computes double SHA-256 hash (SHA256(SHA256(data))), standard in Bitcoin / UTXO.
pub fn doubleHash(data: []const u8, out: *[DIGEST_LENGTH]u8) void {
    var intermediate: [DIGEST_LENGTH]u8 = undefined;
    Sha256.hash(data, &intermediate, .{});
    Sha256.hash(&intermediate, out, .{});
}

test "sha256 and doubleHash" {
    var out: [DIGEST_LENGTH]u8 = undefined;
    hash("hello", &out);
    try std.testing.expect(out.len == 32);

    var d_out: [DIGEST_LENGTH]u8 = undefined;
    doubleHash("hello", &d_out);
    try std.testing.expect(d_out.len == 32);
}

test "REQ-CORE-03 sha256 and double sha256 known answers" {
    // FIPS 180-4 "abc"; double hash from hashlib.sha256(hashlib.sha256(b"abc").digest()).
    var out: [DIGEST_LENGTH]u8 = undefined;
    var expected: [DIGEST_LENGTH]u8 = undefined;
    hash("abc", &out);
    _ = try std.fmt.hexToBytes(&expected, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectEqualSlices(u8, &expected, &out);
    doubleHash("abc", &out);
    _ = try std.fmt.hexToBytes(&expected, "4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}
