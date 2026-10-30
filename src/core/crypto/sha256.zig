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
