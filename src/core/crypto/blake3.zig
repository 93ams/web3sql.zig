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

test "REQ-CORE-03 blake3 official vectors" {
    const vectors = @import("blake3_vectors.zig");
    var input: [31744 + 1024]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i % 251);
    var out: [DIGEST_LENGTH]u8 = undefined;
    var expected: [DIGEST_LENGTH]u8 = undefined;
    for (vectors.cases) |c| {
        if (c.len > input.len) continue;
        hash(input[0..c.len], &out);
        _ = try std.fmt.hexToBytes(&expected, c.hash);
        try std.testing.expectEqualSlices(u8, &expected, &out);
    }
}
