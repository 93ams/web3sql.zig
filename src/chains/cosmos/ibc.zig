const std = @import("std");
const sha256 = @import("../../core/crypto/sha256.zig");
const hex = @import("../../core/encodings/hex.zig");

pub const IbcError = error{
    BufferTooSmall,
};

/// Computes the IBC denom trace hash ("ibc/" + hex_upper(sha256(trace))).
pub fn deriveIbcDenom(trace: []const u8, dest: []u8) IbcError![]const u8 {
    // "ibc/" is 4 bytes + 64 hex chars = 68 bytes
    if (dest.len < 68) return IbcError.BufferTooSmall;

    @memcpy(dest[0..4], "ibc/");

    var hash_buf: [32]u8 = undefined;
    sha256.hash(trace, &hash_buf);

    var hex_buf: [64]u8 = undefined;
    _ = hex.encodeHex(&hash_buf, &hex_buf) catch unreachable;

    for (0..64) |i| {
        dest[4 + i] = std.ascii.toUpper(hex_buf[i]);
    }

    return dest[0..68];
}

test "derive ibc denom" {
    var out: [68]u8 = undefined;
    const denom = try deriveIbcDenom("transfer/channel-141/uatom", &out);
    try std.testing.expectEqualStrings("ibc/", denom[0..4]);
    try std.testing.expectEqual(68, denom.len);
}
