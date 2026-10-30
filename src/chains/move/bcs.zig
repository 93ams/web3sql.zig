const std = @import("std");
const reader = @import("../../core/reader.zig");

pub const BcsError = reader.ReadError || error{InvalidOptionTag};

pub const BcsReader = struct {
    r: reader.Reader,

    pub fn init(bytes: []const u8) BcsReader {
        return .{ .r = reader.Reader.init(bytes) };
    }

    pub fn remaining(self: *const BcsReader) usize {
        return self.r.remaining();
    }

    pub fn readByte(self: *BcsReader) BcsError!u8 {
        return self.r.readByte();
    }

    pub fn readBool(self: *BcsReader) BcsError!bool {
        return self.r.readBool();
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

    /// Option<T> is a vector of length 0 or 1 in BCS.
    pub fn readOptionTag(self: *BcsReader) BcsError!bool {
        return switch (try self.r.readUlebLen()) {
            0 => false,
            1 => true,
            else => BcsError.InvalidOptionTag,
        };
    }

    /// ULEB128 sequence length, bounded by remaining bytes for elements of at least `min_elem_size` bytes.
    pub fn readSeqLen(self: *BcsReader, min_elem_size: usize) BcsError!usize {
        const n = try self.r.readUlebLen();
        if (min_elem_size != 0 and n > self.remaining() / min_elem_size) return BcsError.UnexpectedEndOfBuffer;
        return n;
    }

    pub fn readLengthPrefixedSlice(self: *BcsReader) BcsError![]const u8 {
        return self.r.readLengthPrefixed();
    }
};

test "REQ-MOVE-02 bcs length prefixed slice" {
    const raw = [_]u8{ 5, 'h', 'e', 'l', 'l', 'o' };
    var r = BcsReader.init(&raw);
    try std.testing.expectEqualStrings("hello", try r.readLengthPrefixedSlice());
}

test "REQ-MOVE-02 bcs rejects non-canonical and hostile lengths" {
    var nc = BcsReader.init(&[_]u8{ 0x81, 0x00, 'x' });
    try std.testing.expectError(BcsError.VarintError, nc.readLengthPrefixedSlice());
    var big = BcsReader.init(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f, 'x' });
    try std.testing.expectError(BcsError.UnexpectedEndOfBuffer, big.readLengthPrefixedSlice());
    var opt = BcsReader.init(&[_]u8{ 0, 1, 2 });
    try std.testing.expect(!(try opt.readOptionTag()));
    try std.testing.expect(try opt.readOptionTag());
    try std.testing.expectError(BcsError.InvalidOptionTag, opt.readOptionTag());
}

test "REQ-MOVE-02 bcs integers" {
    var r = BcsReader.init(&[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u64, 1), try r.readU64());
    try std.testing.expectError(BcsError.UnexpectedEndOfBuffer, r.readU128());
}
