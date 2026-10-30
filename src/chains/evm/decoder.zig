const std = @import("std");

pub const Word = [32]u8;

pub const DecoderError = error{
    OutOfBounds,
    InvalidOffset,
    InvalidLength,
};

/// Reads a 32-byte big-endian unsigned integer word at specified word index.
pub fn readWord(data: []const u8, word_index: usize) DecoderError!Word {
    const offset = word_index * 32;
    if (offset + 32 > data.len) return DecoderError.OutOfBounds;
    return data[offset..][0..32].*;
}

/// Reads a u256 value at specified word index.
pub fn readU256(data: []const u8, word_index: usize) DecoderError!u256 {
    const w = try readWord(data, word_index);
    return std.mem.readInt(u256, &w, .big);
}

test "abi decoder reads word and u256" {
    var sample: [64]u8 = @splat(0);
    sample[31] = 42; // word 0 = 42
    sample[63] = 99; // word 1 = 99

    const v0 = try readU256(&sample, 0);
    const v1 = try readU256(&sample, 1);
    try std.testing.expectEqual(@as(u256, 42), v0);
    try std.testing.expectEqual(@as(u256, 99), v1);
    try std.testing.expectError(DecoderError.OutOfBounds, readU256(&sample, 2));
}
