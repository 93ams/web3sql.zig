//! Move TypeTag strings (`vector<u8>`, `0x2::coin::Coin<0x2::sui::SUI>`), parsed without allocation.
//! `parse` validates the whole string once; the views it returns are slices of the input.
const std = @import("std");
const address = @import("address.zig");
const Out = @import("out.zig").Out;

pub const max_depth = 32;

pub const TypeTagError = error{
    InvalidTypeTag,
    InvalidAddress,
    InvalidIdentifier,
    TooDeep,
    BufferTooSmall,
};

pub const Primitive = enum { bool, u8, u16, u32, u64, u128, u256, address, signer };

pub const StructView = struct {
    /// Address text as written (`0x2`), not normalised.
    address: []const u8,
    module: []const u8,
    name: []const u8,
    /// Text between `<` and `>`, empty without generics.
    generics: []const u8,

    pub fn genericIter(self: StructView) GenericIter {
        return .{ .src = self.generics };
    }

    pub fn addressBytes(self: StructView) address.AddressError!address.MoveAddress {
        return address.parseCanonicalAddress(self.address);
    }
};

pub const Tag = union(enum) {
    primitive: Primitive,
    /// Element type text.
    vector: []const u8,
    @"struct": StructView,
};

/// Walks the comma separated type arguments of an already validated `StructView`.
pub const GenericIter = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn next(self: *GenericIter) TypeTagError!?Tag {
        if (self.pos >= self.src.len) return null;
        const r = try parseOne(self.src[self.pos..], 0);
        self.pos += r.len;
        if (self.pos < self.src.len) { // validated text: ',' then optional spaces
            self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] == ' ') self.pos += 1;
        }
        return r.tag;
    }
};

/// Parses a complete type string; surrounding spaces are ignored, nothing may follow.
pub fn parse(src: []const u8) TypeTagError!Tag {
    const s = std.mem.trim(u8, src, " ");
    const r = try parseOne(s, 0);
    if (r.len != s.len) return TypeTagError.InvalidTypeTag;
    return r.tag;
}

const Parsed = struct { tag: Tag, len: usize };

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn identLen(s: []const u8) usize {
    if (s.len == 0 or !isIdentStart(s[0])) return 0;
    var i: usize = 1;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
    return i;
}

fn parseOne(s: []const u8, depth: usize) TypeTagError!Parsed {
    if (depth > max_depth) return TypeTagError.TooDeep;
    if (s.len >= 2 and s[0] == '0' and s[1] == 'x') return parseStruct(s, depth);
    const n = identLen(s);
    const word = s[0..n];
    if (std.meta.stringToEnum(Primitive, word)) |p| return .{ .tag = .{ .primitive = p }, .len = n };
    if (std.mem.eql(u8, word, "vector") and n < s.len and s[n] == '<') {
        const inner = try parseOne(s[n + 1 ..], depth + 1);
        const end = n + 1 + inner.len;
        if (end >= s.len or s[end] != '>') return TypeTagError.InvalidTypeTag;
        return .{ .tag = .{ .vector = s[n + 1 .. end] }, .len = end + 1 };
    }
    return TypeTagError.InvalidTypeTag;
}

fn parseStruct(s: []const u8, depth: usize) TypeTagError!Parsed {
    const a_end = std.mem.indexOf(u8, s, "::") orelse return TypeTagError.InvalidTypeTag;
    _ = address.parseCanonicalAddress(s[0..a_end]) catch return TypeTagError.InvalidAddress;
    var pos = a_end + 2;
    const m = identLen(s[pos..]);
    if (m == 0) return TypeTagError.InvalidIdentifier;
    const module = s[pos..][0..m];
    pos += m;
    if (!std.mem.startsWith(u8, s[pos..], "::")) return TypeTagError.InvalidTypeTag;
    pos += 2;
    const nl = identLen(s[pos..]);
    if (nl == 0) return TypeTagError.InvalidIdentifier;
    const name = s[pos..][0..nl];
    pos += nl;
    var generics: []const u8 = "";
    if (pos < s.len and s[pos] == '<') {
        const start = pos + 1;
        pos = start;
        while (true) {
            const r = try parseOne(s[pos..], depth + 1);
            pos += r.len;
            if (pos >= s.len) return TypeTagError.InvalidTypeTag;
            if (s[pos] == '>') break;
            if (s[pos] != ',') return TypeTagError.InvalidTypeTag;
            pos += 1;
            while (pos < s.len and s[pos] == ' ') pos += 1;
        }
        generics = s[start..pos];
        pos += 1;
    }
    return .{ .tag = .{ .@"struct" = .{ .address = s[0..a_end], .module = module, .name = name, .generics = generics } }, .len = pos };
}

/// Writes the canonical string: addresses in `style`, `, ` between type arguments, no other spaces.
pub fn render(src: []const u8, style: address.Style, dest: []u8) TypeTagError![]const u8 {
    var out = Out{ .buf = dest };
    try renderTag(&out, try parse(src), style, 0);
    return out.written();
}

fn renderTag(out: *Out, tag: Tag, style: address.Style, depth: usize) TypeTagError!void {
    if (depth > max_depth) return TypeTagError.TooDeep;
    switch (tag) {
        .primitive => |p| try out.put(@tagName(p)),
        .vector => |inner| {
            try out.put("vector<");
            try renderTag(out, try parse(inner), style, depth + 1);
            try out.put(">");
        },
        .@"struct" => |sv| {
            try address.write(out, sv.addressBytes() catch return TypeTagError.InvalidAddress, style);
            try out.put("::");
            try out.put(sv.module);
            try out.put("::");
            try out.put(sv.name);
            var it = sv.genericIter();
            var first = true;
            while (try it.next()) |g| {
                try out.put(if (first) "<" else ", ");
                first = false;
                try renderTag(out, g, style, depth + 1);
            }
            if (!first) try out.put(">");
        },
    }
}

// Vectors: MystenLabs/ts-sdks type-tag-serializer test (type-tag-serializer.test.ts, fetched).
const sui_nested = "0x2::balance::Supply<0x72de5feb63c0ab6ed1cda7e5b367f3d0a999add7::amm::LP<0x2::sui::SUI, 0xfee024a3c0c03ada5cdbda7d0e8b68802e6dec80::example_coin::EXAMPLE_COIN>>";

test "REQ-MOVE-01 parse nested struct view" {
    const t = try parse(sui_nested);
    const sv = t.@"struct";
    try std.testing.expectEqualStrings("0x2", sv.address);
    try std.testing.expectEqualStrings("balance", sv.module);
    try std.testing.expectEqualStrings("Supply", sv.name);
    var it = sv.genericIter();
    const lp = (try it.next()).?.@"struct";
    try std.testing.expectEqualStrings("0x72de5feb63c0ab6ed1cda7e5b367f3d0a999add7", lp.address);
    try std.testing.expectEqualStrings("amm", lp.module);
    try std.testing.expectEqualStrings("LP", lp.name);
    try std.testing.expect((try it.next()) == null);
    var lit = lp.genericIter();
    const sui = (try lit.next()).?.@"struct";
    try std.testing.expectEqualStrings("SUI", sui.name);
    const ex = (try lit.next()).?.@"struct";
    try std.testing.expectEqualStrings("EXAMPLE_COIN", ex.name);
    try std.testing.expect((try lit.next()) == null);

    const plain = (try parse("0x72de5feb63c0ab6ed1cda7e5b367f3d0a999add7::foo::FOO")).@"struct";
    try std.testing.expectEqualStrings("", plain.generics);
    try std.testing.expectEqualStrings("u8", (try parse(" vector<u8> ")).vector);
    try std.testing.expectEqual(Primitive.u256, (try parse("u256")).primitive);
}

test "REQ-MOVE-01 render canonical" {
    var buf: [512]u8 = undefined;
    // Same string back in short form (Sui TS tagToString vector).
    try std.testing.expectEqualStrings(sui_nested[0..], try render(sui_nested, .short, &buf));
    // aptos-ts-sdk typeTag.test.ts: toString of 0x1::some_module::SomeResource<u8>.
    try std.testing.expectEqualStrings("0x1::some_module::SomeResource<u8>", try render("0x0001::some_module::SomeResource<u8>", .aptos, &buf));
    try std.testing.expectEqualStrings("vector<0x1::string::String>", try render("vector<0x1::string::String>", .aptos, &buf));
    try std.testing.expectEqualStrings(
        "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI",
        try render("0x2::sui::SUI", .sui, &buf),
    );
    try std.testing.expectError(TypeTagError.BufferTooSmall, render(sui_nested, .short, buf[0..20]));
}

// Invalid inputs adapted from aptos-ts-sdk typeTagParser.test.ts (fetched).
test "REQ-MOVE-01 rejects malformed type tags" {
    const bad = [_][]const u8{
        "",                           "8",                          "addr",                     "T1",
        "0x1:tag::Tag",               "0x1::tag:Tag",               "0x1::tag::Tag<8>",         "0x1::tag::Tag <u8>",
        "0x1::tag::Tag<<u8>",         "0x1::tag::Tag<u8>>",         "u8, u8",                   "u8,u8",
        "0x1::tag::Tag<u8<u8>>",      "0x1::tag::Tag<u8><u8>",      "0x1<u8>::tag::Tag<u8>",    "0x1::tag<u8>::Tag<u8>",
        "0x1::tag::Tag<>",            "0x1::tag::Tag<,>",           "0x1::tag::Tag<u8,>",       "0x1::tag::Tag<,u8>",
        "notAnAddress::tag::Tag<u8>", "0x1::not-a-module::Tag<u8>", "0x1::tag::Not-A-Name<u8>", "vector<>",
        "vector<u8",                  "vector",                     "0x::a::B",                 "0x1::a::B<u8 u8>",
    };
    for (bad) |s| try std.testing.expect(std.meta.isError(parse(s)));
    try std.testing.expectError(TypeTagError.InvalidAddress, parse("0xzz::a::B"));
}

test "REQ-MOVE-01 depth limit 32" {
    var buf: [512]u8 = undefined;
    const build = struct {
        fn f(b: []u8, depth: usize) []const u8 {
            var i: usize = 0;
            for (0..depth) |_| {
                @memcpy(b[i..][0..7], "vector<");
                i += 7;
            }
            @memcpy(b[i..][0..2], "u8");
            i += 2;
            for (0..depth) |_| {
                b[i] = '>';
                i += 1;
            }
            return b[0..i];
        }
    }.f;
    _ = try parse(build(&buf, max_depth));
    try std.testing.expectError(TypeTagError.TooDeep, parse(build(&buf, max_depth + 1)));
    var big: [4096]u8 = undefined;
    @memset(&big, '<');
    try std.testing.expect(std.meta.isError(parse(&big)));
}

fn fuzzOne(_: void, bytes: []const u8) void {
    var buf: [256]u8 = undefined;
    _ = render(bytes, .aptos, &buf) catch return;
    const t = parse(bytes) catch return;
    if (t == .@"struct") {
        var it = t.@"struct".genericIter();
        while (it.next() catch return) |_| {}
    }
}

test "REQ-MOVE-01 typetag fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var b: [128]u8 = undefined;
            const n = smith.slice(&b);
            fuzzOne({}, b[0..n]);
        }
    }.f, .{});
}

test "REQ-MOVE-01 typetag stress" {
    @import("../../core/fuzz.zig").stress(200_000, &.{ sui_nested, "vector<vector<0x1::a::B<u8, u64>>>", "0x1::option::Option<u8>" }, {}, fuzzOne);
}
