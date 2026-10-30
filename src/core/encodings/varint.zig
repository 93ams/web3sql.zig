const std = @import("std");

pub const VarintError = error{
    BufferTooSmall,
    Overflow,
    UnexpectedEndOfBuffer,
    NonCanonical,
};

/// Encodes an unsigned integer of any width as ULEB128.
pub fn encodeUleb(comptime T: type, val: T, dest: []u8) VarintError!usize {
    var v = val;
    var idx: usize = 0;
    while (true) {
        if (idx >= dest.len) return VarintError.BufferTooSmall;
        const low: u7 = @truncate(v);
        v = if (@bitSizeOf(T) > 7) v >> 7 else 0;
        dest[idx] = @as(u8, low) | (if (v != 0) @as(u8, 0x80) else 0);
        idx += 1;
        if (v == 0) return idx;
    }
}

/// Encodes a 64-bit unsigned integer as ULEB128.
pub fn encodeUleb128(val: u64, dest: []u8) VarintError!usize {
    return encodeUleb(u64, val, dest);
}

pub fn DecodedOf(comptime T: type) type {
    return struct { value: T, bytes_read: usize };
}

pub const Decoded = DecodedOf(u64);

/// Decodes a ULEB128 varint into `T`. Non-minimal encodings are accepted up to the width of `T`;
/// use `decodeUlebStrict` where canonical form is required.
pub fn decodeUleb(comptime T: type, src: []const u8) VarintError!DecodedOf(T) {
    const bits = @typeInfo(T).int.bits;
    const max_bytes = (bits + 6) / 7;
    var result: T = 0;
    for (src, 0..) |byte, idx| {
        if (idx >= max_bytes) return VarintError.Overflow;
        const shift = idx * 7;
        const val: T = byte & 0x7F;
        if (shift + 7 > bits and (val >> @intCast(bits - shift)) != 0) return VarintError.Overflow;
        result |= val << @intCast(shift);
        if ((byte & 0x80) == 0) return .{ .value = result, .bytes_read = idx + 1 };
    }
    return VarintError.UnexpectedEndOfBuffer;
}

/// Like `decodeUleb` but rejects non-minimal encodings (trailing zero group), as BCS requires.
pub fn decodeUlebStrict(comptime T: type, src: []const u8) VarintError!DecodedOf(T) {
    const d = try decodeUleb(T, src);
    if (d.bytes_read > 1 and src[d.bytes_read - 1] == 0) return VarintError.NonCanonical;
    return d;
}

/// Decodes a ULEB128 varint from src, returning decoded value and bytes consumed.
/// Accepts non-minimal encodings (e.g. 0x80 0x00); use `decodeUleb128Strict` where canonical form is required.
pub fn decodeUleb128(src: []const u8) VarintError!Decoded {
    return decodeUleb(u64, src);
}

/// Strict u64 ULEB128, the BCS length prefix.
pub fn decodeUleb128Strict(src: []const u8) VarintError!Decoded {
    return decodeUlebStrict(u64, src);
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

test "REQ-CORE-02 uleb128 wide widths and boundaries" {
    var buf: [40]u8 = undefined;
    const max128: u128 = std.math.maxInt(u128);
    const max256: u256 = std.math.maxInt(u256);
    const n128 = try encodeUleb(u128, max128, &buf);
    try std.testing.expectEqual(@as(usize, 19), n128);
    try std.testing.expectEqual(max128, (try decodeUlebStrict(u128, buf[0..n128])).value);
    try std.testing.expectError(VarintError.Overflow, decodeUleb(u64, buf[0..n128]));
    const n256 = try encodeUleb(u256, max256, &buf);
    try std.testing.expectEqual(@as(usize, 37), n256);
    try std.testing.expectEqual(max256, (try decodeUlebStrict(u256, buf[0..n256])).value);
    // top byte of an 18-group u128 holds at most 2 bits
    var over: [19]u8 = @splat(0xFF);
    over[18] = 0x04;
    try std.testing.expectError(VarintError.Overflow, decodeUleb(u128, &over));
    over[18] = 0x03;
    try std.testing.expectEqual(max128, (try decodeUleb(u128, &over)).value);
    // spec example: 624485 = E5 8E 26
    const n = try encodeUleb(u32, 624485, &buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xE5, 0x8E, 0x26 }, buf[0..n]);
    try std.testing.expectError(VarintError.BufferTooSmall, encodeUleb(u32, 624485, buf[0..2]));
    try std.testing.expectError(VarintError.NonCanonical, decodeUlebStrict(u128, &[_]u8{ 0x80, 0x80, 0x00 }));
}

test "uleb128 fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [16]u8 = undefined;
            const n = smith.slice(&buf);
            _ = decodeUleb128(buf[0..n]) catch {};
            _ = decodeUleb128Strict(buf[0..n]) catch {};
            _ = decodeUlebStrict(u128, buf[0..n]) catch {};
            _ = decodeUlebStrict(u256, buf[0..n]) catch {};
        }
    }.f, .{});
}
