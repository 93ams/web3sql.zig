const std = @import("std");
const sha256 = @import("../../core/crypto/sha256.zig");
const hex = @import("../../core/encodings/hex.zig");

const fuzz = @import("../../core/fuzz.zig");

pub const IbcError = error{
    BufferTooSmall,
    /// Empty trace, empty segment, or empty base denom.
    InvalidTrace,
};

pub const Trace = struct {
    /// `port/channel/port/channel` hops, no trailing slash; empty for a native denom.
    path: []const u8,
    base_denom: []const u8,

    /// Number of (port, channel) hops.
    pub fn hops(self: Trace) usize {
        if (self.path.len == 0) return 0;
        return std.mem.count(u8, self.path, "/") / 2 + 1;
    }
};

fn isChannelId(s: []const u8) bool {
    const prefix = "channel-";
    if (!std.mem.startsWith(u8, s, prefix)) return false;
    _ = std.fmt.parseUnsigned(u64, s[prefix.len..], 10) catch return false;
    return s.len > prefix.len and s[prefix.len] != '+';
}

/// Splits a denom trace such as `transfer/channel-141/uatom` into hops and base denom, as ibc-go's
/// `ParseDenomTrace` does: leading `(port, channel-N)` pairs are the path, the rest is the base
/// denom (which may itself contain slashes, e.g. `factory/...`). A two-segment string is a base denom.
pub fn parseTrace(trace: []const u8) IbcError!Trace {
    if (trace.len == 0 or trace[0] == '/' or trace[trace.len - 1] == '/' or std.mem.indexOf(u8, trace, "//") != null)
        return IbcError.InvalidTrace;
    var it = std.mem.splitScalar(u8, trace, '/');
    var consumed: usize = 0; // bytes of path including the trailing slash
    var total = std.mem.count(u8, trace, "/") + 1;
    while (total > 2) {
        const port = it.next().?;
        const chan = it.next() orelse break;
        if (!isChannelId(chan)) break;
        consumed += port.len + 1 + chan.len + 1;
        total -= 2;
    }
    return .{ .path = trace[0..if (consumed == 0) 0 else consumed - 1], .base_denom = trace[consumed..] };
}

/// Computes the IBC denom trace hash ("ibc/" + hex_upper(sha256(trace))).
pub fn deriveIbcDenom(trace: []const u8, dest: []u8) IbcError![]const u8 {
    // "ibc/" is 4 bytes + 64 hex chars = 68 bytes
    if (dest.len < 68) return IbcError.BufferTooSmall;

    @memcpy(dest[0..4], "ibc/");

    var hash_buf: [32]u8 = undefined;
    sha256.hash(trace, &hash_buf);

    var hex_buf: [64]u8 = undefined;
    _ = hex.encodeHex(&hash_buf, &hex_buf) catch unreachable;

    for (0..64) |i| {
        dest[4 + i] = std.ascii.toUpper(hex_buf[i]);
    }

    return dest[0..68];
}

test "derive ibc denom" {
    var out: [68]u8 = undefined;
    const denom = try deriveIbcDenom("transfer/channel-141/uatom", &out);
    try std.testing.expectEqualStrings("ibc/", denom[0..4]);
    try std.testing.expectEqual(68, denom.len);
}

test "REQ-COSMOS-01 ibc denom hash matches Osmosis chain-registry" {
    // chain-registry osmosis/assetlist.json: ATOM base `ibc/27394FB0...` has chain path `transfer/channel-0/uatom`
    var out: [68]u8 = undefined;
    try std.testing.expectEqualStrings("ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2", try deriveIbcDenom("transfer/channel-0/uatom", &out));
    try std.testing.expectError(IbcError.BufferTooSmall, deriveIbcDenom("transfer/channel-0/uatom", out[0..67]));
}

test "REQ-COSMOS-01 parse denom trace" {
    var t = try parseTrace("transfer/channel-0/uatom");
    try std.testing.expectEqualStrings("transfer/channel-0", t.path);
    try std.testing.expectEqualStrings("uatom", t.base_denom);
    try std.testing.expectEqual(@as(usize, 1), t.hops());
    t = try parseTrace("transfer/channel-0/transfer/channel-141/uatom");
    try std.testing.expectEqualStrings("transfer/channel-0/transfer/channel-141", t.path);
    try std.testing.expectEqual(@as(usize, 2), t.hops());
    t = try parseTrace("uatom");
    try std.testing.expectEqual(@as(usize, 0), t.hops());
    try std.testing.expectEqualStrings("uatom", t.base_denom);
    // base denom containing slashes, and a non-channel second segment
    t = try parseTrace("transfer/channel-7/factory/osmo1abc/utoken");
    try std.testing.expectEqualStrings("factory/osmo1abc/utoken", t.base_denom);
    t = try parseTrace("factory/osmo1abc/utoken");
    try std.testing.expectEqual(@as(usize, 0), t.hops());
    try std.testing.expectEqualStrings("factory/osmo1abc/utoken", t.base_denom);
    // ibc-go: two segments are never a path
    t = try parseTrace("transfer/channel-0");
    try std.testing.expectEqual(@as(usize, 0), t.hops());
    try std.testing.expectEqualStrings("transfer/channel-0", t.base_denom);
    for ([_][]const u8{ "", "/", "a//b", "/a/b", "a/b/", "transfer/channel-0/" }) |bad|
        try std.testing.expectError(IbcError.InvalidTrace, parseTrace(bad));
    t = try parseTrace("transfer/channel-x/uatom");
    try std.testing.expectEqual(@as(usize, 0), t.hops());
}

fn walk(_: void, bytes: []const u8) void {
    var out: [68]u8 = undefined;
    _ = deriveIbcDenom(bytes, &out) catch {};
    const t = parseTrace(bytes) catch return;
    std.debug.assert(t.path.len + t.base_denom.len <= bytes.len);
    _ = t.hops();
}

test "REQ-COSMOS-01 ibc trace fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [96]u8 = undefined;
            walk({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-COSMOS-01 ibc trace mutation stress" {
    fuzz.stress(200_000, &.{ "transfer/channel-0/uatom", "transfer/channel-0/transfer/channel-141/factory/x/y" }, {}, walk);
}
