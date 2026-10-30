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
