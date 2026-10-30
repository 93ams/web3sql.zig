const std = @import("std");
const hex = @import("../../core/encodings/hex.zig");

pub const MoveAddress = [32]u8;

pub const AddressError = error{
    InvalidHex,
    InvalidLength,
    BufferTooSmall,
};

/// Parses and normalizes a Move hex address (e.g., 0x1 or 0x000...1) to 32 canonical bytes.
pub fn parseCanonicalAddress(src: []const u8) AddressError!MoveAddress {
    var raw = src;
    if (raw.len >= 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
        raw = raw[2..];
    }
    if (raw.len == 0 or raw.len > 64) return AddressError.InvalidLength;

    var full_hex: [64]u8 = @splat('0');
    const start_pos = 64 - raw.len;
    @memcpy(full_hex[start_pos..], raw);

    var addr: MoveAddress = undefined;
    _ = hex.decodeHex(&full_hex, &addr) catch return AddressError.InvalidHex;
    return addr;
}

test "move canonical address" {
    const addr = try parseCanonicalAddress("0x1");
    try std.testing.expectEqual(@as(u8, 1), addr[31]);
    try std.testing.expectEqual(@as(u8, 0), addr[0]);
}
