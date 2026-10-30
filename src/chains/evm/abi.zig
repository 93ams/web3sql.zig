const std = @import("std");
const keccak = @import("../../core/crypto/keccak.zig");

pub const Selector = [4]u8;
pub const Topic = [32]u8;

/// Computes the 4-byte function selector from a canonical signature e.g. "transfer(address,uint256)".
pub fn computeSelector(signature: []const u8) Selector {
    var hash_buf: [32]u8 = undefined;
    keccak.hash(signature, &hash_buf);
    return hash_buf[0..4].*;
}

/// Computes event topic0 from an event signature e.g. "Transfer(address,address,uint256)".
pub fn computeTopic0(signature: []const u8) Topic {
    var hash_buf: [32]u8 = undefined;
    keccak.hash(signature, &hash_buf);
    return hash_buf;
}

test "compute selector and topic0" {
    // transfer(address,uint256) -> a9059cbb
    const sel = computeSelector("transfer(address,uint256)");
    const expected_sel = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try std.testing.expectEqual(expected_sel, sel);

    // Transfer(address,address,uint256) -> ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
    const topic = computeTopic0("Transfer(address,address,uint256)");
    const expected_topic = "\xdd\xf2\x52\xad\x1b\xe2\xc8\x9b\x69\xc2\xb0\x68\xfc\x37\x8d\xaa\x95\x2b\xa7\xf1\x63\xc4\xa1\x16\x28\xf5\x5a\x4d\xf5\x23\xb3\xef";
    try std.testing.expectEqualStrings(expected_topic, &topic);
}
