const std = @import("std");

const Edwards25519 = std.crypto.ecc.Edwards25519;

/// True when the 32 bytes decompress to a point on Curve25519. Matches `CompressedEdwardsY::decompress`
/// used by Solana: non-canonical `y` and low-order points count as on curve.
pub fn isOnCurve(bytes: *const [32]u8) bool {
    _ = Edwards25519.fromBytes(bytes.*) catch return false;
    return true;
}

test "REQ-CORE-03 isOnCurve" {
    // Ground truth computed independently from y^2 relation: x^2 = (y^2-1)/(dy^2+1) is a square.
    const expected = [_]bool{ true, true, false, true, true, true, true, false };
    for (expected, 0..) |on, y| {
        var bytes: [32]u8 = @splat(0);
        bytes[0] = @intCast(y);
        try std.testing.expectEqual(on, isOnCurve(&bytes));
    }
    const base = Edwards25519.basePoint.toBytes();
    try std.testing.expect(isOnCurve(&base));
}
