const std = @import("std");
const reader = @import("../../core/reader.zig");
const base58 = @import("../../core/encodings/base58.zig");
const fuzz = @import("../../core/fuzz.zig");

pub const BorshError = reader.ReadError || error{
    InvalidOptionTag,
    InvalidEnumTag,
    InvalidUtf8,
    InvalidFloat,
    /// A Vec/array of zero-sized elements would loop without consuming input.
    ZeroSizedElement,
    DepthExceeded,
    TrailingBytes,
    BufferTooSmall,
};

pub const BorshReader = struct {
    r: reader.Reader,

    pub fn init(bytes: []const u8) BorshReader {
        return .{ .r = reader.Reader.init(bytes) };
    }

    pub fn remaining(self: *const BorshReader) usize {
        return self.r.remaining();
    }

    pub fn readByte(self: *BorshReader) BorshError!u8 {
        return self.r.readByte();
    }

    pub fn readBool(self: *BorshReader) BorshError!bool {
        return self.r.readBool();
    }

    pub fn readU32(self: *BorshReader) BorshError!u32 {
        return self.r.readIntLE(u32);
    }

    pub fn readU64(self: *BorshReader) BorshError!u64 {
        return self.r.readIntLE(u64);
    }

    pub fn readSlice(self: *BorshReader, len: usize) BorshError![]const u8 {
        return self.r.readSlice(len);
    }

    /// Option<T> tag: 0 = None, 1 = Some.
    pub fn readOptionTag(self: *BorshReader) BorshError!bool {
        return switch (try self.r.readByte()) {
            0 => false,
            1 => true,
            else => BorshError.InvalidOptionTag,
        };
    }

    /// Vec<T>/String length prefix (u32 LE). Rejects lengths that cannot fit in the remaining bytes
    /// given a minimum element size, so a hostile length cannot drive a long loop.
    pub fn readVecLen(self: *BorshReader, min_elem_size: usize) BorshError!usize {
        const n: usize = try self.readU32();
        if (min_elem_size != 0 and n > self.remaining() / min_elem_size) return BorshError.UnexpectedEndOfBuffer;
        return n;
    }

    /// Borsh string / Vec<u8>: u32 LE length + bytes.
    pub fn readBytes(self: *BorshReader) BorshError![]const u8 {
        return self.readSlice(try self.readVecLen(1));
    }
};

/// Primitive Borsh types. `pubkey` is 32 raw bytes, rendered as Base58.
pub const Prim = enum {
    bool,
    u8,
    u16,
    u32,
    u64,
    u128,
    u256,
    i8,
    i16,
    i32,
    i64,
    i128,
    i256,
    f32,
    f64,
    string,
    pubkey,

    fn fixedSize(self: Prim) u64 {
        return switch (self) {
            .bool, .u8, .i8 => 1,
            .u16, .i16 => 2,
            .u32, .i32, .f32, .string => 4, // string: length prefix is the minimum
            .u64, .i64, .f64 => 8,
            .u128, .i128 => 16,
            .u256, .i256, .pubkey => 32,
        };
    }
};

pub const Field = struct { name: []const u8, ty: Type };
/// A tuple struct or tuple variant has fields with empty names.
pub const Variant = struct { name: []const u8, fields: []const Field = &.{} };

/// Runtime Borsh schema tree. Built at bind time (see the constructors) and then read-only;
/// `min` caches the smallest encoded size of the element so hostile lengths are rejected up front.
pub const Type = union(enum) {
    prim: Prim,
    array: struct { elem: *const Type, len: u32, min: u64 },
    vec: struct { elem: *const Type, min: u64 },
    option: *const Type,
    record: struct { fields: []const Field, min: u64 },
    enumeration: struct { variants: []const Variant, min: u64 },

    pub fn arrayOf(a: std.mem.Allocator, elem: Type, len: u32) std.mem.Allocator.Error!Type {
        const p = try a.create(Type);
        p.* = elem;
        return .{ .array = .{ .elem = p, .len = len, .min = elem.minSize() } };
    }

    pub fn vecOf(a: std.mem.Allocator, elem: Type) std.mem.Allocator.Error!Type {
        const p = try a.create(Type);
        p.* = elem;
        return .{ .vec = .{ .elem = p, .min = elem.minSize() } };
    }

    pub fn optionOf(a: std.mem.Allocator, inner: Type) std.mem.Allocator.Error!Type {
        const p = try a.create(Type);
        p.* = inner;
        return .{ .option = p };
    }

    pub fn recordOf(fields: []const Field) Type {
        return .{ .record = .{ .fields = fields, .min = fieldsMin(fields) } };
    }

    pub fn enumOf(variants: []const Variant) Type {
        var m: u64 = std.math.maxInt(u64);
        for (variants) |v| m = @min(m, fieldsMin(v.fields));
        return .{ .enumeration = .{ .variants = variants, .min = 1 +| (if (variants.len == 0) 0 else m) } };
    }

    /// Smallest number of bytes any value of this type occupies (saturating). O(1): IDL types share
    /// their fields, so walking them here would visit every path through a DAG.
    pub fn minSize(self: Type) u64 {
        switch (self) {
            .prim => |p| return p.fixedSize(),
            .array => |x| return x.min *| x.len,
            .vec => return 4,
            .option => return 1,
            .record => |r| return r.min,
            .enumeration => |e| return e.min,
        }
    }
};

fn fieldsMin(fields: []const Field) u64 {
    var m: u64 = 0;
    for (fields) |f| m +|= f.ty.minSize();
    return m;
}

pub const MAX_DEPTH = 64;

/// Bounded JSON sink over a caller buffer; overflow is `BufferTooSmall`, never truncation.
pub const JsonOut = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(dest: []u8) JsonOut {
        return .{ .buf = dest };
    }

    pub fn written(self: *const JsonOut) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn put(self: *JsonOut, s: []const u8) error{BufferTooSmall}!void {
        if (s.len > self.buf.len - self.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn print(self: *JsonOut, comptime fmt: []const u8, args: anytype) error{BufferTooSmall}!void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return error.BufferTooSmall;
        self.len += s.len;
    }

    /// Quoted, escaped JSON string.
    pub fn string(self: *JsonOut, s: []const u8) error{BufferTooSmall}!void {
        try self.put("\"");
        for (s) |c| switch (c) {
            '"' => try self.put("\\\""),
            '\\' => try self.put("\\\\"),
            0...0x1f => try self.print("\\u{x:0>4}", .{c}),
            else => try self.put(&.{c}),
        };
        try self.put("\"");
    }

    fn hex(self: *JsonOut, bytes: []const u8) error{BufferTooSmall}!void {
        if (2 * bytes.len + 4 > self.buf.len - self.len) return error.BufferTooSmall;
        try self.put("\"0x");
        for (bytes) |b| try self.print("{x:0>2}", .{b});
        try self.put("\"");
    }

    /// Integers beyond 2^53 become decimal strings so JSON consumers keep every digit.
    fn int(self: *JsonOut, v: anytype) error{BufferTooSmall}!void {
        const safe = 9007199254740992;
        const big = if (@typeInfo(@TypeOf(v)).int.bits < 64) false else v > safe or (@typeInfo(@TypeOf(v)).int.signedness == .signed and v < -safe);
        if (big) try self.print("\"{d}\"", .{v}) else try self.print("{d}", .{v});
    }
};

fn IntOf(comptime p: Prim) type {
    const name = @tagName(p);
    const bits = std.fmt.parseInt(u16, name[1..], 10) catch unreachable; // comptime, tag names are u<N>/i<N>
    return @Int(if (name[0] == 'u') .unsigned else .signed, bits);
}

/// Decodes one value of `ty` from `r` and appends it to `out` as compact JSON.
/// Work is bounded by the input length: every Vec/array length is checked against the remaining bytes first.
pub fn writeValue(ty: *const Type, r: *BorshReader, out: *JsonOut, depth: usize) BorshError!void {
    if (depth >= MAX_DEPTH) return BorshError.DepthExceeded;
    switch (ty.*) {
        .prim => |p| try writePrim(p, r, out),
        .option => |inner| {
            if (try r.readOptionTag()) try writeValue(inner, r, out, depth + 1) else try out.put("null");
        },
        .vec => |v| try writeSeq(v.elem, try r.readVecLen(std.math.cast(usize, v.min) orelse std.math.maxInt(usize)), v.min, r, out, depth),
        .array => |a| {
            if (a.len > 0 and a.min > r.remaining()) return BorshError.UnexpectedEndOfBuffer;
            try writeSeq(a.elem, a.len, a.min, r, out, depth);
        },
        .record => |x| try writeFields(x.fields, r, out, depth),
        .enumeration => |e| {
            const tag = try r.readByte();
            if (tag >= e.variants.len) return BorshError.InvalidEnumTag;
            const v = e.variants[tag];
            if (v.fields.len == 0) return out.string(v.name);
            try out.put("{");
            try out.string(v.name);
            try out.put(":");
            try writeFields(v.fields, r, out, depth);
            try out.put("}");
        },
    }
}

fn writeSeq(elem: *const Type, n: usize, min: u64, r: *BorshReader, out: *JsonOut, depth: usize) BorshError!void {
    if (n > 0 and min == 0) return BorshError.ZeroSizedElement;
    if (elem.* == .prim and elem.prim == .u8) return out.hex(try r.readSlice(n));
    try out.put("[");
    for (0..n) |i| {
        if (i != 0) try out.put(",");
        try writeValue(elem, r, out, depth + 1);
    }
    try out.put("]");
}

fn writeFields(fields: []const Field, r: *BorshReader, out: *JsonOut, depth: usize) BorshError!void {
    const tuple = fields.len > 0 and fields[0].name.len == 0;
    try out.put(if (tuple) "[" else "{");
    for (fields, 0..) |f, i| {
        if (i != 0) try out.put(",");
        if (!tuple) {
            try out.string(f.name);
            try out.put(":");
        }
        try writeValue(&f.ty, r, out, depth + 1);
    }
    try out.put(if (tuple) "]" else "}");
}

fn writePrim(p: Prim, r: *BorshReader, out: *JsonOut) BorshError!void {
    switch (p) {
        .bool => try out.put(if (try r.readBool()) "true" else "false"),
        inline .u8, .u16, .u32, .u64, .u128, .u256, .i8, .i16, .i32, .i64, .i128, .i256 => |t| try out.int(try r.r.readIntLE(IntOf(t))),
        inline .f32, .f64 => |t| {
            const F = if (t == .f32) f32 else f64;
            const v: F = @bitCast(try r.r.readIntLE(if (t == .f32) u32 else u64));
            if (std.math.isNan(v)) return BorshError.InvalidFloat; // Borsh forbids NaN
            if (std.math.isInf(v)) return out.put(if (v > 0) "\"Infinity\"" else "\"-Infinity\"");
            try out.print("{d}", .{v});
        },
        .string => {
            const s = try r.readBytes();
            if (!std.unicode.utf8ValidateSlice(s)) return BorshError.InvalidUtf8;
            try out.string(s);
        },
        .pubkey => {
            var b58: [base58.MAX_ENCODED_LEN]u8 = undefined;
            const text = base58.encodeBase58(try r.readSlice(32), &b58) catch unreachable; // 32 bytes always fit
            try out.put("\"");
            try out.put(text);
            try out.put("\"");
        },
    }
}

/// Decodes `bytes` as exactly one `ty` and returns compact JSON written into `dest`.
/// Integers beyond 2^53 are decimal strings, `Vec<u8>`/`[u8; N]` are 0x hex, pubkeys Base58.
pub fn renderJson(ty: *const Type, bytes: []const u8, dest: []u8) BorshError![]const u8 {
    var r = BorshReader.init(bytes);
    var out = JsonOut.init(dest);
    try writeValue(ty, &r, &out, 0);
    if (r.remaining() != 0) return BorshError.TrailingBytes;
    return out.written();
}

test "REQ-SVM-02 borsh reader primitive deserialization" {
    const raw = [_]u8{ 1, 0x2a, 0, 0, 0, 0xef, 0xbe, 0xad, 0xde, 0, 0, 0, 0 };
    var r = BorshReader.init(&raw);
    try std.testing.expectEqual(true, try r.readBool());
    try std.testing.expectEqual(@as(u32, 42), try r.readU32());
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), try r.readU64());
}

test "REQ-SVM-02 borsh bytes, option, hostile length" {
    var r = BorshReader.init(&[_]u8{ 2, 0, 0, 0, 'h', 'i', 1, 0 });
    try std.testing.expectEqualStrings("hi", try r.readBytes());
    try std.testing.expect(try r.readOptionTag());
    try std.testing.expect(!(try r.readOptionTag()));
    var bad = BorshReader.init(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 1 });
    try std.testing.expectError(BorshError.UnexpectedEndOfBuffer, bad.readBytes());
    var bad_opt = BorshReader.init(&[_]u8{2});
    try std.testing.expectError(BorshError.InvalidOptionTag, bad_opt.readOptionTag());
}

fn tp(prim: Prim) Type {
    return .{ .prim = prim };
}

fn expectJson(ty: *const Type, bytes: []const u8, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(want, try renderJson(ty, bytes, &buf));
}

test "REQ-SVM-02 schema renders every primitive" {
    // Encodings follow the Borsh specification (borsh.io): little-endian ints, u32-length strings, 1-byte bool.
    const fields = [_]Field{
        .{ .name = "a", .ty = tp(.u8) },
        .{ .name = "b", .ty = tp(.i16) },
        .{ .name = "c", .ty = tp(.u64) },
        .{ .name = "d", .ty = tp(.i64) },
        .{ .name = "e", .ty = tp(.u128) },
        .{ .name = "f", .ty = tp(.bool) },
        .{ .name = "g", .ty = tp(.string) },
        .{ .name = "h", .ty = tp(.f64) },
        .{ .name = "i", .ty = tp(.f32) },
        .{ .name = "j", .ty = tp(.u256) },
    };
    const ty = Type.recordOf(&fields);
    var raw: [100]u8 = undefined;
    var n: usize = 0;
    const parts = [_][]const u8{
        &.{7},
        &.{ 0xfe, 0xff }, // -2
        &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, // u64 max
        &.{ 0, 0, 0, 0, 0, 0, 0, 0x80 }, // i64 min
        &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        &.{1},
        &.{ 3, 0, 0, 0, 'a', '"', 0x0a },
        &std.mem.toBytes(@as(f64, 1.5)),
        &std.mem.toBytes(@as(f32, -0.25)),
        &.{ 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    for (parts) |x| {
        @memcpy(raw[n..][0..x.len], x);
        n += x.len;
    }
    try expectJson(&ty, raw[0..n], "{\"a\":7,\"b\":-2,\"c\":\"18446744073709551615\",\"d\":\"-9223372036854775808\",\"e\":1,\"f\":true," ++
        "\"g\":\"a\\\"\\u000a\",\"h\":1.5,\"i\":-0.25,\"j\":5}");
    var small: [10]u8 = undefined;
    try std.testing.expectError(BorshError.BufferTooSmall, renderJson(&ty, raw[0..n], &small));
    try std.testing.expectError(BorshError.TrailingBytes, renderJson(&tp(.u8), &.{ 1, 2 }, &small));
}

test "REQ-SVM-02 schema vec option array enum pubkey" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vec_u32 = try Type.vecOf(a, tp(.u32));
    try expectJson(&vec_u32, &.{ 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0 }, "[1,2]");
    const bytes = try Type.vecOf(a, tp(.u8));
    try expectJson(&bytes, &.{ 2, 0, 0, 0, 0xde, 0xad }, "\"0xdead\"");
    const opt = try Type.optionOf(a, tp(.u8));
    try expectJson(&opt, &.{ 1, 9 }, "9");
    try expectJson(&opt, &.{0}, "null");
    const arr = try Type.arrayOf(a, tp(.u16), 2);
    try expectJson(&arr, &.{ 1, 0, 2, 0 }, "[1,2]");
    const pk = tp(.pubkey);
    const key: [32]u8 = @splat(0);
    try expectJson(&pk, &key, "\"11111111111111111111111111111111\"");
    const variants = [_]Variant{
        .{ .name = "Nothing" },
        .{ .name = "Pair", .fields = &.{ .{ .name = "", .ty = tp(.u8) }, .{ .name = "", .ty = tp(.bool) } } },
        .{ .name = "Named", .fields = &.{.{ .name = "x", .ty = tp(.u32) }} },
    };
    const en = Type.enumOf(&variants);
    try expectJson(&en, &.{0}, "\"Nothing\"");
    try expectJson(&en, &.{ 1, 5, 1 }, "{\"Pair\":[5,true]}");
    try expectJson(&en, &.{ 2, 5, 0, 0, 0 }, "{\"Named\":{\"x\":5}}");
    var buf: [64]u8 = undefined;
    try std.testing.expectError(BorshError.InvalidEnumTag, renderJson(&en, &.{3}, &buf));
    try std.testing.expectError(BorshError.InvalidOptionTag, renderJson(&opt, &.{2}, &buf));
    try std.testing.expectError(BorshError.InvalidBool, renderJson(&tp(.bool), &.{2}, &buf));
    try std.testing.expectError(BorshError.InvalidUtf8, renderJson(&tp(.string), &.{ 1, 0, 0, 0, 0xff }, &buf));
    try std.testing.expectError(BorshError.InvalidFloat, renderJson(&tp(.f32), &std.mem.toBytes(std.math.nan(f32)), &buf));
}

test "REQ-SVM-02 hostile lengths and depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [64]u8 = undefined;
    const vec_u64 = try Type.vecOf(a, tp(.u64));
    // 0xffffffff elements promised, 4 bytes present: rejected before any iteration.
    try std.testing.expectError(BorshError.UnexpectedEndOfBuffer, renderJson(&vec_u64, &.{ 0xff, 0xff, 0xff, 0xff, 1, 2, 3, 4 }, &buf));
    // Vec of zero-sized elements with a huge count would spin forever without consuming input.
    const unit = Type.recordOf(&.{});
    const vec_unit = try Type.vecOf(a, unit);
    try std.testing.expectError(BorshError.ZeroSizedElement, renderJson(&vec_unit, &.{ 0xff, 0xff, 0xff, 0xff }, &buf));
    try expectJson(&vec_unit, &.{ 0, 0, 0, 0 }, "[]");
    const huge_arr = try Type.arrayOf(a, tp(.u64), 0xffff_ffff);
    try std.testing.expectError(BorshError.UnexpectedEndOfBuffer, renderJson(&huge_arr, &.{ 1, 2, 3 }, &buf));
    // A zero-length array needs no input, wherever it falls in the record.
    const empty = try Type.arrayOf(a, tp(.u64), 0);
    try expectJson(&empty, &.{}, "[]");
    // Nesting beyond MAX_DEPTH is an error, not a stack overflow.
    var t = tp(.u8);
    for (0..MAX_DEPTH + 1) |_| t = try Type.optionOf(a, t);
    const ones: [MAX_DEPTH + 2]u8 = @splat(1);
    try std.testing.expectError(BorshError.DepthExceeded, renderJson(&t, &ones, &buf));
}

test "REQ-SVM-02 real compute budget instructions from test_data/svm_instructions.parquet" {
    // Rows of slot 463317479 (signature prefixes 46fE53fT, 36nPrmZW, iPmZ8guG); the ComputeBudget
    // program encodes its instructions with Borsh: u8 variant tag + payload.
    const variants = [_]Variant{
        .{ .name = "RequestUnitsDeprecated", .fields = &.{ .{ .name = "units", .ty = tp(.u32) }, .{ .name = "additional_fee", .ty = tp(.u32) } } },
        .{ .name = "RequestHeapFrame", .fields = &.{.{ .name = "", .ty = tp(.u32) }} },
        .{ .name = "SetComputeUnitLimit", .fields = &.{.{ .name = "", .ty = tp(.u32) }} },
        .{ .name = "SetComputeUnitPrice", .fields = &.{.{ .name = "", .ty = tp(.u64) }} },
        .{ .name = "SetLoadedAccountsDataSizeLimit", .fields = &.{.{ .name = "", .ty = tp(.u32) }} },
    };
    const ty = Type.enumOf(&variants);
    const rows = [_]struct { b58: []const u8, want: []const u8 }{
        .{ .b58 = "HZoMm9", .want = "{\"SetComputeUnitLimit\":[5000]}" },
        .{ .b58 = "3QCwqmHZ4mdq", .want = "{\"SetComputeUnitPrice\":[1000000]}" },
        .{ .b58 = "UpPiXq", .want = "{\"SetLoadedAccountsDataSizeLimit\":[1000000]}" },
    };
    for (rows) |row| {
        var raw: [16]u8 = undefined;
        try expectJson(&ty, try base58.decodeBase58(row.b58, &raw), row.want);
    }
}

const stress_seed = [_]u8{ 2, 0, 0, 0, 'h', 'i', 1, 5, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0 };

fn fuzzOne(ty: *const Type, bytes: []const u8) void {
    var out: [1024]u8 = undefined;
    _ = renderJson(ty, bytes, &out) catch {};
}

fn stressType(a: std.mem.Allocator) !Type {
    const inner = try Type.vecOf(a, tp(.u8));
    const fields = try a.dupe(Field, &.{
        .{ .name = "s", .ty = tp(.string) },
        .{ .name = "o", .ty = try Type.optionOf(a, tp(.u32)) },
        .{ .name = "v", .ty = try Type.vecOf(a, inner) },
        .{ .name = "x", .ty = tp(.i128) },
        .{ .name = "f", .ty = tp(.f64) },
        .{ .name = "k", .ty = tp(.pubkey) },
    });
    const variants = try a.dupe(Variant, &.{ .{ .name = "A" }, .{ .name = "B", .fields = fields } });
    return Type.enumOf(variants);
}

test "REQ-SVM-02 borsh fuzz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ty = try stressType(arena.allocator());
    try std.testing.fuzz(&ty, struct {
        fn f(t: *const Type, smith: *std.testing.Smith) !void {
            var buf: [256]u8 = undefined;
            const n = smith.slice(&buf);
            fuzzOne(t, buf[0..n]);
        }
    }.f, .{});
}

test "REQ-SVM-02 borsh mutation stress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ty = try stressType(arena.allocator());
    const head = [_]u8{ 1, 2, 0, 0, 0, 'h', 'i', 1, 5, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0xde, 0xad };
    var valid: [head.len + 24 + 32]u8 = @splat(0);
    @memcpy(valid[0..head.len], &head);
    @memset(valid[head.len + 24 ..], 9);
    fuzz.stress(200_000, &.{ &valid, &stress_seed }, &ty, struct {
        fn f(t: *const Type, bytes: []const u8) void {
            fuzzOne(t, bytes);
        }
    }.f);
}
