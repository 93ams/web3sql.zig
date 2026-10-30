//! Text form of a Borsh schema, the SQL-facing input to `borsh.renderJson`.
//! Grammar: a `borsh.Prim` name | vec<T> | option<T> | [T;N] | {name:T,...}
const std = @import("std");
const borsh = @import("borsh.zig");
const fuzz = @import("../../core/fuzz.zig");

pub const SchemaError = error{ InvalidSchema, OutOfMemory };

const MAX_DEPTH = 32;

const Parser = struct {
    a: std.mem.Allocator,
    s: []const u8,
    at: usize = 0,

    fn skipSpaces(self: *Parser) void {
        while (self.at < self.s.len and self.s[self.at] == ' ') self.at += 1;
    }

    fn eat(self: *Parser, c: u8) bool {
        self.skipSpaces();
        if (self.at >= self.s.len or self.s[self.at] != c) return false;
        self.at += 1;
        return true;
    }

    fn word(self: *Parser) []const u8 {
        self.skipSpaces();
        const start = self.at;
        while (self.at < self.s.len and (std.ascii.isAlphanumeric(self.s[self.at]) or self.s[self.at] == '_')) self.at += 1;
        return self.s[start..self.at];
    }

    fn inner(self: *Parser, depth: usize) SchemaError!borsh.Type {
        if (!self.eat('<')) return error.InvalidSchema;
        const t = try self.ty(depth + 1);
        if (!self.eat('>')) return error.InvalidSchema;
        return t;
    }

    fn ty(self: *Parser, depth: usize) SchemaError!borsh.Type {
        if (depth >= MAX_DEPTH) return error.InvalidSchema;
        if (self.eat('[')) {
            const elem = try self.ty(depth + 1);
            if (!self.eat(';')) return error.InvalidSchema;
            const len = std.fmt.parseInt(u32, self.word(), 10) catch return error.InvalidSchema;
            if (!self.eat(']')) return error.InvalidSchema;
            return borsh.Type.arrayOf(self.a, elem, len);
        }
        if (self.eat('{')) {
            var fields: std.ArrayList(borsh.Field) = .empty;
            while (true) {
                const name = self.word();
                if (name.len == 0 or !self.eat(':')) return error.InvalidSchema;
                try fields.append(self.a, .{ .name = name, .ty = try self.ty(depth + 1) });
                if (self.eat('}')) break;
                if (!self.eat(',')) return error.InvalidSchema;
            }
            return .{ .record = try fields.toOwnedSlice(self.a) };
        }
        const name = self.word();
        if (std.mem.eql(u8, name, "vec")) return borsh.Type.vecOf(self.a, try self.inner(depth));
        if (std.mem.eql(u8, name, "option")) return borsh.Type.optionOf(self.a, try self.inner(depth));
        return .{ .prim = std.meta.stringToEnum(borsh.Prim, name) orelse return error.InvalidSchema };
    }
};

/// Parses `text`. Field names borrow from a copy made in `a`, so use an arena.
pub fn parse(a: std.mem.Allocator, text: []const u8) SchemaError!*const borsh.Type {
    var p: Parser = .{ .a = a, .s = try a.dupe(u8, text) };
    const root = try a.create(borsh.Type);
    root.* = try p.ty(0);
    p.skipSpaces();
    if (p.at != p.s.len) return error.InvalidSchema;
    return root;
}

test "REQ-SVM-02 borsh text schema decodes to JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try parse(arena.allocator(), "{amount: u64, tag: option<u8>, ids: vec<u16>, raw: [u8;2]}");
    const bytes = [_]u8{ 5, 0, 0, 0, 0, 0, 0, 0, 1, 9, 2, 0, 0, 0, 1, 0, 2, 0, 0xab, 0xcd };
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        \\{"amount":5,"tag":9,"ids":[1,2],"raw":"0xabcd"}
    , try borsh.renderJson(schema, &bytes, &out));
}

test "borsh text schema rejects malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "nope", "vec<", "vec<u8", "[u8]", "[u8;x]", "{a}", "{a:u8", "u8 u8", "{:u8}" }) |bad| {
        try std.testing.expectError(error.InvalidSchema, parse(arena.allocator(), bad));
    }
    var deep: [400]u8 = @splat('[');
    try std.testing.expectError(error.InvalidSchema, parse(arena.allocator(), &deep));
}

test "borsh text schema fuzz" {
    fuzz.stress(200_000, &.{ "{a:vec<option<[u8;3]>>,b:string}", "[vec<u8>;4]" }, {}, struct {
        fn f(_: void, bytes: []const u8) void {
            var buf: [16 * 1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            _ = parse(fba.allocator(), bytes) catch {};
        }
    }.f);
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var input: [128]u8 = undefined;
            var buf: [16 * 1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            _ = parse(fba.allocator(), input[0..smith.slice(&input)]) catch {};
        }
    }.f, .{});
}
