//! Bounded output cursor over a caller buffer; overflow is an error, never truncation.
const std = @import("std");

pub const Out = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn put(self: *Out, s: []const u8) error{BufferTooSmall}!void {
        if (s.len > self.buf.len - self.pos) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) error{BufferTooSmall}!void {
        const s = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return error.BufferTooSmall;
        self.pos += s.len;
    }

    pub fn written(self: *const Out) []const u8 {
        return self.buf[0..self.pos];
    }
};
