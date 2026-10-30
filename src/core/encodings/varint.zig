const std = @import("std");

pub const VarintError = error{
    BufferTooSmall,
    Overflow,
    UnexpectedEndOfBuffer,
    NonCanonical,
};

/// Encodes a 64-bit unsigned integer as ULEB128.
pub fn encodeUleb128(val: u64, dest: []u8) VarintError!usize {
    var v = val;
    var idx: usize = 0;
    while (true) {
        if (idx >= dest.len) return VarintError.BufferTooSmall;
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) {
            byte |= 0x80;
        }
        dest[idx] = byte;
        idx += 1;
        if (v == 0) break;
    }
    return idx;
}

pub const Decoded = struct { value: u64, bytes_read: usize };

/// Decodes a ULEB128 varint from src, returning decoded value and bytes consumed.
/// Accepts non-minimal encodings (e.g. 0x80 0x00); use `decodeUleb128Strict` where canonical form is required.
pub fn decodeUleb128(src: []const u8) VarintError!Decoded {
    var result: u64 = 0;
    for (src, 0..) |byte, idx| {
        const shift = idx * 7;
        const val: u64 = byte & 0x7F;
        if (val != 0) {
            if (shift >= 64) return VarintError.Overflow;
            // bits that would be shifted out of 64
            if (shift > 57 and (val >> @intCast(64 - shift)) != 0) return VarintError.Overflow;
            result |= val << @intCast(shift);
        }
        if ((byte & 0x80) == 0) return .{ .value = result, .bytes_read = idx + 1 };
        if (idx >= 9) return VarintError.Overflow; // a u64 never needs an 11th byte
    }
    return VarintError.UnexpectedEndOfBuffer;
}

/// Like `decodeUleb128` but rejects non-minimal encodings (trailing zero group), as BCS requires.
pub fn decodeUleb128Strict(src: []const u8) VarintError!Decoded {
    const d = try decodeUleb128(src);
    if (d.bytes_read > 1 and src[d.bytes_read - 1] == 0) return VarintError.NonCanonical;
    return d;
}

test "uleb128 roundtrip" {
    var buf: [10]u8 = undefined;
    const test_vals = [_]u64{ 0, 1, 127, 128, 624485, std.math.maxInt(u64) };
    for (test_vals) |val| {
        const len = try encodeUleb128(val, &buf);
        const dec = try decodeUleb128(buf[0..len]);
        try std.testing.expectEqual(val, dec.value);
        try std.testing.expectEqual(len, dec.bytes_read);
    }
}

test "uleb128 malformed input never panics" {
    // 11 continuation bytes: previously overflowed the shift counter
    const long: [11]u8 = @splat(0x80);
    try std.testing.expectError(VarintError.Overflow, decodeUleb128(&long));
    // value > u64::MAX
    const too_big = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f };
    try std.testing.expectError(VarintError.Overflow, decodeUleb128(&too_big));
    try std.testing.expectError(VarintError.UnexpectedEndOfBuffer, decodeUleb128(&[_]u8{0x80}));
    try std.testing.expectError(VarintError.NonCanonical, decodeUleb128Strict(&[_]u8{ 0x80, 0x00 }));
    const max = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try decodeUleb128Strict(&max)).value);
}

test "uleb128 fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [16]u8 = undefined;
            const n = smith.slice(&buf);
            _ = decodeUleb128(buf[0..n]) catch {};
            _ = decodeUleb128Strict(buf[0..n]) catch {};
        }
    }.f, .{});
}
