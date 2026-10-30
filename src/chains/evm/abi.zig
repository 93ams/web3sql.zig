//! ABI type grammar: human-readable signatures to a runtime `Type` tree, canonical rendering, topic0 and selectors.
//! The tree is built once at bind time from a caller allocator; `decoder.zig` only reads it.
const std = @import("std");
const keccak = @import("../../core/crypto/keccak.zig");

pub const Selector = [4]u8;
pub const Topic = [32]u8;

/// Deepest allowed nesting. A leaf counts as 1, each array or tuple around it adds 1, and so does the argument list.
pub const MAX_DEPTH: u8 = 16;

pub const AbiError = error{
    InvalidSignature,
    InvalidType,
    DepthExceeded,
    TypeTooLarge,
    OutOfMemory,
};

pub const Type = struct {
    kind: Kind,
    dynamic: bool = false,
    depth: u8 = 1,
    /// Encoded size of a static type, or the head of a dynamic tuple or `T[N]`. Cached so rows never recompute it.
    size: u32 = 32,

    pub const Kind = union(enum) {
        uint: u16,
        int: u16,
        address,
        boolean,
        fixed_bytes: u8,
        bytes,
        string,
        array: *const Type,
        fixed_array: struct { elem: *const Type, len: u32 },
        tuple: []const Param,
    };

    /// Bytes this type occupies in its parent's head.
    pub fn headSize(self: *const Type) u32 {
        return if (self.dynamic) 32 else self.size;
    }

    pub fn isComposite(self: *const Type) bool {
        return switch (self.kind) {
            .array, .fixed_array, .tuple => true,
            else => false,
        };
    }

    /// Value types are stored directly in a topic; all others are replaced by their keccak hash.
    pub fn isValueType(self: *const Type) bool {
        return switch (self.kind) {
            .uint, .int, .address, .boolean, .fixed_bytes => true,
            else => false,
        };
    }
};

pub const Param = struct {
    name: []const u8 = "",
    ty: Type,
    indexed: bool = false,
};

pub const FragmentKind = enum { event, function, unknown };

/// One bound event or function. Takes `*const` in the decoder because `root` is referenced by decoded values.
pub const Fragment = struct {
    kind: FragmentKind,
    name: []const u8,
    inputs: []const Param,
    outputs: []const Param,
    anonymous: bool,
    indexed: u8,
    /// `Name(type,type)`, the string that is hashed.
    canonical: []const u8,
    hash: Topic,
    /// `inputs` as one tuple whose head starts at byte 0 of `data`, hence never "dynamic" itself.
    root: Type,

    pub fn selector(self: *const Fragment) Selector {
        return self.hash[0..4].*;
    }

    pub fn topic0(self: *const Fragment) Topic {
        return self.hash;
    }
};

/// Computes the 4-byte function selector from a canonical signature e.g. "transfer(address,uint256)".
pub fn computeSelector(signature: []const u8) Selector {
    var hash_buf: [32]u8 = undefined;
    keccak.hash(signature, &hash_buf);
    return hash_buf[0..4].*;
}

/// Computes event topic0 from an event signature e.g. "Transfer(address,address,uint256)".
pub fn computeTopic0(signature: []const u8) Topic {
    var hash_buf: [32]u8 = undefined;
    keccak.hash(signature, &hash_buf);
    return hash_buf;
}

fn parseSize(s: []const u8) ?u32 {
    if (s.len == 0 or (s[0] == '0' and s.len > 1)) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Maps a non-tuple, non-array type name to its `Type`. `uint` and `int` are aliases for the 256-bit forms.
pub fn elementary(name: []const u8) AbiError!Type {
    const eql = std.mem.eql;
    if (eql(u8, name, "address")) return .{ .kind = .address };
    if (eql(u8, name, "bool")) return .{ .kind = .boolean };
    if (eql(u8, name, "string")) return .{ .kind = .string, .dynamic = true };
    if (eql(u8, name, "bytes")) return .{ .kind = .bytes, .dynamic = true };
    if (eql(u8, name, "uint")) return .{ .kind = .{ .uint = 256 } };
    if (eql(u8, name, "int")) return .{ .kind = .{ .int = 256 } };
    if (std.mem.startsWith(u8, name, "bytes")) {
        const n = parseSize(name[5..]) orelse return AbiError.InvalidType;
        if (n < 1 or n > 32) return AbiError.InvalidType;
        return .{ .kind = .{ .fixed_bytes = @intCast(n) } };
    }
    const is_uint = std.mem.startsWith(u8, name, "uint");
    if (!is_uint and !std.mem.startsWith(u8, name, "int")) return AbiError.InvalidType;
    const bits = parseSize(name[if (is_uint) 4 else 3..]) orelse return AbiError.InvalidType;
    if (bits < 8 or bits > 256 or bits % 8 != 0) return AbiError.InvalidType;
    return .{ .kind = if (is_uint) .{ .uint = @intCast(bits) } else .{ .int = @intCast(bits) } };
}

fn nested(child_depth: u8) AbiError!u8 {
    if (child_depth >= MAX_DEPTH) return AbiError.DepthExceeded;
    return child_depth + 1;
}

/// Builds the tuple type of `params`. Empty tuples have no encoding in Solidity and would make zero-size array elements.
pub fn tupleOf(params: []const Param) AbiError!Type {
    if (params.len == 0) return AbiError.InvalidType;
    var ty: Type = .{ .kind = .{ .tuple = params }, .size = 0, .depth = 1 };
    for (params) |p| {
        ty.dynamic = ty.dynamic or p.ty.dynamic;
        ty.depth = @max(ty.depth, try nested(p.ty.depth));
        ty.size = std.math.add(u32, ty.size, p.ty.headSize()) catch return AbiError.TypeTooLarge;
    }
    return ty;
}

fn wrapArray(allocator: std.mem.Allocator, elem: Type, len: ?u32) AbiError!Type {
    const depth = try nested(elem.depth);
    const child = try allocator.create(Type);
    child.* = elem;
    const n = len orelse return .{ .kind = .{ .array = child }, .dynamic = true, .depth = depth };
    // Zero-length arrays are a Solidity compile error, and zero-size elements would defeat the array length bound.
    if (n == 0) return AbiError.InvalidType;
    return .{
        .kind = .{ .fixed_array = .{ .elem = child, .len = n } },
        .dynamic = elem.dynamic,
        .depth = depth,
        .size = std.math.mul(u32, elem.headSize(), n) catch return AbiError.TypeTooLarge,
    };
}

/// Applies every `[]` or `[N]` suffix starting at `text[pos.*]`, advancing `pos` past them.
pub fn applyArraySuffixes(allocator: std.mem.Allocator, base: Type, text: []const u8, pos: *usize) AbiError!Type {
    var ty = base;
    while (pos.* < text.len and text[pos.*] == '[') {
        const close = std.mem.indexOfScalarPos(u8, text, pos.*, ']') orelse return AbiError.InvalidType;
        const digits = text[pos.* + 1 .. close];
        const len = if (digits.len == 0) null else parseSize(digits) orelse return AbiError.InvalidType;
        ty = try wrapArray(allocator, ty, len);
        pos.* = close + 1;
    }
    return ty;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    return true;
}

/// Checks a parameter name from outside this file. Names reach JSON output unescaped, so this is what keeps it valid.
pub fn isParamName(s: []const u8) bool {
    return s.len == 0 or isIdentifier(s);
}

fn writeType(a: std.mem.Allocator, out: *std.ArrayList(u8), ty: *const Type) AbiError!void {
    switch (ty.kind) {
        .uint => |bits| try out.print(a, "uint{d}", .{bits}),
        .int => |bits| try out.print(a, "int{d}", .{bits}),
        .address => try out.appendSlice(a, "address"),
        .boolean => try out.appendSlice(a, "bool"),
        .fixed_bytes => |n| try out.print(a, "bytes{d}", .{n}),
        .bytes => try out.appendSlice(a, "bytes"),
        .string => try out.appendSlice(a, "string"),
        .array => |elem| {
            try writeType(a, out, elem);
            try out.appendSlice(a, "[]");
        },
        .fixed_array => |arr| {
            try writeType(a, out, arr.elem);
            try out.print(a, "[{d}]", .{arr.len});
        },
        .tuple => |fields| try writeParams(a, out, fields),
    }
}

fn writeParams(a: std.mem.Allocator, out: *std.ArrayList(u8), params: []const Param) AbiError!void {
    try out.append(a, '(');
    for (params, 0..) |*p, i| {
        if (i > 0) try out.append(a, ',');
        try writeType(a, out, &p.ty);
    }
    try out.append(a, ')');
}

/// Validates a parsed fragment and computes everything rows need. Shared by the signature and JSON parsers.
pub fn finishFragment(allocator: std.mem.Allocator, kind_hint: FragmentKind, name: []const u8, inputs: []const Param, outputs: []const Param, anonymous: bool) AbiError!Fragment {
    if (!isIdentifier(name)) return AbiError.InvalidSignature;
    var kind = kind_hint;
    var root: Type = .{ .kind = .{ .tuple = inputs }, .size = 0 };
    var indexed: usize = 0;
    for (inputs) |p| {
        root.depth = @max(root.depth, try nested(p.ty.depth));
        if (p.indexed) {
            indexed += 1;
        } else {
            root.size = std.math.add(u32, root.size, p.ty.headSize()) catch return AbiError.TypeTooLarge;
        }
    }
    if (indexed > 0 or anonymous) {
        if (kind == .function) return AbiError.InvalidSignature;
        kind = .event;
    }
    if (indexed > @as(usize, if (anonymous) 4 else 3)) return AbiError.InvalidSignature;

    var canonical: std.ArrayList(u8) = .empty;
    try canonical.appendSlice(allocator, name);
    try writeParams(allocator, &canonical, inputs);
    const text = try canonical.toOwnedSlice(allocator);

    return .{
        .kind = kind,
        .name = name,
        .inputs = inputs,
        .outputs = outputs,
        .anonymous = anonymous,
        .indexed = @intCast(indexed),
        .canonical = text,
        .hash = computeTopic0(text),
        .root = root,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }

    fn eat(self: *Parser, c: u8) bool {
        self.skipSpace();
        if (self.pos >= self.text.len or self.text[self.pos] != c) return false;
        self.pos += 1;
        return true;
    }

    /// Next run of name characters, possibly empty.
    fn word(self: *Parser) []const u8 {
        self.skipSpace();
        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const c = self.text[self.pos];
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') break;
        }
        return self.text[start..self.pos];
    }

    /// Commas at this nesting level, up to the matching ')', so the slice can be sized once.
    fn countParams(self: *const Parser) AbiError!usize {
        var count: usize = 1;
        var nest: usize = 0;
        for (self.text[self.pos..]) |c| switch (c) {
            '(' => nest += 1,
            ')' => {
                if (nest == 0) return count;
                nest -= 1;
            },
            ',' => {
                if (nest == 0) count += 1;
            },
            else => {},
        };
        return AbiError.InvalidSignature;
    }

    /// Parses up to and including the ')' closing an already-consumed '('.
    fn params(self: *Parser, depth: u8, allow_indexed: bool) AbiError![]const Param {
        if (self.eat(')')) return &.{};
        const list = try self.allocator.alloc(Param, try self.countParams());
        for (list, 0..) |*p, i| {
            if (i > 0 and !self.eat(',')) return AbiError.InvalidSignature;
            p.* = try self.param(depth, allow_indexed);
        }
        if (!self.eat(')')) return AbiError.InvalidSignature;
        return list;
    }

    fn param(self: *Parser, depth: u8, allow_indexed: bool) AbiError!Param {
        var p: Param = .{ .ty = try self.parseType(depth) };
        while (true) {
            const w = self.word();
            if (std.mem.eql(u8, w, "indexed")) {
                if (!allow_indexed or p.indexed) return AbiError.InvalidSignature;
                p.indexed = true;
            } else if (!isLocation(w)) {
                if (w.len == 0) return p;
                if (!isIdentifier(w)) return AbiError.InvalidSignature;
                p.name = try self.allocator.dupe(u8, w);
                return p;
            }
        }
    }

    fn parseType(self: *Parser, depth: u8) AbiError!Type {
        if (depth >= MAX_DEPTH) return AbiError.DepthExceeded;
        var base: Type = undefined;
        if (self.eat('(')) {
            base = try tupleOf(try self.params(depth + 1, false));
        } else {
            const w = self.word();
            if (std.mem.eql(u8, w, "tuple") and self.eat('(')) {
                base = try tupleOf(try self.params(depth + 1, false));
            } else {
                base = try elementary(w);
            }
        }
        return applyArraySuffixes(self.allocator, base, self.text, &self.pos);
    }
};

fn isLocation(w: []const u8) bool {
    for ([_][]const u8{ "calldata", "memory", "storage", "payable" }) |k| {
        if (std.mem.eql(u8, w, k)) return true;
    }
    return false;
}

fn isFunctionModifier(w: []const u8) bool {
    for ([_][]const u8{ "external", "public", "view", "pure", "payable", "nonpayable", "constant" }) |k| {
        if (std.mem.eql(u8, w, k)) return true;
    }
    return false;
}

/// Parses a human-readable signature: `event Swap(address indexed sender, ...)`,
/// `function f(uint a) view returns (bool)` or a bare `Swap(address,int256)`, whose kind stays `.unknown`
/// unless `indexed`, `anonymous`, `returns` or a modifier settles it. Every string is copied into `allocator`,
/// which should be an arena: the tree is freed as a whole, and a failed parse leaves its partial tree behind.
pub fn parseSignature(allocator: std.mem.Allocator, text: []const u8) AbiError!Fragment {
    var p: Parser = .{ .allocator = allocator, .text = text };
    var kind: FragmentKind = .unknown;
    var name = p.word();
    if (std.mem.eql(u8, name, "event")) {
        kind = .event;
        name = p.word();
    } else if (std.mem.eql(u8, name, "function")) {
        kind = .function;
        name = p.word();
    }
    if (!p.eat('(')) return AbiError.InvalidSignature;
    const inputs = try p.params(0, kind != .function);

    var outputs: []const Param = &.{};
    var anonymous = false;
    while (true) {
        const w = p.word();
        if (w.len == 0) break;
        const event_word = std.mem.eql(u8, w, "anonymous");
        const returns = std.mem.eql(u8, w, "returns");
        if (!event_word and !returns and !isFunctionModifier(w)) return AbiError.InvalidSignature;
        const wanted: FragmentKind = if (event_word) .event else .function;
        if (kind != .unknown and kind != wanted) return AbiError.InvalidSignature;
        kind = wanted;
        anonymous = anonymous or event_word;
        if (returns) {
            if (!p.eat('(')) return AbiError.InvalidSignature;
            outputs = try p.params(0, false);
        }
    }
    p.skipSpace();
    if (p.pos != text.len) return AbiError.InvalidSignature;
    return finishFragment(allocator, kind, try allocator.dupe(u8, name), inputs, outputs, anonymous);
}

const testing = std.testing;
const core_fuzz = @import("../../core/fuzz.zig");

fn expectCanonical(sig: []const u8, canonical: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try parseSignature(arena.allocator(), sig);
    try testing.expectEqualStrings(canonical, f.canonical);
}

test "REQ-EVM-01 compute selector and topic0" {
    // Both values checked against eth_utils.keccak; the topic also heads the real Transfer logs in abi_vectors.zig.
    const sel = computeSelector("transfer(address,uint256)");
    const expected_sel = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try testing.expectEqual(expected_sel, sel);

    const topic = computeTopic0("Transfer(address,address,uint256)");
    const expected_topic = "\xdd\xf2\x52\xad\x1b\xe2\xc8\x9b\x69\xc2\xb0\x68\xfc\x37\x8d\xaa\x95\x2b\xa7\xf1\x63\xc4\xa1\x16\x28\xf5\x5a\x4d\xf5\x23\xb3\xef";
    try testing.expectEqualStrings(expected_topic, &topic);
}

test "REQ-EVM-02 human-readable signatures render canonically" {
    try expectCanonical("Swap(address indexed sender, int256 amount0, uint160 sqrtPriceX96)", "Swap(address,int256,uint160)");
    try expectCanonical("event Swap( address indexed sender , uint amount )", "Swap(address,uint256)");
    try expectCanonical("function f(uint a, (int b, string[] c)[2][] memory d) external view returns (bool)", "f(uint256,(int256,string[])[2][])");
    try expectCanonical("function g(tuple(address payable a, bytes32[3] calldata b) t)", "g((address,bytes32[3]))");
    try expectCanonical("noArgs()", "noArgs()");
    try expectCanonical("function $_x1(int8,uint8,bytes1,bytes32)", "$_x1(int8,uint8,bytes1,bytes32)");
}

test "REQ-EVM-02 fragment kinds, names, indexed flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const swap = try parseSignature(a, "Swap(address indexed sender, int256 amount0)");
    try testing.expectEqual(FragmentKind.event, swap.kind);
    try testing.expectEqual(@as(u8, 1), swap.indexed);
    try testing.expectEqualStrings("sender", swap.inputs[0].name);
    try testing.expect(swap.inputs[0].indexed and !swap.inputs[1].indexed);
    try testing.expectEqual(@as(u32, 32), swap.root.size);

    const f = try parseSignature(a, "transfer(address to, uint256 value) returns (bool ok)");
    try testing.expectEqual(FragmentKind.function, f.kind);
    try testing.expectEqualStrings("ok", f.outputs[0].name);
    try testing.expectEqual([4]u8{ 0xa9, 0x05, 0x9c, 0xbb }, f.selector());

    try testing.expectEqual(FragmentKind.unknown, (try parseSignature(a, "x(uint8)")).kind);
    const anon = try parseSignature(a, "event A(uint indexed a, uint indexed b, uint indexed c, uint indexed d) anonymous");
    try testing.expect(anon.anonymous);
    try testing.expectEqual(@as(u8, 4), anon.indexed);
}

test "REQ-EVM-02 static sizes are cached at bind time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try parseSignature(arena.allocator(), "f((uint,bool)[3] a, string[2] b, (uint,bytes) c, uint[][2] d)");
    try testing.expectEqual(@as(u32, 192 + 32 + 32 + 32), f.root.size);
    try testing.expect(!f.inputs[0].ty.dynamic);
    try testing.expect(f.inputs[1].ty.dynamic);
    try testing.expectEqual(@as(u32, 64), f.inputs[1].ty.size);
    try testing.expectEqual(@as(u32, 64), f.inputs[2].ty.size);
}

test "REQ-EVM-02 rejects malformed signatures with typed errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad_type = [_][]const u8{ "f(uint7)", "f(uint264)", "f(uint0)", "f(uint08)", "f(int)x", "f(bytes0)", "f(bytes33)", "f(foo)", "f(fixed128x18)", "f(function)", "f(uint[0])", "f(())", "f(uint[-1])", "f(uint[+1])", "f(uint[)", "f(tuple)", "f(,)", "f(uint,)" };
    for (bad_type) |s| {
        if (parseSignature(a, s)) |_| return error.TestExpectedError else |e| {
            try testing.expect(e == AbiError.InvalidType or e == AbiError.InvalidSignature);
        }
    }
    const bad_sig = [_][]const u8{ "", "f", "f(", "1f()", "(uint)", "event (uint)", "f(uint a b)", "f(uint))", "f() bogus", "f() returns", "event f() view", "function f() anonymous", "function f(uint indexed a)", "f(uint indexed indexed a)", "f((uint indexed a))", "f(uint indexed a,uint indexed b,uint indexed c,uint indexed d)" };
    for (bad_sig) |s| try testing.expectError(AbiError.InvalidSignature, parseSignature(a, s));

    try testing.expectError(AbiError.TypeTooLarge, parseSignature(a, "f(uint[4294967295])"));
    try testing.expectError(AbiError.TypeTooLarge, parseSignature(a, "f(uint[65536][65536])"));
}

test "REQ-EVM-02 nesting depth is bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try parseSignature(a, "f(uint[][][][][][][][][][][][][][])");
    try testing.expectError(AbiError.DepthExceeded, parseSignature(a, "f(uint[][][][][][][][][][][][][][][][][])"));
    try testing.expectError(AbiError.DepthExceeded, parseSignature(a, "f(((((((((((((((((((((uint)))))))))))))))))))))"));
}

fn parseOne(_: void, bytes: []const u8) void {
    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    _ = parseSignature(fba.allocator(), bytes) catch {};
}

test "REQ-EVM-02 signature parser stress" {
    core_fuzz.stress(200_000, &.{
        "event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)",
        "function f(uint a, (int b, string[] c)[2][] memory d) external view returns (bool, (bytes32,uint8[3])[])",
        "OrderFulfilled(bytes32,address,address,address,(uint8,address,uint256,uint256)[],(uint8,address,uint256,uint256,address)[])",
    }, {}, parseOne);
}

test "REQ-EVM-02 signature parser fuzz" {
    try testing.fuzz({}, struct {
        fn f(_: void, smith: *testing.Smith) !void {
            var buf: [256]u8 = undefined;
            parseOne({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}
