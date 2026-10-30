const std = @import("std");
const hex = @import("../../core/encodings/hex.zig");
const Out = @import("out.zig").Out;

pub const MoveAddress = [32]u8;

pub const AddressError = error{
    InvalidHex,
    InvalidLength,
    BufferTooSmall,
    NotCanonical,
};

/// Display rules. `aptos` is AIP-40 (special addresses 0x0..0xf short, everything else 64 digits),
/// `sui` is always 64 digits, `short` drops all leading zeros (the form most type strings use).
pub const Style = enum { aptos, sui, short };

/// Parses and normalizes a Move hex address (e.g., 0x1 or 0x000...1) to 32 canonical bytes.
pub fn parseCanonicalAddress(src: []const u8) AddressError!MoveAddress {
    var raw = src;
    if (raw.len >= 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
        raw = raw[2..];
    }
    if (raw.len == 0 or raw.len > 64) return AddressError.InvalidLength;

    // decodeHex would itself strip a second "0x", leaving part of `addr` undefined.
    for (raw) |c| if (!std.ascii.isHex(c)) return AddressError.InvalidHex;

    var full_hex: [64]u8 = @splat('0');
    const start_pos = 64 - raw.len;
    @memcpy(full_hex[start_pos..], raw);

    var addr: MoveAddress = undefined;
    _ = hex.decodeHex(&full_hex, &addr) catch return AddressError.InvalidHex;
    return addr;
}

/// Aptos "special" addresses: 0x0 through 0xf.
pub fn isSpecial(addr: MoveAddress) bool {
    return addr[31] < 16 and std.mem.allEqual(u8, addr[0..31], 0);
}

/// Strict parse: mandatory `0x`, then exactly 64 digits; for `.aptos` a single digit is also
/// accepted but only for special addresses (AIP-40). Padded short forms like `0x0f` are rejected.
pub fn parseStrict(src: []const u8, style: Style) AddressError!MoveAddress {
    if (src.len < 3 or src[0] != '0' or src[1] != 'x') return AddressError.NotCanonical;
    const digits = src.len - 2;
    if (digits == 64) return parseCanonicalAddress(src);
    if (style == .aptos and digits == 1) return parseCanonicalAddress(src);
    return AddressError.NotCanonical;
}

/// Writes the `0x`-prefixed lowercase form into `dest`.
pub fn format(addr: MoveAddress, style: Style, dest: []u8) AddressError![]const u8 {
    var out = Out{ .buf = dest };
    try write(&out, addr, style);
    return out.written();
}

pub fn write(out: *Out, addr: MoveAddress, style: Style) error{BufferTooSmall}!void {
    var h: [64]u8 = undefined;
    _ = hex.encodeHex(&addr, &h) catch return error.BufferTooSmall;
    const short = style == .short or (style == .aptos and isSpecial(addr));
    var lead: usize = 0;
    if (short) {
        while (lead < 63 and h[lead] == '0') lead += 1;
    }
    try out.put("0x");
    try out.put(h[lead..]);
}

test "REQ-MOVE-01 move canonical address" {
    const addr = try parseCanonicalAddress("0x1");
    try std.testing.expectEqual(@as(u8, 1), addr[31]);
    try std.testing.expectEqual(@as(u8, 0), addr[0]);
}

// Vectors: aptos-labs/aptos-ts-sdk packages/ts-sdk/tests/unit/accountAddress.test.ts (fetched).
test "REQ-MOVE-01 aptos display rules" {
    var buf: [66]u8 = undefined;
    const long1 = "0x0000000000000000000000000000000000000000000000000000000000000001";
    const other = "0xca843279e3427144cead5e4d5999a3d0ca843279e3427144cead5e4d5999a3d0";
    const ten = "0x0000000000000000000000000000000000000000000000000000000000000010";
    for ([_][]const u8{ "0x1", "1", long1, "0x01", long1[2..] }) |s| {
        const a = try parseCanonicalAddress(s);
        try std.testing.expectEqualStrings("0x1", try format(a, .aptos, &buf));
    }
    try std.testing.expectEqualStrings("0x0", try format(try parseCanonicalAddress("0x0"), .aptos, &buf));
    try std.testing.expectEqualStrings("0xf", try format(try parseCanonicalAddress("0x0f"), .aptos, &buf));
    try std.testing.expectEqualStrings(ten, try format(try parseCanonicalAddress("0x10"), .aptos, &buf));
    try std.testing.expectEqualStrings(other, try format(try parseCanonicalAddress(other), .aptos, &buf));
    try std.testing.expectEqualStrings(long1, try format(try parseCanonicalAddress("0x1"), .sui, &buf));
    try std.testing.expectEqualStrings("0x10", try format(try parseCanonicalAddress(ten), .short, &buf));
    try std.testing.expectEqualStrings("0x0", try format(try parseCanonicalAddress("0x0"), .short, &buf));
    try std.testing.expectError(AddressError.BufferTooSmall, format(try parseCanonicalAddress("0x1"), .sui, buf[0..65]));
}

test "REQ-MOVE-01 strict address validation" {
    const long1 = "0x0000000000000000000000000000000000000000000000000000000000000001";
    _ = try parseStrict("0x1", .aptos);
    _ = try parseStrict(long1, .aptos);
    _ = try parseStrict(long1, .sui);
    try std.testing.expectError(AddressError.NotCanonical, parseStrict("0x0f", .aptos));
    try std.testing.expectError(AddressError.NotCanonical, parseStrict("0x10", .aptos));
    try std.testing.expectError(AddressError.NotCanonical, parseStrict("0x1", .sui));
    try std.testing.expectError(AddressError.NotCanonical, parseStrict("1", .aptos));
    try std.testing.expectError(AddressError.InvalidHex, parseStrict("0xg000000000000000000000000000000000000000000000000000000000000001", .sui));
    try std.testing.expectError(AddressError.InvalidHex, parseCanonicalAddress("0x0x" ++ long1[4..]));
    try std.testing.expectError(AddressError.InvalidLength, parseCanonicalAddress("0x"));
    try std.testing.expectError(AddressError.InvalidLength, parseCanonicalAddress("0x00" ++ long1[2..]));
}
