//! Ordinals inscription envelope: `OP_FALSE OP_IF "ord" [tag value]... OP_0 <body pushes> OP_ENDIF`
//! inside a witness (tapscript) script. Extracts the content type and body.
//! shortcut: only the first envelope of a script, only tag 1 (content type) is surfaced,
//! upgrade when metadata/parent/pointer tags are needed.
const std = @import("std");
const script = @import("script.zig");
const hex = @import("../../core/encodings/hex.zig");
const fuzz = @import("../../core/fuzz.zig");

pub const OrdError = error{
    TruncatedScript,
    /// Non-push opcode in a body that `find` did not validate.
    InvalidEnvelope,
    BufferTooSmall,
};

const PROTOCOL_ID = "ord";

pub const Inscription = struct {
    content_type: ?[]const u8,
    /// Script bytes after the body separator; read with `nextChunk` / `readBody`.
    body_script: []const u8,

    /// Next body push, null at OP_ENDIF (or script end).
    pub fn nextChunk(self: *Inscription) OrdError!?[]const u8 {
        var it = script.Iterator.init(self.body_script);
        const ins = (it.next() catch return OrdError.TruncatedScript) orelse return null;
        self.body_script = it.rest;
        if (ins.opcode == script.OP_ENDIF) return null;
        return pushValue(&ins) orelse OrdError.InvalidEnvelope;
    }

    /// Concatenates the body pushes into `dest`.
    pub fn readBody(self: Inscription, dest: []u8) OrdError![]const u8 {
        var copy = self;
        var n: usize = 0;
        while (try copy.nextChunk()) |c| {
            if (dest.len - n < c.len) return OrdError.BufferTooSmall;
            @memcpy(dest[n..][0..c.len], c);
            n += c.len;
        }
        return dest[0..n];
    }
};

/// First well-formed `OP_FALSE OP_IF "ord"` envelope in `witness_script`, or null. As in ord's
/// `from_tapscript`, a bad envelope is skipped and an undecodable script yields nothing at all, so
/// the whole script is walked even after a match.
pub fn find(witness_script: []const u8) OrdError!?Inscription {
    var it = script.Iterator.init(witness_script);
    var found: ?Inscription = null;
    var p1: u16 = 0x100; // previous opcode, 0x100 = none
    var p2: u16 = 0x100;
    while (it.next() catch return OrdError.TruncatedScript) |ins| {
        if (found == null and ins.isPush() and ins.opcode != 0 and std.mem.eql(u8, ins.data, PROTOCOL_ID) and p1 == script.OP_IF and p2 == script.OP_0) {
            found = try parseEnvelope(&it);
            p1 = 0x100;
            p2 = 0x100;
            continue;
        }
        p2 = p1;
        p1 = if (ins.isPush() and ins.data.len == 0) script.OP_0 else ins.opcode; // ord compares the pushed bytes
    }
    return found;
}

const PUSHNUM_VALUES = [_]u8{ 0x81, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

/// Data of a push. As in ord's envelope.rs, OP_1NEGATE and OP_1..OP_16 count as one-byte pushes;
/// many real inscriptions write their tags that way.
fn pushValue(ins: *const script.Instruction) ?[]const u8 {
    if (ins.isPush()) return ins.data;
    if (ins.opcode < 0x4f or ins.opcode > 0x60 or ins.opcode == 0x50) return null;
    return PUSHNUM_VALUES[ins.opcode - 0x4f ..][0..1];
}

/// Walks one envelope to its OP_ENDIF. Null if it never gets there or holds a non-push, as in
/// ord's `from_instructions`. Tag and value alternate until an empty tag starts the body; a tag
/// left without a value is ord's `incomplete_field`, which is still an inscription.
fn parseEnvelope(it: *script.Iterator) OrdError!?Inscription {
    var ct: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    var in_body = false;
    var body: []const u8 = &.{};
    while (it.next() catch return OrdError.TruncatedScript) |ins| {
        if (ins.opcode == script.OP_ENDIF) return .{ .content_type = ct, .body_script = body };
        const push = pushValue(&ins) orelse return null;
        if (in_body) continue;
        if (tag) |t| {
            if (ct == null and t.len == 1 and t[0] == 1) ct = push;
            tag = null;
        } else if (push.len == 0) {
            in_body = true;
            body = it.rest;
        } else tag = push;
    }
    return null;
}

fn plainAscii(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c > 0x7e or c == '"' or c == '\\') return false;
    return true;
}

/// Writes `{"content_type":"image/png","body":"0x..."}` (content_type null if absent or not plain
/// ASCII) for the first envelope, or `null` text if none.
pub fn renderJson(witness_script: []const u8, dest: []u8) OrdError![]const u8 {
    var w = std.Io.Writer.fixed(dest);
    emit(&w, witness_script) catch |e| return switch (e) {
        error.WriteFailed => OrdError.BufferTooSmall,
        else => |r| r,
    };
    return w.buffered();
}

fn emit(w: *std.Io.Writer, witness_script: []const u8) (OrdError || std.Io.Writer.Error)!void {
    var ins = (try find(witness_script)) orelse return w.writeAll("null");
    if (ins.content_type) |c| {
        if (plainAscii(c)) try w.print("{{\"content_type\":\"{s}\",\"body\":\"0x", .{c}) else try w.writeAll("{\"content_type\":null,\"body\":\"0x");
    } else try w.writeAll("{\"content_type\":null,\"body\":\"0x");
    while (try ins.nextChunk()) |c| {
        for (c) |b| try w.print("{x:0>2}", .{b});
    }
    try w.writeAll("\"}");
}

test "REQ-UTXO-02 ordinals tag written as OP_1, per ord envelope.rs" {
    const s = [_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51, 0x0a } ++ "text/plain".* ++ [_]u8{ 0x00, 0x02, 'h', 'i', 0x68 };
    var ins = (try find(&s)).?;
    try std.testing.expectEqualStrings("text/plain", ins.content_type.?);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hi", try ins.readBody(&buf));
}

test "REQ-UTXO-02 ordinals envelope content type and multi-push body" {
    // Layout per docs.ordinals.com/inscriptions: <pubkey> OP_CHECKSIG OP_FALSE OP_IF "ord" 01 <ct> OP_0 <body...> OP_ENDIF
    const s = [_]u8{ 0x03, 1, 2, 3, 0xac, 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x01, 0x01, 0x0a } ++ "text/plain".* ++
        [_]u8{ 0x00, 0x02, 'h', 'e', 0x03, 'l', 'l', 'o', 0x68 };
    var ins = (try find(&s)).?;
    try std.testing.expectEqualStrings("text/plain", ins.content_type.?);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try ins.readBody(&buf));
    try std.testing.expectError(OrdError.BufferTooSmall, ins.readBody(buf[0..3]));
    var out: [96]u8 = undefined;
    try std.testing.expectEqualStrings("{\"content_type\":\"text/plain\",\"body\":\"0x68656c6c6f\"}", try renderJson(&s, &out));
    try std.testing.expectError(OrdError.BufferTooSmall, renderJson(&s, out[0..20]));
}

test "REQ-UTXO-02 ordinals absent, empty and malformed" {
    try std.testing.expect((try find(&[_]u8{ 0x51, 0xac })) == null);
    try std.testing.expect((try find(&[_]u8{ 0x00, 0x63, 0x03, 'x', 'y', 'z', 0x68 })) == null);
    // no content type, no body
    var ins = (try find(&[_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x68 })).?;
    try std.testing.expect(ins.content_type == null);
    try std.testing.expect((try ins.nextChunk()) == null);
    // Unterminated: no inscription, even with a complete-looking body.
    try std.testing.expect((try find(&[_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51 })) == null);
    try std.testing.expect((try find(&[_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x01, 0x01, 0x01, 0x41, 0x00, 0x02, 'h', 'i' })) == null);
    // ord's incomplete_field: a tag without a value is still an inscription.
    try std.testing.expect((try find(&[_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x01, 0x01, 0x68 })).?.content_type == null);
    try std.testing.expectError(OrdError.TruncatedScript, find(&[_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x05 }));
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("null", try renderJson(&[_]u8{0x51}, &out));
}

test "REQ-UTXO-02 ordinals bad envelopes do not hide later ones, per ord envelope.rs" {
    const bad = [_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x76, 0x68 }; // OP_DUP inside
    const good = [_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x00, 0x02, 'h', 'i', 0x68 };
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hi", try (try find(&(bad ++ good))).?.readBody(&buf));
    // OP_PUSHDATA1 of nothing opens an envelope just as OP_0 does.
    try std.testing.expectEqualStrings("hi", try (try find(&([_]u8{0x4c} ++ good))).?.readBody(&buf));
    // First envelope wins when both are good.
    try std.testing.expectEqualStrings("hi", try (try find(&(good ++ [_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x68 }))).?.readBody(&buf));
    // A script that stops decoding drops every envelope, even one already complete.
    try std.testing.expectError(OrdError.TruncatedScript, find(&(good ++ [_]u8{0x05})));
}

fn walk(_: void, bytes: []const u8) void {
    var out: [512]u8 = undefined;
    _ = renderJson(bytes, &out) catch {};
    var buf: [128]u8 = undefined;
    if (find(bytes) catch null) |ins| _ = ins.readBody(&buf) catch {};
}

test "REQ-UTXO-02 ordinals fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [96]u8 = undefined;
            walk({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-UTXO-02 ordinals mutation stress" {
    const seed = [_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x01, 0x01, 0x04, 't', 'e', 'x', 't', 0x00, 0x02, 'h', 'i', 0x68 };
    fuzz.stress(200_000, &.{&seed}, {}, walk);
}
