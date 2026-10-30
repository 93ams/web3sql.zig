//! Anchor IDL JSON -> runtime Borsh schema. Kept apart from `borsh.zig` so targets that cannot
//! afford `std.json` (WASM) leave it out. Everything here runs at bind time and allocates from
//! the caller's allocator (pass an arena); decoding afterwards allocates nothing.
//! Handles both IDL generations: legacy (<0.30, `publicKey`, `defined: "X"`, no discriminators)
//! and current (`pubkey`, `defined: {name}`, explicit `discriminator`).
//! shortcut: generics, hashMap/hashSet and coption are rejected with UnsupportedType; add when a real IDL needs them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const borsh = @import("borsh.zig");
const anchor = @import("anchor.zig");

const Type = borsh.Type;
const Field = borsh.Field;

pub const IdlError = Allocator.Error || error{
    InvalidJson,
    JsonTooDeep,
    MissingField,
    UnknownType,
    UnsupportedType,
    RecursiveType,
    TypeTooDeep,
    InvalidDiscriminator,
    NameTooLong,
};

pub const DecodeError = borsh.BorshError || anchor.AnchorError || error{ UnknownDiscriminator, UnsupportedType };

pub const MAX_JSON_DEPTH = 64;
const MAX_TYPE_DEPTH = 32;

/// One instruction (args), account or event: discriminator prefix plus the schema of what follows it.
/// `ty` is null when the schema uses a construct this parser rejects (generics, maps); decoding it yields UnsupportedType
/// while the rest of the IDL stays usable.
pub const Item = struct { name: []const u8, disc: []const u8, ty: ?Type };

pub const Idl = struct {
    instructions: []const Item,
    accounts: []const Item,
    events: []const Item,

    pub fn parse(a: Allocator, json: []const u8) IdlError!Idl {
        try checkDepth(json);
        const root = std.json.parseFromSliceLeaky(Value, a, json, .{}) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJson,
        };
        if (root != .object) return error.InvalidJson;
        var res = Resolver{ .a = a, .defs = try collectDefs(a, root.object.get("types"), root.object.get("accounts")) };
        return .{
            .instructions = try res.items(root.object.get("instructions"), "global", .instruction),
            .accounts = try res.items(root.object.get("accounts"), "account", .account),
            .events = try res.items(root.object.get("events"), "event", .event),
        };
    }

    /// `{"name":...,"data":{...}}` for instruction data (8-byte discriminator + Borsh args); no trailing bytes allowed.
    pub fn decodeInstruction(self: Idl, data: []const u8, dest: []u8) DecodeError![]const u8 {
        return decodeItem(self.instructions, data, dest, true);
    }

    /// Same for an Anchor event payload (discriminator + Borsh), e.g. from `anchor.decodeProgramData`.
    pub fn decodeEvent(self: Idl, data: []const u8, dest: []u8) DecodeError![]const u8 {
        return decodeItem(self.events, data, dest, true);
    }

    /// Account data may be zero padded to the allocated size, so trailing bytes are ignored.
    pub fn decodeAccount(self: Idl, data: []const u8, dest: []u8) DecodeError![]const u8 {
        return decodeItem(self.accounts, data, dest, false);
    }

    /// A raw `Program data: <base64>` log line straight to event JSON. `scratch` holds the decoded bytes.
    pub fn decodeEventLog(self: Idl, line: []const u8, scratch: []u8, dest: []u8) DecodeError![]const u8 {
        return self.decodeEvent(try anchor.decodeProgramData(line, scratch), dest);
    }
};

fn decodeItem(items: []const Item, data: []const u8, dest: []u8, strict: bool) DecodeError![]const u8 {
    for (items) |it| {
        if (!std.mem.startsWith(u8, data, it.disc)) continue;
        const ty = it.ty orelse return error.UnsupportedType;
        var r = borsh.BorshReader.init(data[it.disc.len..]);
        var out = borsh.JsonOut.init(dest);
        try out.put("{\"name\":");
        try out.string(it.name);
        try out.put(",\"data\":");
        try borsh.writeValue(&ty, &r, &out, 0);
        try out.put("}");
        if (strict and r.remaining() != 0) return error.TrailingBytes;
        return out.written();
    }
    return error.UnknownDiscriminator;
}

/// std.json.Value parsing recurses, so bound nesting before it sees hostile input.
fn checkDepth(json: []const u8) IdlError!void {
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    for (json) |c| {
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[', '{' => {
                depth += 1;
                if (depth > MAX_JSON_DEPTH) return error.JsonTooDeep;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
}

const Def = struct {
    name: []const u8,
    json: Value,
    state: enum { todo, busy, done } = .todo,
    out: Type = undefined,
};

/// Named types come from `types`; legacy IDLs also let `defined` point at an account with an inline `type`.
fn collectDefs(a: Allocator, types: ?Value, accounts: ?Value) IdlError![]Def {
    const ts = try list(types);
    const accs = try list(accounts);
    const defs = try a.alloc(Def, ts.len + accs.len);
    var n: usize = 0;
    for (ts) |v| {
        defs[n] = .{ .name = try str(v, "name"), .json = v };
        n += 1;
    }
    for (accs) |v| {
        if (field(v, "type") == null) continue;
        defs[n] = .{ .name = try str(v, "name"), .json = v };
        n += 1;
    }
    return defs[0..n];
}

fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

fn str(v: Value, key: []const u8) IdlError![]const u8 {
    const s = field(v, key) orelse return error.MissingField;
    if (s != .string) return error.InvalidJson;
    return s.string;
}

fn list(v: ?Value) IdlError![]const Value {
    const x = v orelse return &.{};
    if (x != .array) return error.InvalidJson;
    return x.array.items;
}

const Kind = enum { instruction, account, event };

const Resolver = struct {
    a: Allocator,
    defs: []Def,

    fn items(self: *Resolver, v: ?Value, prefix: []const u8, kind: Kind) IdlError![]const Item {
        const arr = try list(v);
        const out = try self.a.alloc(Item, arr.len);
        for (arr, out) |x, *o| {
            const name = try str(x, "name");
            const ty: ?Type = self.itemType(x, name, kind) catch |e| switch (e) {
                error.UnsupportedType => null,
                else => return e,
            };
            o.* = .{ .name = name, .disc = try self.disc(x, prefix, name, kind), .ty = ty };
        }
        return out;
    }

    fn itemType(self: *Resolver, x: Value, name: []const u8, kind: Kind) IdlError!Type {
        return switch (kind) {
            .instruction => .{ .record = try self.fields(field(x, "args")) },
            // Legacy events carry fields inline, legacy accounts an inline `type`; current IDLs point into `types`.
            .event => if (field(x, "fields")) |f| .{ .record = try self.fields(f) } else try self.named(name),
            .account => if (field(x, "type")) |t| try self.body(t, 0) else try self.named(name),
        };
    }

    fn disc(self: *Resolver, x: Value, prefix: []const u8, name: []const u8, kind: Kind) IdlError![]const u8 {
        if (field(x, "discriminator")) |d| {
            if (d != .array or d.array.items.len == 0 or d.array.items.len > 64) return error.InvalidDiscriminator;
            const out = try self.a.alloc(u8, d.array.items.len);
            for (d.array.items, out) |b, *o| {
                if (b != .integer or b.integer < 0 or b.integer > 255) return error.InvalidDiscriminator;
                o.* = @intCast(b.integer);
            }
            return out;
        }
        var snake: [anchor.MAX_NAME_LEN]u8 = undefined;
        const n = if (kind == .instruction) try toSnake(name, &snake) else name;
        const h = anchor.computeDiscriminator(n, prefix) catch return error.NameTooLong;
        return try self.a.dupe(u8, &h);
    }

    fn named(self: *Resolver, name: []const u8) IdlError!Type {
        for (self.defs, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return self.def(i, 0);
        return error.UnknownType;
    }

    fn def(self: *Resolver, i: usize, depth: usize) IdlError!Type {
        const d = &self.defs[i];
        switch (d.state) {
            .done => return d.out,
            .busy => return error.RecursiveType,
            .todo => {},
        }
        if (field(d.json, "generics")) |g| if (g != .array or g.array.items.len != 0) return error.UnsupportedType;
        d.state = .busy;
        errdefer d.state = .todo;
        d.out = try self.body(field(d.json, "type") orelse return error.MissingField, depth);
        d.state = .done;
        return d.out;
    }

    /// `{"kind":"struct"|"enum"|"type", ...}`
    fn body(self: *Resolver, v: Value, depth: usize) IdlError!Type {
        if (depth > MAX_TYPE_DEPTH) return error.TypeTooDeep;
        const kind = try str(v, "kind");
        if (std.mem.eql(u8, kind, "struct")) return .{ .record = try self.fields(field(v, "fields")) };
        if (std.mem.eql(u8, kind, "type")) return self.resolve(field(v, "alias") orelse return error.MissingField, depth + 1);
        if (!std.mem.eql(u8, kind, "enum")) return error.UnsupportedType;
        const vs = try list(field(v, "variants"));
        const out = try self.a.alloc(borsh.Variant, vs.len);
        for (vs, out) |x, *o| o.* = .{ .name = try str(x, "name"), .fields = try self.fields(field(x, "fields")) };
        return .{ .enumeration = out };
    }

    /// Named fields `[{name,type}]` or tuple fields `[type]` (empty names); absent means unit.
    fn fields(self: *Resolver, v: ?Value) IdlError![]const Field {
        const arr = try list(v);
        const out = try self.a.alloc(Field, arr.len);
        for (arr, out) |x, *o| {
            if (field(x, "type")) |t| {
                o.* = .{ .name = try str(x, "name"), .ty = try self.resolve(t, 0) };
            } else o.* = .{ .name = "", .ty = try self.resolve(x, 0) };
        }
        return out;
    }

    fn resolve(self: *Resolver, v: Value, depth: usize) IdlError!Type {
        if (depth > MAX_TYPE_DEPTH) return error.TypeTooDeep;
        switch (v) {
            .string => |s| return primitive(s) orelse (if (std.mem.eql(u8, s, "bytes")) self.bytes() else error.UnknownType),
            .object => {
                if (field(v, "vec")) |t| return Type.vecOf(self.a, try self.resolve(t, depth + 1));
                if (field(v, "option")) |t| return Type.optionOf(self.a, try self.resolve(t, depth + 1));
                if (field(v, "array")) |t| {
                    if (t != .array or t.array.items.len != 2 or t.array.items[1] != .integer) return error.UnsupportedType;
                    const n = std.math.cast(u32, t.array.items[1].integer) orelse return error.InvalidJson;
                    return Type.arrayOf(self.a, try self.resolve(t.array.items[0], depth + 1), n);
                }
                if (field(v, "tuple")) |t| {
                    const arr = try list(t);
                    const out = try self.a.alloc(Field, arr.len);
                    for (arr, out) |x, *o| o.* = .{ .name = "", .ty = try self.resolve(x, depth + 1) };
                    return .{ .record = out };
                }
                if (field(v, "defined")) |t| {
                    const name = if (t == .string) t.string else try str(t, "name");
                    if (field(t, "generics") != null) return error.UnsupportedType;
                    for (self.defs, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return self.def(i, depth + 1);
                    return error.UnknownType;
                }
                return error.UnsupportedType;
            },
            else => return error.InvalidJson,
        }
    }

    fn bytes(self: *Resolver) IdlError!Type {
        return Type.vecOf(self.a, .{ .prim = .u8 });
    }
};

fn primitive(name: []const u8) ?Type {
    if (std.mem.eql(u8, name, "publicKey") or std.mem.eql(u8, name, "pubkey")) return .{ .prim = .pubkey };
    return if (std.meta.stringToEnum(borsh.Prim, name)) |p| .{ .prim = p } else null;
}

/// camelCase -> snake_case, the way Anchor derives instruction discriminators from legacy IDL names.
/// shortcut: plain ASCII word splitting, not heck's full acronym rules; add if a legacy IDL mismatches.
fn toSnake(name: []const u8, dest: []u8) IdlError![]const u8 {
    var n: usize = 0;
    for (name, 0..) |c, i| {
        const upper = std.ascii.isUpper(c);
        const need = @as(usize, if (upper and i > 0 and !std.ascii.isUpper(name[i - 1]) and name[i - 1] != '_') 2 else 1);
        if (n + need > dest.len) return error.NameTooLong;
        if (need == 2) {
            dest[n] = '_';
            n += 1;
        }
        dest[n] = std.ascii.toLower(c);
        n += 1;
    }
    return dest[0..n];
}

const external_json = @embedFile("testdata/external.json");
const external_legacy_json = @embedFile("testdata/external_legacy.json");
const wide_json = @embedFile("testdata/wide_integers.json");
const raydium_json = @embedFile("testdata/raydium_clmm_trimmed.json");

fn expectDecode(want: []const u8, got: DecodeError![]const u8) !void {
    try std.testing.expectEqualStrings(want, try got);
}

test "REQ-SVM-02 idl current format: explicit discriminators" {
    // Source: coral-xyz/anchor tests/declare-program/idls/external.json.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idl = try Idl.parse(arena.allocator(), external_json);
    var buf: [256]u8 = undefined;
    // `update` discriminator [219,200,88,176,158,63,253,127] + u32 value 7.
    try expectDecode("{\"name\":\"update\",\"data\":{\"value\":7}}", idl.decodeInstruction(&.{ 219, 200, 88, 176, 158, 63, 253, 127, 7, 0, 0, 0 }, &buf));
    // `init` takes no arguments.
    try expectDecode("{\"name\":\"init\",\"data\":{}}", idl.decodeInstruction(&.{ 220, 59, 207, 236, 108, 250, 47, 100 }, &buf));
    // MyEvent [96,184,197,243,139,2,90,148] and MyAccount [246,28,6,87,251,45,50,42], resolved through `types`.
    try expectDecode("{\"name\":\"MyEvent\",\"data\":{\"value\":9}}", idl.decodeEvent(&.{ 96, 184, 197, 243, 139, 2, 90, 148, 9, 0, 0, 0 }, &buf));
    try expectDecode("{\"name\":\"MyAccount\",\"data\":{\"field\":1}}", idl.decodeAccount(&.{ 246, 28, 6, 87, 251, 45, 50, 42, 1, 0, 0, 0, 0, 0, 0, 0 }, &buf));
    // Generic-typed instructions are kept but not decodable.
    const generic = [_]u8{ 2, 200, 154, 199, 119, 208, 171, 225 };
    try std.testing.expectError(error.UnsupportedType, idl.decodeInstruction(&generic, &buf));
    // Failure modes.
    try std.testing.expectError(error.UnknownDiscriminator, idl.decodeInstruction(&.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &buf));
    try std.testing.expectError(error.TrailingBytes, idl.decodeInstruction(&.{ 219, 200, 88, 176, 158, 63, 253, 127, 7, 0, 0, 0, 0 }, &buf));
    try std.testing.expectError(error.UnexpectedEndOfBuffer, idl.decodeInstruction(&.{ 219, 200, 88, 176, 158, 63, 253, 127, 7 }, &buf));
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, idl.decodeInstruction(&.{ 219, 200, 88, 176, 158, 63, 253, 127, 7, 0, 0, 0 }, &tiny));
}

test "REQ-SVM-02 idl legacy format: computed discriminators" {
    // Source: coral-xyz/anchor tests/declare-program/idls/external_legacy.json (no discriminators, camelCase names).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idl = try Idl.parse(arena.allocator(), external_legacy_json);
    var buf: [256]u8 = undefined;
    // Legacy `update` hashes "global:update", which the current IDL lists as [219,200,88,...].
    try expectDecode("{\"name\":\"update\",\"data\":{\"value\":7}}", idl.decodeInstruction(&.{ 219, 200, 88, 176, 158, 63, 253, 127, 7, 0, 0, 0 }, &buf));
    // `updateComposite` -> "global:update_composite" = [26,42,201,224,121,60,188,220] in the current IDL.
    try expectDecode("{\"name\":\"updateComposite\",\"data\":{\"value\":1}}", idl.decodeInstruction(&.{ 26, 42, 201, 224, 121, 60, 188, 220, 1, 0, 0, 0 }, &buf));
    // Legacy event with inline fields, legacy account with inline type; same hashes as the current IDL.
    try expectDecode("{\"name\":\"MyEvent\",\"data\":{\"value\":9}}", idl.decodeEvent(&.{ 96, 184, 197, 243, 139, 2, 90, 148, 9, 0, 0, 0 }, &buf));
    try expectDecode("{\"name\":\"MyAccount\",\"data\":{\"field\":1}}", idl.decodeAccount(&.{ 246, 28, 6, 87, 251, 45, 50, 42, 1, 0, 0, 0 }, &buf));
    // `defined` argument (legacy string form).
    try std.testing.expect(idl.instructions[3].ty.?.record[0].ty == .record);
}

test "REQ-SVM-02 idl wide integers" {
    // Source: coral-xyz/anchor tests/declare-program/idls/wide_integers.json (u256/i256).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idl = try Idl.parse(arena.allocator(), wide_json);
    var raw: [8 + 64]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ @as([64]u8, @splat(0));
    raw[8] = 5;
    @memset(raw[40..72], 0xff); // i256 -1
    var buf: [256]u8 = undefined;
    try expectDecode("{\"name\":\"store_wide\",\"data\":{\"wide\":{\"unsigned\":5,\"signed\":-1}}}", idl.decodeInstruction(&raw, &buf));
}

test "REQ-SVM-02 raydium clmm swap instruction and event" {
    // Source: Raydium CLMM IDL as vendored by anchor tests/declare-program/idls/amm_v3.json, trimmed to `swap` + SwapEvent
    // (see testdata/raydium_clmm_trimmed.json). Discriminators f8c69e91e17587c8 / 40c6cde8260871e2 were also recomputed
    // independently with Python hashlib: sha256("global:swap") and sha256("event:SwapEvent").
    // Note: the byte payloads are hand-built per the IDL (the parquet sample holds no Raydium or Orca swap).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idl = try Idl.parse(arena.allocator(), raydium_json);
    try std.testing.expectEqualSlices(u8, &.{ 248, 198, 158, 145, 225, 117, 135, 200 }, idl.instructions[0].disc);
    var ix: [8 + 8 + 8 + 16 + 1]u8 = .{ 248, 198, 158, 145, 225, 117, 135, 200 } ++ @as([33]u8, @splat(0));
    std.mem.writeInt(u64, ix[8..16], 1_000_000, .little);
    std.mem.writeInt(u64, ix[16..24], 990_000, .little);
    std.mem.writeInt(u128, ix[24..40], 79228162514264337593543950336, .little); // 2^96, a price limit above 2^53
    ix[40] = 1;
    var buf: [1024]u8 = undefined;
    try expectDecode("{\"name\":\"swap\",\"data\":{\"amount\":1000000,\"other_amount_threshold\":990000," ++
        "\"sqrt_price_limit_x64\":\"79228162514264337593543950336\",\"is_base_input\":true}}", idl.decodeInstruction(&ix, &buf));

    // emit! event via a `Program data:` log line: base64(disc || borsh(SwapEvent)).
    var ev: [8 + 4 * 32 + 4 * 8 + 1 + 16 + 16 + 4]u8 = @splat(0);
    @memcpy(ev[0..8], &[_]u8{ 64, 198, 205, 232, 38, 8, 113, 226 });
    ev[8 + 32] = 1; // sender = 0x01 00.. (pool_state is zero)
    std.mem.writeInt(u64, ev[8 + 128 ..][0..8], 5, .little); // amount_0
    ev[8 + 160] = 1; // zero_for_one
    std.mem.writeInt(i32, ev[ev.len - 4 ..][0..4], -100, .little); // tick
    var line: [400]u8 = undefined;
    @memcpy(line[0..14], "Program data: ");
    const b64 = @import("../../core/encodings/base64.zig");
    const enc = try b64.encode(.standard, &ev, line[14..]);
    var scratch: [256]u8 = undefined;
    const out = try idl.decodeEventLog(line[0 .. 14 + enc.len], &scratch, &buf);
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"name\":\"SwapEvent\",\"data\":{\"pool_state\":\"11111111111111111111111111111111\",\"sender\":\""));
    try std.testing.expect(std.mem.endsWith(u8, out, "\"amount_0\":5,\"transfer_fee_0\":0,\"amount_1\":0,\"transfer_fee_1\":0,\"zero_for_one\":true,\"sqrt_price_x64\":0,\"liquidity\":0,\"tick\":-100}}"));
}

test "REQ-SVM-02 idl rejects malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidJson, Idl.parse(a, "not json"));
    try std.testing.expectError(error.InvalidJson, Idl.parse(a, "[]"));
    try std.testing.expectError(error.UnknownType, Idl.parse(a, "{\"instructions\":[{\"name\":\"a\",\"args\":[{\"name\":\"x\",\"type\":\"u7\"}]}]}"));
    try std.testing.expectError(error.UnknownType, Idl.parse(a, "{\"instructions\":[{\"name\":\"a\",\"args\":[{\"name\":\"x\",\"type\":{\"defined\":\"Nope\"}}]}]}"));
    try std.testing.expectError(error.RecursiveType, Idl.parse(a,
        \\{"instructions":[{"name":"a","args":[{"name":"x","type":{"defined":"T"}}]}],
        \\ "types":[{"name":"T","type":{"kind":"struct","fields":[{"name":"n","type":{"defined":"T"}}]}}]}
    ));
    try std.testing.expectError(error.InvalidDiscriminator, Idl.parse(a, "{\"instructions\":[{\"name\":\"a\",\"discriminator\":[256]}]}"));
    const map = try Idl.parse(a, "{\"instructions\":[{\"name\":\"a\",\"args\":[{\"name\":\"x\",\"type\":{\"hashMap\":[\"u8\",\"u8\"]}}]}]}");
    try std.testing.expect(map.instructions[0].ty == null);
    var deep: [MAX_JSON_DEPTH + 1]u8 = @splat('[');
    try std.testing.expectError(error.JsonTooDeep, Idl.parse(a, &deep));
}

fn fuzzParse(_: void, bytes: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const idl = Idl.parse(arena.allocator(), bytes) catch return;
    var buf: [256]u8 = undefined;
    _ = idl.decodeInstruction(bytes, &buf) catch {};
}

test "REQ-SVM-02 idl fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [512]u8 = undefined;
            const n = smith.slice(&buf);
            fuzzParse({}, buf[0..n]);
        }
    }.f, .{});
}

test "REQ-SVM-02 idl mutation stress" {
    const fuzz = @import("../../core/fuzz.zig");
    fuzz.stress(200_000, &.{
        "{\"instructions\":[{\"name\":\"a\",\"args\":[{\"name\":\"x\",\"type\":{\"vec\":\"u8\"}}]}],\"types\":[{\"name\":\"T\",\"type\":{\"kind\":\"enum\",\"variants\":[{\"name\":\"A\"}]}}]}",
        "{\"events\":[{\"name\":\"E\",\"fields\":[{\"name\":\"v\",\"type\":{\"array\":[\"u16\",3]}}]}]}",
    }, {}, fuzzParse);
}

test "REQ-SVM-02 idl decode mutation stress" {
    const fuzz = @import("../../core/fuzz.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idl = try Idl.parse(arena.allocator(), raydium_json);
    var ix: [41]u8 = .{ 248, 198, 158, 145, 225, 117, 135, 200 } ++ @as([33]u8, @splat(3));
    var ev: [8 + 4 * 32 + 4 * 8 + 1 + 16 + 16 + 4]u8 = @splat(2);
    @memcpy(ev[0..8], &[_]u8{ 64, 198, 205, 232, 38, 8, 113, 226 });
    fuzz.stress(200_000, &.{ &ix, &ev }, &idl, struct {
        fn f(i: *const Idl, bytes: []const u8) void {
            var buf: [1024]u8 = undefined;
            _ = i.decodeInstruction(bytes, &buf) catch {};
            _ = i.decodeEvent(bytes, &buf) catch {};
            _ = i.decodeAccount(bytes, &buf) catch {};
        }
    }.f);
}
