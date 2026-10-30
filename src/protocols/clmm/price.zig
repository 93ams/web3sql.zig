const std = @import("std");
const math = @import("../../core/math/root.zig");

pub const ClmmError = math.MathError || error{ TickOutOfRange, SqrtPriceOutOfRange };

/// Writes `(int + frac / 2^frac_bits) * 10^(decimals0 - decimals1)` as a decimal with exactly `scale`
/// fractional digits, truncating toward zero. The exact binary fraction is expanded digit by digit
/// and the decimal point moved, so no precision is lost and nothing can overflow.
/// `frac_bits` must be at most 252, so that the digit step fits in u256.
pub fn renderPrice(int: u128, frac: u256, frac_bits: u8, decimals0: u8, decimals1: u8, scale: u8, dest: []u8) ClmmError![]const u8 {
    var buf: [math.MAX_DECIMAL_LEN]u8 = undefined;
    const digits = try math.formatDecimal(int, &buf);
    const int_len: i32 = @intCast(digits.len);
    const shift = @as(i32, decimals0) - decimals1;
    const mask = (@as(u256, 1) << frac_bits) - 1;

    var rem = frac;
    var n: usize = 0;
    var weight: i32 = @max(int_len + shift - 1, 0);
    while (weight >= -@as(i32, scale)) : (weight -= 1) {
        const raw = weight - shift; // weight of this digit before the decimals adjustment
        var digit: u8 = '0';
        if (raw < 0) {
            rem *= 10;
            digit += @intCast(rem >> frac_bits);
            rem &= mask;
        } else if (raw < int_len) {
            digit = digits[@intCast(int_len - 1 - raw)];
        }
        if (n == 0 and digit == '0' and weight > 0) continue;
        if (n + 2 > dest.len) return ClmmError.BufferTooSmall;
        if (weight == -1) {
            dest[n] = '.';
            n += 1;
        }
        dest[n] = digit;
        n += 1;
    }
    return dest[0..n];
}

test "REQ-PROT-01 renderPrice moves the point both ways and truncates" {
    var buf: [64]u8 = undefined;
    const half = @as(u256, 1) << 127; // 0.5 with 128 fractional bits
    try std.testing.expectEqualStrings("1.50", try renderPrice(1, half, 128, 0, 0, 2, &buf));
    try std.testing.expectEqualStrings("1", try renderPrice(1, half, 128, 0, 0, 0, &buf));
    try std.testing.expectEqualStrings("15.0", try renderPrice(1, half, 128, 1, 0, 1, &buf));
    try std.testing.expectEqualStrings("1500", try renderPrice(1, half, 128, 3, 0, 0, &buf));
    try std.testing.expectEqualStrings("0.0150", try renderPrice(1, half, 128, 0, 2, 4, &buf));
    try std.testing.expectEqualStrings("0.00", try renderPrice(1, 0, 128, 0, 3, 2, &buf));
    try std.testing.expectEqualStrings("0.00", try renderPrice(0, 0, 128, 5, 0, 2, &buf));
    try std.testing.expectError(ClmmError.BufferTooSmall, renderPrice(1, half, 128, 0, 0, 2, buf[0..3]));
}
