//! BCS cursor. `strict` (default) rejects non-canonical ULEB128 and, via `finish`, trailing bytes.
const std = @import("std");
const reader = @import("../../core/reader.zig");
const varint = @import("../../core/encodings/varint.zig");

pub const BcsError = reader.ReadError || error{
    InvalidOptionTag,
    InvalidUtf8,
    InvalidVariant,
    TrailingBytes,
    TooDeep,
    BufferTooSmall,
    InvalidSchema,
};

/// BCS caps sequence lengths at 2^31 - 1.
pub const max_seq_len = 0x7fff_ffff;

pub const BcsReader = struct {
    r: reader.Reader,
    strict: bool = true,

    pub fn init(bytes: []const u8) BcsReader {
        return .{ .r = reader.Reader.init(bytes) };
    }

    /// Accepts non-minimal ULEB128 and trailing bytes.
    pub fn initLenient(bytes: []const u8) BcsReader {
        return .{ .r = reader.Reader.init(bytes), .strict = false };
    }

    pub fn remaining(self: *const BcsReader) usize {
        return self.r.remaining();
    }

    /// Strict mode: error if input is left over.
    pub fn finish(self: *const BcsReader) BcsError!void {
        if (self.strict and self.remaining() != 0) return BcsError.TrailingBytes;
    }

    pub fn readByte(self: *BcsReader) BcsError!u8 {
        return self.r.readByte();
    }

    pub fn readBool(self: *BcsReader) BcsError!bool {
        return self.r.readBool();
    }

    pub fn readU16(self: *BcsReader) BcsError!u16 {
        return self.r.readIntLE(u16);
    }

    pub fn readU32(self: *BcsReader) BcsError!u32 {
        return self.r.readIntLE(u32);
    }

    pub fn readU64(self: *BcsReader) BcsError!u64 {
        return self.r.readIntLE(u64);
    }

    pub fn readU128(self: *BcsReader) BcsError!u128 {
        return self.r.readIntLE(u128);
    }

    pub fn readU256(self: *BcsReader) BcsError!u256 {
        return self.r.readIntLE(u256);
    }

    pub fn readAddress(self: *BcsReader) BcsError![32]u8 {
        return (try self.r.readSlice(32))[0..32].*;
    }

    /// ULEB128 of at most u32 range (sequence lengths, enum variant indices).
    pub fn readUleb32(self: *BcsReader) BcsError!u32 {
        const src = self.r.bytes[self.r.cursor..];
        const d = (if (self.strict) varint.decodeUlebStrict(u32, src) else varint.decodeUleb(u32, src)) catch return BcsError.VarintError;
        self.r.cursor += d.bytes_read;
        return d.value;
    }

    /// Option<T> is a vector of length 0 or 1 in BCS.
    pub fn readOptionTag(self: *BcsReader) BcsError!bool {
        return switch (try self.readUleb32()) {
            0 => false,
            1 => true,
            else => BcsError.InvalidOptionTag,
        };
    }

    /// Sequence length, bounded by remaining bytes for elements of at least `min_elem_size` bytes.
    pub fn readSeqLen(self: *BcsReader, min_elem_size: usize) BcsError!usize {
        const n: usize = try self.readUleb32();
        if (n > max_seq_len) return BcsError.VarintError;
        if (min_elem_size != 0 and n > self.remaining() / min_elem_size) return BcsError.UnexpectedEndOfBuffer;
        return n;
    }

    pub fn readLengthPrefixedSlice(self: *BcsReader) BcsError![]const u8 {
        const start = self.r.cursor;
        errdefer self.r.cursor = start;
        return self.r.readSlice(try self.readSeqLen(1));
    }

    pub fn readString(self: *BcsReader) BcsError![]const u8 {
        const start = self.r.cursor;
        errdefer self.r.cursor = start;
        const s = try self.readLengthPrefixedSlice();
        if (!std.unicode.utf8ValidateSlice(s)) return BcsError.InvalidUtf8;
        return s;
    }
};

// Vectors in this file: zefchain/bcs README.md and tests/serde.rs; Aptos/Sui SDK tests (fetched).
test "REQ-MOVE-02 bcs length prefixed slice" {
    const raw = [_]u8{ 5, 'h', 'e', 'l', 'l', 'o' };
    var r = BcsReader.init(&raw);
    try std.testing.expectEqualStrings("hello", try r.readLengthPrefixedSlice());
    try r.finish();
}

test "REQ-MOVE-02 bcs rejects non-canonical and hostile lengths" {
    var nc = BcsReader.init(&[_]u8{ 0x81, 0x00, 'x' });
    try std.testing.expectError(BcsError.VarintError, nc.readLengthPrefixedSlice());
    var big = BcsReader.init(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f, 'x' });
    try std.testing.expectError(BcsError.VarintError, big.readLengthPrefixedSlice());
    var huge = BcsReader.init(&[_]u8{ 0xff, 0xff, 0xff, 0x7f, 'x' });
    try std.testing.expectError(BcsError.UnexpectedEndOfBuffer, huge.readLengthPrefixedSlice());
    var opt = BcsReader.init(&[_]u8{ 0, 1, 2 });
    try std.testing.expect(!(try opt.readOptionTag()));
    try std.testing.expect(try opt.readOptionTag());
    try std.testing.expectError(BcsError.InvalidOptionTag, opt.readOptionTag());
}

// zefchain/bcs tests/serde.rs test_uleb128: five-byte overflow, truncating 0x1f, and non-canonical 80 80 80 00.
test "REQ-MOVE-02 bcs uleb128 edge cases" {
    const cases = [_]struct { b: []const u8, v: ?u32, strict_err: bool = false }{
        .{ .b = &.{0x01}, .v = 1 },
        .{ .b = &.{ 0x80, 0x01 }, .v = 128 },
        .{ .b = &.{ 0x80, 0x80, 0x01 }, .v = 16384 },
        .{ .b = &.{ 0x80, 0x80, 0x80, 0x01 }, .v = 2097152 },
        .{ .b = &.{ 0x80, 0x80, 0x80, 0x80, 0x01 }, .v = 268435456 },
        .{ .b = &.{ 0x8f, 0x4a }, .v = 9487 },
        .{ .b = &.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, .v = 4294967295 },
        .{ .b = &.{ 0x80, 0x80, 0x80, 0x80, 0x80 }, .v = null },
        .{ .b = &.{ 0x80, 0x80, 0x80, 0x80, 0x1f }, .v = null },
        .{ .b = &.{ 0x80, 0x80, 0x80, 0x80 }, .v = null },
        .{ .b = &.{ 0x80, 0x80, 0x80, 0x00 }, .v = 0, .strict_err = true },
    };
    for (cases) |c| {
        var r = BcsReader.init(c.b);
        if (c.v == null or c.strict_err) {
            try std.testing.expectError(BcsError.VarintError, r.readUleb32());
        } else try std.testing.expectEqual(c.v.?, try r.readUleb32());
        if (c.strict_err) {
            var l = BcsReader.initLenient(c.b);
            try std.testing.expectEqual(c.v.?, try l.readUleb32());
        }
    }
}

test "REQ-MOVE-02 bcs integers" {
    var r = BcsReader.init(&[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u64, 1), try r.readU64());
    try std.testing.expectError(BcsError.UnexpectedEndOfBuffer, r.readU128());
    // zefchain/bcs README integer table.
    var t = BcsReader.init(&[_]u8{ 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0x00, 0xEF, 0xCD, 0xAB, 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u16, 4660), try t.readU16());
    try std.testing.expectEqual(@as(u32, 305419896), try t.readU32());
    try std.testing.expectEqual(@as(u64, 1311768467750121216), try t.readU64());
    try t.finish();
    var tr = BcsReader.init(&[_]u8{ 1, 2 });
    _ = try tr.readByte();
    try std.testing.expectError(BcsError.TrailingBytes, tr.finish());
    try BcsReader.initLenient(&[_]u8{ 1, 2 }).finish();
}

test "REQ-MOVE-02 bcs strings" {
    // zefchain/bcs README and aptos-ts-sdk serializer.test.ts: "çå∞≠¢õß∂ƒ∫" is 24 bytes.
    const s = [_]u8{ 24, 0xc3, 0xa7, 0xc3, 0xa5, 0xe2, 0x88, 0x9e, 0xe2, 0x89, 0xa0, 0xc2, 0xa2, 0xc3, 0xb5, 0xc3, 0x9f, 0xe2, 0x88, 0x82, 0xc6, 0x92, 0xe2, 0x88, 0xab };
    var r = BcsReader.init(&s);
    try std.testing.expectEqualStrings("çå∞≠¢õß∂ƒ∫", try r.readString());
    // serde.rs: invalid utf8 [1, 0xFF]; invalid bool [9]; invalid option [5, 0].
    var bad = BcsReader.init(&[_]u8{ 1, 0xFF });
    try std.testing.expectError(BcsError.InvalidUtf8, bad.readString());
    var b = BcsReader.init(&[_]u8{9});
    try std.testing.expectError(BcsError.InvalidBool, b.readBool());
    var o = BcsReader.init(&[_]u8{ 5, 0 });
    try std.testing.expectError(BcsError.InvalidOptionTag, o.readOptionTag());
}
