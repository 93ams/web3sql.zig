const std = @import("std");

pub const TransferEvent = struct {
    from: [20]u8,
    to: [20]u8,
    value: u256,
};

pub const TokenError = error{
    InvalidTopicCount,
    InvalidDataLength,
};

/// Fast-path zero-allocation decoder for ERC-20 Transfer(address,address,uint256) logs.
/// topics[1] = indexed from (address in lower 20 bytes of 32-byte topic)
/// topics[2] = indexed to (address in lower 20 bytes of 32-byte topic)
/// data = unindexed value (uint256, 32 bytes)
pub fn decodeTransferLog(topics: []const [32]u8, data: []const u8) TokenError!TransferEvent {
    if (topics.len < 3) return TokenError.InvalidTopicCount;
    if (data.len < 32) return TokenError.InvalidDataLength;

    var from: [20]u8 = undefined;
    var to: [20]u8 = undefined;
    @memcpy(&from, topics[1][12..32]);
    @memcpy(&to, topics[2][12..32]);

    const value = std.mem.readInt(u256, data[0..32], .big);

    return .{
        .from = from,
        .to = to,
        .value = value,
    };
}

test "erc20 decode transfer log" {
    var topics: [3][32]u8 = @splat(@splat(0));
    topics[1][31] = 0xAA;
    topics[2][31] = 0xBB;

    var data: [32]u8 = @splat(0);
    data[31] = 100;

    const event = try decodeTransferLog(&topics, &data);
    try std.testing.expectEqual(@as(u8, 0xAA), event.from[19]);
    try std.testing.expectEqual(@as(u8, 0xBB), event.to[19]);
    try std.testing.expectEqual(@as(u256, 100), event.value);
}
