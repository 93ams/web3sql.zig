//! Bounds-checked byte cursor shared by every binary decoder (Borsh, BCS, ...).
//! All length arithmetic is checked, so hostile lengths yield errors, never panics or OOB reads.
const std = @import("std");
const varint = @import("encodings/varint.zig");

pub const ReadError = error{
    UnexpectedEndOfBuffer,
    InvalidBool,
    VarintError,
};

pub const Reader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.cursor;
    }

    pub fn readSlice(self: *Reader, len: usize) ReadError![]const u8 {
        if (len > self.remaining()) return ReadError.UnexpectedEndOfBuffer;
        const s = self.bytes[self.cursor..][0..len];
        self.cursor += len;
        return s;
    }

    pub fn readByte(self: *Reader) ReadError!u8 {
        return (try self.readSlice(1))[0];
    }

    /// Little-endian fixed-width integer (Borsh, BCS).
    pub fn readIntLE(self: *Reader, comptime T: type) ReadError!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        return std.mem.readInt(T, (try self.readSlice(n))[0..n], .little);
    }

    pub fn readBool(self: *Reader) ReadError!bool {
        return switch (try self.readByte()) {
            0 => false,
            1 => true,
            else => ReadError.InvalidBool,
        };
    }

    /// ULEB128 length prefix, strictly canonical, converted to usize without truncation.
    pub fn readUlebLen(self: *Reader) ReadError!usize {
        const d = varint.decodeUleb128Strict(self.bytes[self.cursor..]) catch return ReadError.VarintError;
        const len = std.math.cast(usize, d.value) orelse return ReadError.VarintError;
        self.cursor += d.bytes_read;
        return len;
    }

    /// ULEB128-prefixed byte string.
    pub fn readLengthPrefixed(self: *Reader) ReadError![]const u8 {
        const start = self.cursor;
        errdefer self.cursor = start;
        return self.readSlice(try self.readUlebLen());
    }
};

test "reader rejects hostile lengths" {
    var r = Reader.init(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 'x' });
    try std.testing.expectError(ReadError.UnexpectedEndOfBuffer, r.readLengthPrefixed());
    try std.testing.expectEqual(@as(usize, 0), r.cursor);
    var r2 = Reader.init(&[_]u8{ 1, 2 });
    try std.testing.expectError(ReadError.UnexpectedEndOfBuffer, r2.readSlice(std.math.maxInt(usize)));
    try std.testing.expectError(ReadError.UnexpectedEndOfBuffer, r2.readIntLE(u32));
}

test "reader fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [64]u8 = undefined;
            const n = smith.slice(&buf);
            var r = Reader.init(buf[0..n]);
            while (r.remaining() > 0) {
                _ = r.readLengthPrefixed() catch break;
            }
        }
    }.f, .{});
}
