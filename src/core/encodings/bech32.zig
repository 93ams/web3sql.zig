const std = @import("std");

pub const Bech32Error = error{
    InvalidCharacter,
    InvalidChecksum,
    InvalidLength,
    BufferTooSmall,
};

pub const CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

/// Bech32 encoding variant
pub const Variant = enum {
    bech32,
    bech32m,
};

/// Polymod checksum computation for Bech32/Bech32m.
pub fn polymod(values: []const u5) u32 {
    const generator = [_]u32{
        0x3b6a57b2,
        0x26508e6d,
        0x1ea119fa,
        0x3d4233dd,
        0x2a1462b3,
    };
    var chk: u32 = 1;
    for (values) |v| {
        const top: u5 = @intCast(chk >> 25);
        chk = ((chk & 0x1ffffff) << 5) ^ v;
        for (0..5) |i| {
            if ((top >> @intCast(i)) & 1 != 0) {
                chk ^= generator[i];
            }
        }
    }
    return chk;
}

test "bech32 polymod sanity" {
    const vals = [_]u5{ 0, 1, 2 };
    const p = polymod(&vals);
    try std.testing.expect(p != 0);
}
