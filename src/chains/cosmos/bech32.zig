const std = @import("std");
const bech32_core = @import("../../core/encodings/bech32.zig");

pub const CosmosError = error{
    InvalidBech32,
    BufferTooSmall,
};

/// Splits a Bech32 cosmos address into its HRP and data parts.
pub fn splitHrp(address: []const u8) CosmosError!struct { hrp: []const u8, data_part: []const u8 } {
    if (address.len < 8) return CosmosError.InvalidBech32;
    const last_one = std.mem.lastIndexOfScalar(u8, address, '1') orelse return CosmosError.InvalidBech32;
    if (last_one == 0 or last_one + 7 > address.len) return CosmosError.InvalidBech32;

    return .{
        .hrp = address[0..last_one],
        .data_part = address[last_one + 1 ..],
    };
}

test "split cosmos hrp" {
    const parts = try splitHrp("cosmos1h4n0kgyu74h");
    try std.testing.expectEqualStrings("cosmos", parts.hrp);
    try std.testing.expectEqualStrings("h4n0kgyu74h", parts.data_part);
}
