const std = @import("std");

pub const Blake3 = std.crypto.hash.Blake3;
pub const DIGEST_LENGTH: usize = 32;

/// Computes zero-allocation Blake3 hash (default 32-byte output).
pub fn hash(data: []const u8, out: *[DIGEST_LENGTH]u8) void {
    Blake3.hash(data, out, .{});
}

test "blake3 smoke test" {
    var out: [DIGEST_LENGTH]u8 = undefined;
    hash("hello web3sql", &out);
    try std.testing.expect(out.len == 32);
}
