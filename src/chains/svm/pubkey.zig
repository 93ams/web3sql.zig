const std = @import("std");
const base58 = @import("../../core/encodings/base58.zig");

pub const Pubkey = [32]u8;

pub const SvmError = error{
    InvalidPubkey,
    NoBumpFound,
    BufferTooSmall,
};

/// Encodes pubkey into Base58 representation.
pub fn toBase58(pubkey: *const Pubkey, dest: []u8) SvmError![]const u8 {
    return base58.encodeBase58(pubkey, dest) catch SvmError.BufferTooSmall;
}

test "svm pubkey base58" {
    const pk: Pubkey = @splat(0);
    var buf: [64]u8 = undefined;
    const b58 = try toBase58(&pk, &buf);
    // 32 zeros in base58 is 32 '1's
    try std.testing.expectEqual(32, b58.len);
    try std.testing.expectEqual(@as(u8, '1'), b58[0]);
}
