//! Runtime BCS schema: a small tree built once at bind time, then used to render rows to JSON
//! without allocating. Text grammar (spaces ignored):
//!   T := bool | u8 | u16 | u32 | u64 | u128 | u256 | address | string
//!      | vector<T> | option<T> | enum<T|T|...> | (T,T,...) | {name:T,name:T,...}
//! `address` is 32 raw bytes; vector<u8> renders as 0x hex; `()` is a unit and renders null.
const std = @import("std");
const bcs = @import("bcs.zig");
const hex = @import("../../core/encodings/hex.zig");
const Out = @import("out.zig").Out;

pub const BcsError = bcs.BcsError;
pub const max_depth = 32;

pub const Field = struct { name: []const u8, node: Node };

pub const Node = union(enum) {
    bool,
    u8,
    u16,
    u32,
    u64,
    u128,
    u256,
    address,
    string,
    option: *const Node,
    vector: *const Node,
    /// Struct or tuple; fields with empty names form a tuple.
    record: []const Field,
    /// One node per variant, indexed by the ULEB128 variant tag.
    variants: []const Node,
};

/// Checks depth and that no vector element can be zero-sized (which would let a tiny input claim
/// 2^31 elements and make decoding work unbounded by input length). Call on hand-built trees.
pub fn check(node: *const Node) BcsError!void {
    _ = try checkDepth(node, 0);
}

fn checkDepth(node: *const Node, depth: usize) BcsError!usize {
    if (depth > max_depth) return BcsError.TooDeep;
    return switch (node.*) {
        .bool, .u8 => 1,
        .u16 => 2,
        .u32 => 4,
        .u64 => 8,
        .u128 => 16,
        .u256, .address => 32,
        .string => 1,
        .option => |c| {
            _ = try checkDepth(c, depth + 1);
            return 1;
        },
        .vector => |c| {
            if (try checkDepth(c, depth + 1) == 0) return BcsError.InvalidSchema;
            return 1;
        },
        .record => |fs| {
            var sum: usize = 0;
            for (fs) |*f| sum +|= try checkDepth(&f.node, depth + 1);
            return sum;
        },
        .variants => |vs| {
            for (vs) |*v| _ = try checkDepth(v, depth + 1);
            return 1;
        },
    };
}

/// Parses schema text. Everything is allocated from `alloc`; use an arena and free it as one.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) (BcsError || error{OutOfMemory})!*const Node {
    var p = Parser{ .alloc = alloc, .src = text };
    const n = try p.node(0);
    p.skip();
    if (p.pos != text.len) return BcsError.InvalidSchema;
    try check(n);
    return n;
}

const Parser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    const E = BcsError || error{OutOfMemory};

    fn skip(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] == ' ') self.pos += 1;
    }

    fn eat(self: *Parser, c: u8) bool {
        self.skip();
        if (self.pos < self.src.len and self.src[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, c: u8) E!void {
        if (!self.eat(c)) return BcsError.InvalidSchema;
    }

    fn word(self: *Parser) []const u8 {
        self.skip();
        const start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
        return self.src[start..self.pos];
    }

    fn child(self: *Parser, depth: usize) E!*const Node {
        const c = try self.alloc.create(Node);
        c.* = (try self.node(depth + 1)).*;
        return c;
    }

    fn node(self: *Parser, depth: usize) E!*const Node {
        if (depth > max_depth) return BcsError.TooDeep;
        const out = try self.alloc.create(Node);
        self.skip();
        if (self.eat('(')) {
            var fs: std.ArrayList(Field) = .empty;
            if (!self.eat(')')) while (true) {
                try fs.append(self.alloc, .{ .name = "", .node = (try self.node(depth + 1)).* });
                if (self.eat(')')) break;
                try self.expect(',');
            };
            out.* = .{ .record = try fs.toOwnedSlice(self.alloc) };
            return out;
        }
        if (self.eat('{')) {
            var fs: std.ArrayList(Field) = .empty;
            if (!self.eat('}')) while (true) {
                const name = self.word();
                if (name.len == 0) return BcsError.InvalidSchema;
                try self.expect(':');
                try fs.append(self.alloc, .{ .name = try self.alloc.dupe(u8, name), .node = (try self.node(depth + 1)).* });
                if (self.eat('}')) break;
                try self.expect(',');
            };
            out.* = .{ .record = try fs.toOwnedSlice(self.alloc) };
            return out;
        }
        const w = self.word();
        if (std.mem.eql(u8, w, "vector") or std.mem.eql(u8, w, "option")) {
            try self.expect('<');
            const c = try self.child(depth);
            try self.expect('>');
            out.* = if (w[0] == 'v') .{ .vector = c } else .{ .option = c };
        } else if (std.mem.eql(u8, w, "enum")) {
            try self.expect('<');
            var vs: std.ArrayList(Node) = .empty;
            while (true) {
                try vs.append(self.alloc, (try self.node(depth + 1)).*);
                if (self.eat('>')) break;
                try self.expect('|');
            }
            out.* = .{ .variants = try vs.toOwnedSlice(self.alloc) };
        } else inline for (.{ "bool", "u8", "u16", "u32", "u64", "u128", "u256", "address", "string" }) |name| {
            if (std.mem.eql(u8, w, name)) {
                out.* = @field(Node, name);
                return out;
            }
        } else return BcsError.InvalidSchema;
        return out;
    }
};

/// Decodes `bytes` against `root` and writes compact JSON into `dest`. u64/u128/u256 above 2^53
/// become decimal strings. Strict readers reject trailing bytes. Never allocates.
pub fn renderJson(root: *const Node, bytes: []const u8, strict: bool, dest: []u8) BcsError![]const u8 {
    var r = if (strict) bcs.BcsReader.init(bytes) else bcs.BcsReader.initLenient(bytes);
    var out = Out{ .buf = dest };
    try renderNode(&out, &r, root, 0);
    try r.finish();
    return out.written();
}

fn renderInt(out: *Out, v: anytype) BcsError!void {
    if (v > 9007199254740992) return out.print("\"{d}\"", .{v});
    return out.print("{d}", .{v});
}

fn renderNode(out: *Out, r: *bcs.BcsReader, node: *const Node, depth: usize) BcsError!void {
    if (depth > max_depth) return BcsError.TooDeep;
    switch (node.*) {
        .bool => try out.put(if (try r.readBool()) "true" else "false"),
        .u8 => try out.print("{d}", .{try r.readByte()}),
        .u16 => try out.print("{d}", .{try r.readU16()}),
        .u32 => try out.print("{d}", .{try r.readU32()}),
        .u64 => try renderInt(out, try r.readU64()),
        .u128 => try renderInt(out, try r.readU128()),
        .u256 => try renderInt(out, try r.readU256()),
        .address => try putHex(out, &(try r.readAddress())),
        .string => try putJsonString(out, try r.readString()),
        .option => |c| {
            if (try r.readOptionTag()) try renderNode(out, r, c, depth + 1) else try out.put("null");
        },
        .vector => |c| {
            // Zero-size elements are rejected by `check`, so n is bounded by remaining input.
            const n = try r.readSeqLen(1);
            if (c.* == .u8) return putHex(out, try r.r.readSlice(n));
            try out.put("[");
            for (0..n) |i| {
                if (i != 0) try out.put(",");
                try renderNode(out, r, c, depth + 1);
            }
            try out.put("]");
        },
        .record => |fs| {
            if (fs.len == 0) return out.put("null");
            const named = fs[0].name.len != 0;
            try out.put(if (named) "{" else "[");
            for (fs, 0..) |*f, i| {
                if (i != 0) try out.put(",");
                if (named) {
                    try putJsonString(out, f.name);
                    try out.put(":");
                }
                try renderNode(out, r, &f.node, depth + 1);
            }
            try out.put(if (named) "}" else "]");
        },
        .variants => |vs| {
            const idx = try r.readUleb32();
            if (idx >= vs.len) return BcsError.InvalidVariant;
            try out.print("{{\"variant\":{d},\"value\":", .{idx});
            try renderNode(out, r, &vs[idx], depth + 1);
            try out.put("}");
        },
    }
}

fn putHex(out: *Out, b: []const u8) BcsError!void {
    if (out.buf.len - out.pos < 4 or (out.buf.len - out.pos - 4) / 2 < b.len) return BcsError.BufferTooSmall;
    try out.put("\"0x");
    const n = (hex.encodeHex(b, out.buf[out.pos..]) catch return BcsError.BufferTooSmall).len;
    out.pos += n;
    try out.put("\"");
}

fn putJsonString(out: *Out, s: []const u8) BcsError!void {
    try out.put("\"");
    for (s) |c| switch (c) {
        '"' => try out.put("\\\""),
        '\\' => try out.put("\\\\"),
        0...0x1f => try out.print("\\u{x:0>4}", .{c}),
        else => try out.put(&[_]u8{c}),
    };
    try out.put("\"");
}

fn fill(comptime n: usize, head: []const u8, byte: u8) [n]u8 {
    var a: [n]u8 = undefined;
    @memset(&a, byte);
    @memcpy(a[0..head.len], head);
    return a;
}

fn tryRender(text: []const u8, bytes: []const u8, strict: bool, dest: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return renderJson(try parse(arena.allocator(), text), bytes, strict, dest);
}

fn expectJson(text: []const u8, bytes: []const u8, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(want, try tryRender(text, bytes, true, &buf));
}

fn expectFail(text: []const u8, bytes: []const u8, want: anyerror) !void {
    var buf: [512]u8 = undefined;
    try std.testing.expectError(want, tryRender(text, bytes, true, &buf));
}

test "REQ-MOVE-02 sui sdk Coin struct vector" {
    // MystenLabs/ts-sdks packages/bcs/tests/bcs.test.ts, bytes produced by Rust bcs.
    var raw: [24]u8 = undefined;
    try std.base64.standard.Decoder.decode(&raw, "gNGxBWAAAAAOQmlnIFdhbGxldCBHdXkA");
    try expectJson("{value:u64,owner:string,is_locked:bool}", &raw, "{\"value\":412412400000,\"owner\":\"Big Wallet Guy\",\"is_locked\":false}");
    try expectFail("{value:u64,owner:string,is_locked:bool}", raw[0..23], error.UnexpectedEndOfBuffer);
    var longer: [25]u8 = undefined;
    @memcpy(longer[0..24], &raw);
    longer[24] = 0;
    try expectFail("{value:u64,owner:string,is_locked:bool}", &longer, error.TrailingBytes);
    var buf: [512]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), "{value:u64,owner:string,is_locked:bool}");
    try std.testing.expect((try renderJson(root, &longer, false, &buf)).len > 0);
}

test "REQ-MOVE-02 bcs crate sequences, options, big ints" {
    // zefchain/bcs README: Vec<u16> [1,2] and Option<u8> Some(8).
    try expectJson("vector<u16>", &.{ 2, 1, 0, 2, 0 }, "[1,2]");
    try expectJson("option<u8>", &.{ 1, 8 }, "8");
    try expectJson("option<u8>", &.{0}, "null");
    try expectFail("option<u8>", &.{ 5, 0 }, error.InvalidOptionTag);
    // README: 1311768467750121216 as u64 and aptos-ts-sdk serializer u128/u256 bytes.
    const le = [_]u8{ 0x00, 0xEF, 0xCD, 0xAB, 0x78, 0x56, 0x34, 0x12 };
    try expectJson("u64", &le, "\"1311768467750121216\"");
    try expectJson("u128", &fill(16, &le, 0), "\"1311768467750121216\"");
    try expectJson("u256", &fill(32, &le, 0), "\"1311768467750121216\"");
    try expectJson("u128", &fill(16, "", 0xff), "\"340282366920938463463374607431768211455\"");
    try expectJson("u256", &fill(32, "", 0xff), "\"115792089237316195423570985008687907853269984665640564039457584007913129639935\"");
    try expectJson("u64", &.{ 0, 0, 0, 0, 0, 0, 0x20, 0 }, "9007199254740992");
    try expectJson("u64", &.{ 1, 0, 0, 0, 0, 0, 0x20, 0 }, "\"9007199254740993\"");
    // serde.rs: invalid bool, short vec, trailing elements, invalid utf8.
    try expectFail("bool", &.{9}, error.InvalidBool);
    try expectFail("vector<u8>", &.{ 5, 1, 2, 3, 4 }, error.UnexpectedEndOfBuffer);
    try expectFail("vector<u8>", &.{ 5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, error.TrailingBytes);
    try expectFail("string", &.{ 1, 0xFF }, error.InvalidUtf8);
    try expectFail("vector<u8>", &.{ 0x80, 0x00 }, error.VarintError);
    try expectFail("vector<u8>", &.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, error.VarintError);
}

test "REQ-MOVE-02 enums, tuples, addresses, bytes, escaping" {
    // serde.rs test_enum style variants: unit + newtype + tuple.
    try expectJson("enum<()|u8|(u8,u8)>", &.{0}, "{\"variant\":0,\"value\":null}");
    try expectJson("enum<()|u8|(u8,u8)>", &.{ 2, 1, 2 }, "{\"variant\":2,\"value\":[1,2]}");
    try expectFail("enum<()|u8>", &.{5}, error.InvalidVariant);
    try expectJson("vector<u8>", &.{ 5, 0x41, 0x70, 0x74, 0x6f, 0x73 }, "\"0x4170746f73\"");
    var one = fill(32, "", 0);
    one[31] = 1;
    try expectJson("address", &one, "\"0x0000000000000000000000000000000000000000000000000000000000000001\"");
    try expectJson("string", &.{ 4, '"', '\\', 'a', 1 }, "\"\\\"\\\\a\\u0001\"");
    try expectJson("vector<option<string>>", &.{ 2, 0, 1, 1, 'x' }, "[null,\"x\"]");
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, tryRender("vector<u8>", &.{ 5, 1, 2, 3, 4, 5 }, true, &tiny));
}

test "REQ-MOVE-02 schema validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The bcs crate serialises vec![(); 786_432] as 80 80 30; zero-size elements are refused at bind.
    for ([_][]const u8{ "vector<()>", "vector<({})>", "vector<(())>", "", "vector<u8", "u7", "{a u8}", "(u8,)", "{:u8}", "u8 u8", "enum<>", "enum<u8" }) |t|
        try std.testing.expect(std.meta.isError(parse(a, t)));
    _ = try parse(a, " { a : vector < option < u8 > > , b : ( u8 , string ) } ");
    var deep: [400]u8 = undefined;
    var n: usize = 0;
    for (0..40) |_| {
        @memcpy(deep[n..][0..7], "vector<");
        n += 7;
    }
    @memcpy(deep[n..][0..2], "u8");
    n += 2;
    @memset(deep[n..][0..40], '>');
    try std.testing.expectError(error.TooDeep, parse(a, deep[0 .. n + 40]));
}

const fuzz_text = "{a:u64,b:vector<option<string>>,c:enum<()|u8|(address,u256)>,d:vector<u8>}";
const fuzz_seed = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 1, 'x', 2, 7, 3, 1, 2, 3 };

fn fuzzOne(root: *const Node, bytes: []const u8) void {
    var buf: [1024]u8 = undefined;
    _ = renderJson(root, bytes, true, &buf) catch {};
    _ = renderJson(root, bytes, false, &buf) catch {};
}

test "REQ-MOVE-02 bcs fuzz" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), fuzz_text);
    try std.testing.fuzz(root, struct {
        fn f(r: *const Node, smith: *std.testing.Smith) !void {
            var b: [128]u8 = undefined;
            const n = smith.slice(&b);
            fuzzOne(r, b[0..n]);
        }
    }.f, .{});
}

test "REQ-MOVE-02 bcs stress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), fuzz_text);
    @import("../../core/fuzz.zig").stress(200_000, &.{&fuzz_seed}, root, fuzzOne);
}

test "REQ-MOVE-02 schema parser fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var b: [96]u8 = undefined;
            const n = smith.slice(&b);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            _ = parse(arena.allocator(), b[0..n]) catch {};
        }
    }.f, .{});
}
