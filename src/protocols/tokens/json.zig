const std = @import("std");
const math = @import("../../core/math/root.zig");
const hex = @import("../../core/encodings/hex.zig");

pub const JsonError = error{BufferTooSmall};

const MAX_SAFE_INTEGER: u256 = @as(u256, 1) << 53;

/// Compact JSON writer over a caller buffer. Fails rather than truncates.
pub const Out = struct {
    dest: []u8,
    len: usize = 0,

    pub fn raw(self: *Out, text: []const u8) JsonError!void {
        if (text.len > self.dest.len - self.len) return JsonError.BufferTooSmall;
        @memcpy(self.dest[self.len..][0..text.len], text);
        self.len += text.len;
    }

    /// Writes bytes as a quoted 0x hex string.
    pub fn bytes(self: *Out, value: []const u8) JsonError!void {
        try self.raw("\"0x");
        const encoded = hex.encodeHex(value, self.dest[self.len..]) catch return JsonError.BufferTooSmall;
        self.len += encoded.len;
        try self.raw("\"");
    }

    /// Writes a number up to 2^53, a quoted decimal string beyond it.
    pub fn int(self: *Out, value: u256) JsonError!void {
        var buf: [math.MAX_DECIMAL_LEN]u8 = undefined;
        const text = math.formatDecimal(value, &buf) catch return JsonError.BufferTooSmall;
        if (value <= MAX_SAFE_INTEGER) return self.raw(text);
        try self.raw("\"");
        try self.raw(text);
        try self.raw("\"");
    }

    pub fn written(self: *const Out) []const u8 {
        return self.dest[0..self.len];
    }
};

test "REQ-PROT-02 json writer switches to strings above 2^53" {
    var buf: [64]u8 = undefined;
    var out: Out = .{ .dest = &buf };
    try out.int(9007199254740992);
    try out.raw(",");
    try out.int(9007199254740993);
    try out.raw(",");
    try out.bytes(&.{ 0xab, 0x01 });
    try std.testing.expectEqualStrings("9007199254740992,\"9007199254740993\",\"0xab01\"", out.written());

    var small: Out = .{ .dest = buf[0..3] };
    try std.testing.expectError(JsonError.BufferTooSmall, small.bytes(&.{0xab}));
}
