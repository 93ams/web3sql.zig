const std = @import("std");
const reader = @import("../../core/reader.zig");

pub const BorshError = reader.ReadError || error{InvalidOptionTag};

pub const BorshReader = struct {
    r: reader.Reader,

    pub fn init(bytes: []const u8) BorshReader {
        return .{ .r = reader.Reader.init(bytes) };
    }

    pub fn remaining(self: *const BorshReader) usize {
        return self.r.remaining();
    }

    pub fn readByte(self: *BorshReader) BorshError!u8 {
        return self.r.readByte();
    }

    pub fn readBool(self: *BorshReader) BorshError!bool {
        return self.r.readBool();
    }

    pub fn readU32(self: *BorshReader) BorshError!u32 {
        return self.r.readIntLE(u32);
    }

    pub fn readU64(self: *BorshReader) BorshError!u64 {
        return self.r.readIntLE(u64);
    }

    pub fn readSlice(self: *BorshReader, len: usize) BorshError![]const u8 {
        return self.r.readSlice(len);
    }

    /// Option<T> tag: 0 = None, 1 = Some.
    pub fn readOptionTag(self: *BorshReader) BorshError!bool {
        return switch (try self.r.readByte()) {
            0 => false,
            1 => true,
            else => BorshError.InvalidOptionTag,
        };
    }

    /// Vec<T>/String length prefix (u32 LE). Rejects lengths that cannot fit in the remaining bytes
    /// given a minimum element size, so a hostile length cannot drive a long loop.
    pub fn readVecLen(self: *BorshReader, min_elem_size: usize) BorshError!usize {
        const n: usize = try self.readU32();
        if (min_elem_size != 0 and n > self.remaining() / min_elem_size) return BorshError.UnexpectedEndOfBuffer;
        return n;
    }

    /// Borsh string / Vec<u8>: u32 LE length + bytes.
    pub fn readBytes(self: *BorshReader) BorshError![]const u8 {
        return self.readSlice(try self.readVecLen(1));
    }
};

test "REQ-SVM-02 borsh reader primitive deserialization" {
    const raw = [_]u8{ 1, 0x2a, 0, 0, 0, 0xef, 0xbe, 0xad, 0xde, 0, 0, 0, 0 };
    var r = BorshReader.init(&raw);
    try std.testing.expectEqual(true, try r.readBool());
    try std.testing.expectEqual(@as(u32, 42), try r.readU32());
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), try r.readU64());
}

test "REQ-SVM-02 borsh bytes, option, hostile length" {
    var r = BorshReader.init(&[_]u8{ 2, 0, 0, 0, 'h', 'i', 1, 0 });
    try std.testing.expectEqualStrings("hi", try r.readBytes());
    try std.testing.expect(try r.readOptionTag());
    try std.testing.expect(!(try r.readOptionTag()));
    var bad = BorshReader.init(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 1 });
    try std.testing.expectError(BorshError.UnexpectedEndOfBuffer, bad.readBytes());
    var bad_opt = BorshReader.init(&[_]u8{2});
    try std.testing.expectError(BorshError.InvalidOptionTag, bad_opt.readOptionTag());
}
