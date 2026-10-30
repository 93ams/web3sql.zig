//! Standard JSON ABI to the same `Fragment` the signature parser builds. Kept apart so builds that
//! never reference it (WASM) do not pull in `std.json`.
const std = @import("std");
const abi = @import("abi.zig");

pub const JsonAbiError = abi.AbiError || error{InvalidJson};

const Json = std.json.Value;

fn asArray(value: ?Json) JsonAbiError![]const Json {
    const v = value orelse return &.{};
    return if (v == .array) v.array.items else JsonAbiError.InvalidJson;
}

fn asString(value: ?Json) JsonAbiError![]const u8 {
    const v = value orelse return "";
    return if (v == .string) v.string else JsonAbiError.InvalidJson;
}

fn asBool(value: ?Json) JsonAbiError!bool {
    const v = value orelse return false;
    return if (v == .bool) v.bool else JsonAbiError.InvalidJson;
}

fn parseParams(allocator: std.mem.Allocator, items: []const Json, depth: u8) JsonAbiError![]const abi.Param {
    if (depth >= abi.MAX_DEPTH) return JsonAbiError.DepthExceeded;
    const params = try allocator.alloc(abi.Param, items.len);
    for (items, params) |item, *p| {
        if (item != .object) return JsonAbiError.InvalidJson;
        const name = try asString(item.object.get("name"));
        if (!abi.isParamName(name)) return JsonAbiError.InvalidSignature;
        p.* = .{
            .name = try allocator.dupe(u8, name),
            .ty = try parseType(allocator, item.object, depth),
            .indexed = try asBool(item.object.get("indexed")),
        };
        if (p.indexed and depth > 0) return JsonAbiError.InvalidSignature;
    }
    return params;
}

fn parseType(allocator: std.mem.Allocator, param: std.json.ObjectMap, depth: u8) JsonAbiError!abi.Type {
    const text = try asString(param.get("type"));
    const base_len = std.mem.indexOfScalar(u8, text, '[') orelse text.len;
    const base = text[0..base_len];
    const ty = if (std.mem.eql(u8, base, "tuple"))
        try abi.tupleOf(try parseParams(allocator, try asArray(param.get("components")), depth + 1))
    else
        try abi.elementary(base);
    var pos = base_len;
    const wrapped = try abi.applyArraySuffixes(allocator, ty, text, &pos);
    if (pos != text.len) return JsonAbiError.InvalidType;
    return wrapped;
}

fn parseEntry(allocator: std.mem.Allocator, entry: Json) JsonAbiError!?abi.Fragment {
    if (entry != .object) return JsonAbiError.InvalidJson;
    const obj = entry.object;
    // The ABI spec lets a function entry omit "type".
    const type_name = if (obj.contains("type")) try asString(obj.get("type")) else "function";
    const kind: abi.FragmentKind = if (std.mem.eql(u8, type_name, "event"))
        .event
    else if (std.mem.eql(u8, type_name, "function"))
        .function
    else
        return null;
    return try abi.finishFragment(
        allocator,
        kind,
        try allocator.dupe(u8, try asString(obj.get("name"))),
        try parseParams(allocator, try asArray(obj.get("inputs")), 0),
        try parseParams(allocator, try asArray(obj.get("outputs")), 0),
        try asBool(obj.get("anonymous")),
    );
}

fn parseJson(allocator: std.mem.Allocator, text: []const u8) JsonAbiError!std.json.Parsed(Json) {
    return std.json.parseFromSlice(Json, allocator, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => JsonAbiError.OutOfMemory,
        else => JsonAbiError.InvalidJson,
    };
}

/// Parses one event or function object. Other entry types (constructor, error, fallback) are `InvalidType`.
/// Allocation rules as for `abi.parseSignature`. The temporary JSON tree also comes from `allocator`.
pub fn parseFragment(allocator: std.mem.Allocator, text: []const u8) JsonAbiError!abi.Fragment {
    const parsed = try parseJson(allocator, text);
    defer parsed.deinit();
    return try parseEntry(allocator, parsed.value) orelse JsonAbiError.InvalidType;
}

/// Parses a whole ABI array, keeping events and functions and skipping every other entry type.
pub fn parseAbi(allocator: std.mem.Allocator, text: []const u8) JsonAbiError![]const abi.Fragment {
    const parsed = try parseJson(allocator, text);
    defer parsed.deinit();
    const entries = try asArray(parsed.value);
    const fragments = try allocator.alloc(abi.Fragment, entries.len);
    var n: usize = 0;
    for (entries) |entry| {
        fragments[n] = try parseEntry(allocator, entry) orelse continue;
        n += 1;
    }
    return fragments[0..n];
}

const testing = std.testing;
const core_fuzz = @import("../../core/fuzz.zig");
const hex = @import("../../core/encodings/hex.zig");
const vectors = @import("abi_vectors.zig");

// Source: ConsiderationEventsAndErrors.sol, ProjectOpenSea/seaport-types (struct fields from ConsiderationStructs.sol).
const order_fulfilled =
    \\{"anonymous":false,"name":"OrderFulfilled","type":"event","inputs":[
    \\{"indexed":false,"name":"orderHash","type":"bytes32","internalType":"bytes32"},
    \\{"indexed":true,"name":"offerer","type":"address"},
    \\{"indexed":true,"name":"zone","type":"address"},
    \\{"indexed":false,"name":"recipient","type":"address"},
    \\{"indexed":false,"name":"offer","type":"tuple[]","components":[
    \\{"name":"itemType","type":"uint8","internalType":"enum ItemType"},{"name":"token","type":"address"},
    \\{"name":"identifier","type":"uint256"},{"name":"amount","type":"uint256"}]},
    \\{"indexed":false,"name":"consideration","type":"tuple[]","components":[
    \\{"name":"itemType","type":"uint8"},{"name":"token","type":"address"},{"name":"identifier","type":"uint256"},
    \\{"name":"amount","type":"uint256"},{"name":"recipient","type":"address"}]}]}
;

test "REQ-EVM-02 JSON event fragment matches the signature parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try parseFragment(a, order_fulfilled);
    const s = try abi.parseSignature(a, "event OrderFulfilled(bytes32 orderHash, address indexed offerer, address indexed zone, address recipient, (uint8 itemType, address token, uint256 identifier, uint256 amount)[] offer, (uint8 itemType, address token, uint256 identifier, uint256 amount, address recipient)[] consideration)");
    try testing.expectEqualStrings(s.canonical, j.canonical);
    try testing.expectEqual(s.hash, j.hash);
    try testing.expectEqual(s.indexed, j.indexed);
    try testing.expectEqual(s.root.size, j.root.size);
    try testing.expectEqualStrings("offerer", j.inputs[1].name);
    // vectors.logs[3] is a live OrderFulfilled log from Seaport 1.6.
    var topic0: [32]u8 = undefined;
    _ = try hex.decodeHex(vectors.logs[3].topics[0], &topic0);
    try testing.expectEqual(topic0, j.topic0());
}

test "REQ-EVM-02 JSON real Seaport ABI, canonical form and hash match eth_utils" {
    for (vectors.fragments) |v| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const f = try parseFragment(arena.allocator(), v.json);
        try testing.expectEqualStrings(v.canonical, f.canonical);
        var want: [32]u8 = undefined;
        _ = try hex.decodeHex(v.hash, &want);
        try testing.expectEqual(want, f.hash);
    }
}

test "REQ-EVM-02 JSON function fragment, implicit type, outputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try parseFragment(arena.allocator(),
        \\{"name":"transfer","inputs":[{"name":"to","type":"address"},{"type":"uint256"}],"outputs":[{"type":"bool"}]}
    );
    try testing.expectEqual(abi.FragmentKind.function, f.kind);
    try testing.expectEqualStrings("transfer(address,uint256)", f.canonical);
    try testing.expectEqual(@as(usize, 1), f.outputs.len);
}

test "REQ-EVM-02 JSON array suffixes on tuples" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try parseFragment(arena.allocator(),
        \\{"type":"function","name":"f","inputs":[{"type":"tuple[2][]","components":[{"type":"uint8[3]"},{"type":"string"}]}]}
    );
    try testing.expectEqualStrings("f((uint8[3],string)[2][])", f.canonical);
}

test "REQ-EVM-02 JSON whole ABI skips non-event/function entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = try parseAbi(arena.allocator(),
        \\[{"type":"constructor","inputs":[]},{"type":"error","name":"E","inputs":[]},{"type":"receive"},
        \\ {"type":"event","name":"A","inputs":[]},{"type":"function","name":"b","inputs":[]}]
    );
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("b()", list[1].canonical);
}

test "REQ-EVM-02 JSON rejects unknown types and bad shapes with errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = parseFragment;
    try testing.expectError(JsonAbiError.InvalidJson, parse(a, "{"));
    try testing.expectError(JsonAbiError.InvalidJson, parse(a, "[]"));
    try testing.expectError(JsonAbiError.InvalidJson, parse(a,
        \\{"name":1}
    ));
    try testing.expectError(JsonAbiError.InvalidJson, parse(a,
        \\{"name":"f","inputs":{}}
    ));
    try testing.expectError(JsonAbiError.InvalidJson, parse(a,
        \\{"name":"f","inputs":[3]}
    ));
    try testing.expectError(JsonAbiError.InvalidType, parse(a,
        \\{"name":"f","inputs":[{"type":"uint7"}]}
    ));
    try testing.expectError(JsonAbiError.InvalidType, parse(a,
        \\{"name":"f","inputs":[{"type":"tuple"}]}
    ));
    try testing.expectError(JsonAbiError.InvalidType, parse(a,
        \\{"name":"f","inputs":[{"type":"uint8[2]x"}]}
    ));
    try testing.expectError(JsonAbiError.InvalidType, parse(a,
        \\{"type":"constructor","inputs":[]}
    ));
    try testing.expectError(JsonAbiError.InvalidSignature, parse(a,
        \\{"name":"f","inputs":[{"type":"uint8","name":"a\"b"}]}
    ));
    try testing.expectError(JsonAbiError.InvalidSignature, parse(a,
        \\{"type":"function","name":"f","inputs":[{"type":"uint8","indexed":true}]}
    ));
}

test "REQ-EVM-02 JSON component nesting is bounded" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("{\"name\":\"f\",\"inputs\":");
    for (0..20) |_| try w.writeAll("[{\"type\":\"tuple\",\"components\":");
    try w.writeAll("[{\"type\":\"uint8\"}]");
    for (0..20) |_| try w.writeAll("}]");
    try w.writeAll("}");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(JsonAbiError.DepthExceeded, parseFragment(arena.allocator(), w.buffered()));
}

fn parseOne(_: void, bytes: []const u8) void {
    var buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    _ = parseFragment(fba.allocator(), bytes) catch {};
    fba.reset();
    _ = parseAbi(fba.allocator(), bytes) catch {};
}

test "REQ-EVM-02 JSON parser stress" {
    core_fuzz.stress(200_000, &.{
        order_fulfilled,
        \\[{"type":"function","name":"f","inputs":[{"type":"tuple[2][]","components":[{"type":"uint8[3]"},{"type":"string"}]}],"outputs":[]}]
        ,
        vectors.fragments[0].json,
    }, {}, parseOne);
}

test "REQ-EVM-02 JSON parser fuzz" {
    try testing.fuzz({}, struct {
        fn f(_: void, smith: *testing.Smith) !void {
            var buf: [512]u8 = undefined;
            parseOne({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}
