const std = @import("std");

pub const OpReturnError = error{
    NotOpReturn,
    TruncatedScript,
    NonPushOpcode,
};

const OP_RETURN = 0x6a;
const OP_PUSHDATA1 = 0x4c;
const OP_PUSHDATA2 = 0x4d;
const OP_PUSHDATA4 = 0x4e;

/// Reads one data push at the start of `s`; returns the pushed bytes and the rest of the script.
/// Small-number opcodes (OP_0, OP_1..OP_16) are pushes of 0/1 byte-values, not data, so they are
/// rejected as `NonPushOpcode`.
pub fn readPush(s: []const u8) OpReturnError!struct { data: []const u8, rest: []const u8 } {
    if (s.len == 0) return OpReturnError.TruncatedScript;
    const op = s[0];
    var len: usize = undefined;
    var hdr: usize = 1;
    switch (op) {
        1...75 => len = op,
        OP_PUSHDATA1, OP_PUSHDATA2, OP_PUSHDATA4 => {
            const n: usize = switch (op) {
                OP_PUSHDATA1 => 1,
                OP_PUSHDATA2 => 2,
                else => 4,
            };
            if (s.len < 1 + n) return OpReturnError.TruncatedScript;
            var v: u32 = 0;
            for (s[1..][0..n], 0..) |byte, i| v |= @as(u32, byte) << @intCast(8 * i);
            len = v;
            hdr += n;
        },
        else => return OpReturnError.NonPushOpcode,
    }
    if (s.len - hdr < len) return OpReturnError.TruncatedScript;
    return .{ .data = s[hdr .. hdr + len], .rest = s[hdr + len ..] };
}

/// Extracts the first data push of an OP_RETURN script (the payload for Runes/Ordinals/bridge metadata).
/// A bare OP_RETURN yields an empty payload.
pub fn extractPayload(script: []const u8) OpReturnError![]const u8 {
    if (script.len == 0 or script[0] != OP_RETURN) return OpReturnError.NotOpReturn;
    if (script.len == 1) return script[1..1];
    return (try readPush(script[1..])).data;
}

test "REQ-UTXO-02 extract op_return payload" {
    const direct = [_]u8{ 0x6a, 0x04, 't', 'e', 's', 't' };
    try std.testing.expectEqualStrings("test", try extractPayload(&direct));

    const pd1 = [_]u8{ 0x6a, 0x4c, 0x02, 'h', 'i' };
    try std.testing.expectEqualStrings("hi", try extractPayload(&pd1));

    const pd2 = [_]u8{ 0x6a, 0x4d, 0x02, 0x00, 'h', 'i' };
    try std.testing.expectEqualStrings("hi", try extractPayload(&pd2));

    const pd4 = [_]u8{ 0x6a, 0x4e, 0x02, 0x00, 0x00, 0x00, 'h', 'i' };
    try std.testing.expectEqualStrings("hi", try extractPayload(&pd4));

    try std.testing.expectEqual(@as(usize, 0), (try extractPayload(&[_]u8{0x6a})).len);
}

test "REQ-UTXO-02 op_return rejects malformed" {
    try std.testing.expectError(OpReturnError.NotOpReturn, extractPayload(&[_]u8{0x76}));
    try std.testing.expectError(OpReturnError.TruncatedScript, extractPayload(&[_]u8{ 0x6a, 0x05, 'a' }));
    try std.testing.expectError(OpReturnError.TruncatedScript, extractPayload(&[_]u8{ 0x6a, 0x4e, 0xff, 0xff, 0xff, 0xff }));
    try std.testing.expectError(OpReturnError.NonPushOpcode, extractPayload(&[_]u8{ 0x6a, 0x51 }));
}
