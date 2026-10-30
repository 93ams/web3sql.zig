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
    /// Non-push opcode, or a tag without value, inside the envelope.
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
        if (!ins.isPush()) return OrdError.InvalidEnvelope;
        return ins.data;
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

/// Finds the first `OP_FALSE OP_IF "ord"` envelope in `witness_script`; null if there is none.
pub fn find(witness_script: []const u8) OrdError!?Inscription {
    var it = script.Iterator.init(witness_script);
    var p1: u16 = 0x100; // previous opcode, 0x100 = none
    var p2: u16 = 0x100;
    while (it.next() catch return OrdError.TruncatedScript) |ins| {
        if (ins.isPush() and ins.opcode != 0 and std.mem.eql(u8, ins.data, PROTOCOL_ID) and p1 == script.OP_IF and p2 == script.OP_0)
            return try parseFields(&it);
        p2 = p1;
        p1 = ins.opcode;
    }
    return null;
}

fn parseFields(it: *script.Iterator) OrdError!Inscription {
    var ct: ?[]const u8 = null;
    while (true) {
        const tag = (it.next() catch return OrdError.TruncatedScript) orelse return .{ .content_type = ct, .body_script = &.{} };
        if (tag.opcode == script.OP_ENDIF) return .{ .content_type = ct, .body_script = &.{} };
        if (tag.opcode == script.OP_0) return .{ .content_type = ct, .body_script = it.rest };
        if (!tag.isPush()) return OrdError.InvalidEnvelope;
        const val = (it.next() catch return OrdError.TruncatedScript) orelse return OrdError.InvalidEnvelope;
        if (!val.isPush()) return OrdError.InvalidEnvelope;
        if (ct == null and tag.data.len == 1 and tag.data[0] == 1) ct = val.data;
    }
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
    try std.testing.expectError(OrdError.InvalidEnvelope, find(&[_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51 }));
    try std.testing.expectError(OrdError.InvalidEnvelope, find(&[_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x01, 0x01, 0x68 }));
    try std.testing.expectError(OrdError.TruncatedScript, find(&[_]u8{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x05 }));
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("null", try renderJson(&[_]u8{0x51}, &out));
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
