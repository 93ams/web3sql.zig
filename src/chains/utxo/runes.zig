//! Runestone envelope: `OP_RETURN OP_13 <data pushes...>`, payload = concatenated pushes,
//! decoded as LEB128 u128 integers (ordinals runes spec). Fields are tag/value pairs up to the
//! body tag (0); the body is left as raw integers. shortcut: no edict/etching semantics and no
//! cenotaph rules beyond structural errors, a full runes indexer is out of scope.
const std = @import("std");
const script = @import("script.zig");
const fuzz = @import("../../core/fuzz.zig");

pub const RunesError = error{
    NotRunestone,
    /// A non-push opcode after OP_13 (a cenotaph in the spec).
    NonPushOpcode,
    TruncatedScript,
    TruncatedInteger,
    IntegerOverflow,
    /// Non-minimal LEB128 (trailing zero byte).
    OverlongInteger,
    PayloadTooLarge,
    BufferTooSmall,
};

pub const BODY_TAG: u128 = 0;

pub const Int = struct { value: u128, rest: []const u8 };

/// Reads one LEB128 u128. Mirrors ord: at most 19 bytes, no overflow, no overlong encodings.
pub fn readInt(bytes: []const u8) RunesError!Int {
    var v: u128 = 0;
    var shift: u32 = 0;
    for (bytes, 0..) |b, i| {
        const low: u128 = b & 0x7f;
        if (shift == 126 and low > 3) return RunesError.IntegerOverflow;
        v |= low << @intCast(shift);
        if (b & 0x80 == 0) {
            if (i > 0 and low == 0) return RunesError.OverlongInteger;
            return .{ .value = v, .rest = bytes[i + 1 ..] };
        }
        shift += 7;
        if (shift > 126) return RunesError.IntegerOverflow;
    }
    return RunesError.TruncatedInteger;
}

pub const Pair = struct { tag: u128, value: u128 };

/// Iterates the tag/value fields; stops (null) at the body tag or the end, leaving the body in `body`.
pub const PairIterator = struct {
    rest: []const u8,
    body: []const u8 = &.{},

    pub fn next(self: *PairIterator) RunesError!?Pair {
        if (self.rest.len == 0) return null;
        const t = try readInt(self.rest);
        if (t.value == BODY_TAG) {
            self.body = t.rest;
            self.rest = &.{};
            return null;
        }
        const v = readInt(t.rest) catch |e| {
            self.rest = &.{};
            return e;
        };
        self.rest = v.rest;
        return .{ .tag = t.value, .value = v.value };
    }
};

/// Max OP_RETURN script the row path buffers (consensus script size limit).
pub const MAX_SCRIPT: usize = 10_000;

/// Concatenates the data pushes after `OP_RETURN OP_13` into `dest` and returns the LEB128 payload.
pub fn extractPayload(spk: []const u8, dest: []u8) RunesError![]const u8 {
    if (spk.len < 2 or spk[0] != script.OP_RETURN or spk[1] != script.OP_13) return RunesError.NotRunestone;
    var it = script.Iterator.init(spk[2..]);
    var n: usize = 0;
    while (it.next() catch return RunesError.TruncatedScript) |ins| {
        if (!ins.isPush()) return RunesError.NonPushOpcode;
        if (dest.len - n < ins.data.len) return RunesError.PayloadTooLarge;
        @memcpy(dest[n..][0..ins.data.len], ins.data);
        n += ins.data.len;
    }
    return dest[0..n];
}

fn writeInt(w: *std.Io.Writer, v: u128) !void {
    // JSON numbers beyond 2^53 lose precision in most SQL engines: emit them as strings.
    if (v > (1 << 53)) try w.print("\"{d}\"", .{v}) else try w.print("{d}", .{v});
}

/// Writes `{"fields":[[tag,value],...],"body":[int,...]}` for a runestone scriptPubKey.
pub fn renderJson(spk: []const u8, dest: []u8) RunesError![]const u8 {
    var pbuf: [MAX_SCRIPT]u8 = undefined;
    const payload = try extractPayload(spk, &pbuf);
    var w = std.Io.Writer.fixed(dest);
    emit(&w, payload) catch |e| return switch (e) {
        error.WriteFailed => RunesError.BufferTooSmall,
        else => |r| r,
    };
    return w.buffered();
}

fn emit(w: *std.Io.Writer, payload: []const u8) (RunesError || std.Io.Writer.Error)!void {
    try w.writeAll("{\"fields\":[");
    var it = PairIterator{ .rest = payload };
    var first = true;
    while (try it.next()) |p| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("[");
        try writeInt(w, p.tag);
        try w.writeAll(",");
        try writeInt(w, p.value);
        try w.writeAll("]");
    }
    try w.writeAll("],\"body\":[");
    var body = it.body;
    first = true;
    while (body.len > 0) {
        const i = try readInt(body);
        if (!first) try w.writeAll(",");
        first = false;
        try writeInt(w, i.value);
        body = i.rest;
    }
    try w.writeAll("]}");
}

test "REQ-UTXO-02 runestone fields and body" {
    // Hand-built per the runes spec (docs.ordinals.com/runes): tag 2 (Flags)=1, tag 4 (Rune)=300, body edict ints.
    // 300 = 0xAC 0x02 in LEB128.
    const payload = [_]u8{ 2, 1, 4, 0xac, 0x02, 0, 1, 1, 100, 0 };
    const spk = [_]u8{ 0x6a, 0x5d, payload.len } ++ payload;
    var buf: [64]u8 = undefined;
    const got = try extractPayload(&spk, &buf);
    try std.testing.expectEqualSlices(u8, &payload, got);
    var it = PairIterator{ .rest = got };
    try std.testing.expectEqual(Pair{ .tag = 2, .value = 1 }, (try it.next()).?);
    try std.testing.expectEqual(Pair{ .tag = 4, .value = 300 }, (try it.next()).?);
    try std.testing.expect((try it.next()) == null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 100, 0 }, it.body);
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("{\"fields\":[[2,1],[4,300]],\"body\":[1,1,100,0]}", try renderJson(&spk, &out));
    try std.testing.expectError(RunesError.BufferTooSmall, renderJson(&spk, out[0..10]));
}

test "REQ-UTXO-02 runestone multi-push and empty" {
    var buf: [16]u8 = undefined;
    const spk = [_]u8{ 0x6a, 0x5d, 0x02, 2, 1, 0x01, 0x00 };
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 1, 0 }, try extractPayload(&spk, &buf));
    try std.testing.expectEqual(@as(usize, 0), (try extractPayload(&[_]u8{ 0x6a, 0x5d }, &buf)).len);
    try std.testing.expectError(RunesError.NonPushOpcode, extractPayload(&[_]u8{ 0x6a, 0x5d, 0x51 }, &buf));
    try std.testing.expectError(RunesError.NotRunestone, extractPayload(&[_]u8{ 0x6a, 0x04, 't', 'e', 's', 't' }, &buf));
    try std.testing.expectError(RunesError.TruncatedScript, extractPayload(&[_]u8{ 0x6a, 0x5d, 0x09, 1 }, &buf));
    try std.testing.expectError(RunesError.PayloadTooLarge, extractPayload(&[_]u8{ 0x6a, 0x5d, 0x03, 1, 2, 3 }, buf[0..2]));
}

fn filled(comptime n: usize, b: u8) [n]u8 {
    return @splat(b);
}

test "REQ-UTXO-02 leb128 u128 limits" {
    const max = filled(18, 0xff) ++ [_]u8{0x03};
    try std.testing.expectEqual(std.math.maxInt(u128), (try readInt(&max)).value);
    var over = max;
    over[18] = 0x04;
    try std.testing.expectError(RunesError.IntegerOverflow, readInt(&over));
    try std.testing.expectError(RunesError.IntegerOverflow, readInt(&(filled(19, 0x80) ++ [_]u8{0x01})));
    try std.testing.expectError(RunesError.OverlongInteger, readInt(&[_]u8{ 0x80, 0x00 }));
    try std.testing.expectError(RunesError.TruncatedInteger, readInt(&[_]u8{0x80}));
    try std.testing.expectError(RunesError.TruncatedInteger, readInt(&.{}));
    var out: [200]u8 = undefined;
    const spk = [_]u8{ 0x6a, 0x5d, 0x14, 2 } ++ max;
    try std.testing.expectEqualStrings("{\"fields\":[[2,\"340282366920938463463374607431768211455\"]],\"body\":[]}", try renderJson(&spk, &out));
}

fn walk(_: void, bytes: []const u8) void {
    var buf: [256]u8 = undefined;
    var out: [512]u8 = undefined;
    _ = renderJson(bytes, &out) catch {};
    const p = extractPayload(bytes, &buf) catch bytes;
    var it = PairIterator{ .rest = p };
    while (it.next() catch null) |_| {}
    var body = it.body;
    while (readInt(body) catch null) |i| body = i.rest;
}

test "REQ-UTXO-02 runes fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [96]u8 = undefined;
            walk({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-UTXO-02 runes mutation stress" {
    const seed = [_]u8{ 0x6a, 0x5d, 0x0a, 2, 1, 4, 0xac, 0x02, 0, 1, 1, 100 };
    fuzz.stress(200_000, &.{&seed}, {}, walk);
}
