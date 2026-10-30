const std = @import("std");

pub const U512 = u512;

/// Formats a u512 value into a decimal string buffer.
pub fn formatDecimal(value: u512, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value});
}

test "u512 operations" {
    const val: u512 = (1 << 300) + 12345;
    try std.testing.expect(val > 0);
    var buf: [128]u8 = undefined;
    const str = try formatDecimal(123456789, &buf);
    try std.testing.expectEqualStrings("123456789", str);
}
