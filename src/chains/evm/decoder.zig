//! Zero-allocation ABI head/tail decoder over a bound `abi.Type` tree.
//! `Value` locates one value lazily, `Cursor` walks a value flat, `decodeField` jumps to one field by path.
//! Rejected: anything that changes a value (dirty high bits, bad bool, offsets or lengths leaving `data`).
//! Tolerated: unpadded or non-zero tail padding and trailing bytes, which change no value and occur in real logs.
const std = @import("std");
const abi = @import("abi.zig");
const hex = @import("../../core/encodings/hex.zig");
const u256_math = @import("../../core/math/u256.zig");

const Type = abi.Type;
const Fragment = abi.Fragment;

pub const DecoderError = error{
    OutOfBounds,
    InvalidOffset,
    InvalidLength,
    InvalidValue,
    InvalidUtf8,
    WorkExceeded,
    BufferTooSmall,
    TypeMismatch,
    TopicMismatch,
    TopicCount,
    SelectorMismatch,
    KindMismatch,
    InvalidPath,
    NoSuchField,
};

/// Stands in for indexed non-value params, whose topic holds only their keccak hash.
const hash_type: Type = .{ .kind = .{ .fixed_bytes = 32 } };

fn wordUsize(w: *const [32]u8) ?usize {
    for (w[0..24]) |b| if (b != 0) return null;
    return std.math.cast(usize, std.mem.readInt(u64, w[24..32], .big));
}

/// One value located inside its frame. Nothing is read until an accessor is called.
pub const Value = struct {
    ty: *const Type,
    /// Bytes that this value's offsets are relative to.
    frame: []const u8,
    pos: usize = 0,
    /// Topics not yet consumed. Only a log root has any.
    topics: []const [32]u8 = &.{},

    fn word(self: Value) DecoderError!*const [32]u8 {
        if (self.frame.len < 32 or self.pos > self.frame.len - 32) return DecoderError.OutOfBounds;
        return self.frame[self.pos..][0..32];
    }

    /// Follows the offset word at this position. Offsets only move forward in the frame, so no cycle can form.
    fn tail(self: Value) DecoderError![]const u8 {
        const offset = wordUsize(try self.word()) orelse return DecoderError.InvalidOffset;
        if (offset > self.frame.len) return DecoderError.InvalidOffset;
        return self.frame[offset..];
    }

    pub fn uint(self: Value) DecoderError!u256 {
        if (self.ty.kind != .uint) return DecoderError.TypeMismatch;
        const bits = self.ty.kind.uint;
        const v = std.mem.readInt(u256, try self.word(), .big);
        if (bits < 256 and v >> @intCast(bits) != 0) return DecoderError.InvalidValue;
        return v;
    }

    pub fn int(self: Value) DecoderError!i256 {
        if (self.ty.kind != .int) return DecoderError.TypeMismatch;
        const bits = self.ty.kind.int;
        const v = std.mem.readInt(i256, try self.word(), .big);
        const top = v >> @intCast(bits - 1);
        if (top != 0 and top != -1) return DecoderError.InvalidValue;
        return v;
    }

    pub fn address(self: Value) DecoderError!*const [20]u8 {
        if (self.ty.kind != .address) return DecoderError.TypeMismatch;
        const w = try self.word();
        for (w[0..12]) |b| if (b != 0) return DecoderError.InvalidValue;
        return w[12..32];
    }

    pub fn boolean(self: Value) DecoderError!bool {
        if (self.ty.kind != .boolean) return DecoderError.TypeMismatch;
        const w = try self.word();
        for (w[0..31]) |b| if (b != 0) return DecoderError.InvalidValue;
        return switch (w[31]) {
            0 => false,
            1 => true,
            else => DecoderError.InvalidValue,
        };
    }

    /// Content of `bytes`, `string` or `bytesN`. A `string` is not checked for UTF-8 here.
    pub fn bytes(self: Value) DecoderError![]const u8 {
        switch (self.ty.kind) {
            .fixed_bytes => |n| {
                const w = try self.word();
                for (w[n..]) |b| if (b != 0) return DecoderError.InvalidValue;
                return w[0..n];
            },
            .bytes, .string => {
                const t = try self.tail();
                if (t.len < 32) return DecoderError.OutOfBounds;
                const size = wordUsize(t[0..32]) orelse return DecoderError.InvalidLength;
                if (size > t.len - 32) return DecoderError.InvalidLength;
                return t[32..][0..size];
            },
            else => return DecoderError.TypeMismatch,
        }
    }

    /// Opens a composite. Every child's head is then proven in bounds, so array length cannot exceed the frame.
    fn iter(self: Value) DecoderError!Iter {
        var it: Iter = .{ .ty = self.ty, .frame = self.frame, .pos = self.pos, .topics = self.topics, .count = 0 };
        switch (self.ty.kind) {
            .tuple => |fields| it.count = fields.len,
            .fixed_array => |arr| it.count = arr.len,
            .array => |elem| {
                const t = try self.tail();
                if (t.len < 32) return DecoderError.OutOfBounds;
                it.count = wordUsize(t[0..32]) orelse return DecoderError.InvalidLength;
                it.frame = t[32..];
                it.pos = 0;
                if (it.count > it.frame.len / elem.headSize()) return DecoderError.InvalidLength;
                return it;
            },
            else => return DecoderError.TypeMismatch,
        }
        if (self.ty.dynamic) {
            it.frame = try self.tail();
            it.pos = 0;
        }
        if (it.pos > it.frame.len or self.ty.size > it.frame.len - it.pos) return DecoderError.OutOfBounds;
        return it;
    }

    /// Number of children of an array or tuple.
    pub fn len(self: Value) DecoderError!usize {
        return (try self.iter()).count;
    }

    /// Child by position. O(1) for arrays, O(fields) for tuples.
    pub fn at(self: Value, index: usize) DecoderError!Value {
        var it = try self.iter();
        if (index >= it.count) return if (self.ty.kind == .tuple) DecoderError.NoSuchField else DecoderError.OutOfBounds;
        if (self.ty.kind != .tuple) {
            const elem = it.elemType();
            return .{ .ty = elem, .frame = it.frame, .pos = it.pos + index * elem.headSize() };
        }
        for (0..index) |_| _ = try it.next();
        return it.next();
    }

    /// Tuple field by name.
    pub fn named(self: Value, name: []const u8) DecoderError!Value {
        if (self.ty.kind != .tuple) return DecoderError.TypeMismatch;
        for (self.ty.kind.tuple, 0..) |*p, i| {
            if (std.mem.eql(u8, p.name, name)) return self.at(i);
        }
        return DecoderError.NoSuchField;
    }
};

/// The one place that computes where a child sits; `Value.at` and `Cursor` both use it.
const Iter = struct {
    ty: *const Type,
    frame: []const u8,
    pos: usize,
    topics: []const [32]u8,
    count: usize,
    index: usize = 0,

    fn elemType(self: *const Iter) *const Type {
        return switch (self.ty.kind) {
            .array => |elem| elem,
            .fixed_array => |arr| arr.elem,
            else => unreachable, // only called once `ty` is known to be an array
        };
    }

    /// Precondition: `index < count`.
    fn next(self: *Iter) DecoderError!Value {
        defer self.index += 1;
        const child_ty = switch (self.ty.kind) {
            .tuple => |fields| blk: {
                const p = &fields[self.index];
                if (p.indexed) {
                    if (self.topics.len == 0) return DecoderError.TopicCount;
                    const topic = &self.topics[0];
                    self.topics = self.topics[1..];
                    return .{ .ty = if (p.ty.isValueType()) &p.ty else &hash_type, .frame = topic };
                }
                break :blk &p.ty;
            },
            else => self.elemType(),
        };
        const v: Value = .{ .ty = child_ty, .frame = self.frame, .pos = self.pos };
        self.pos += child_ty.headSize();
        return v;
    }
};

/// Flat depth-first walk with no allocation and no recursion.
///
/// Overlapping offsets could make `T[][][]...` visit the same tail over and over, multiplying per level. So each
/// offset word, leaf and payload word is charged against a budget linear in `frame.len`. A canonical encoding pays
/// one unit per word it owns, which is half the budget.
/// shortcut: encoders that share one tail more than twice over run out of budget, widen `init` if real data does.
pub const Cursor = struct {
    stack: [abi.MAX_DEPTH]Iter = undefined,
    top: usize = 0,
    pending: ?Value,
    budget: usize,

    pub const Item = struct {
        tag: enum { value, open, close },
        value: Value,
        /// Field name inside a tuple (empty if unnamed), null for array elements and the start value.
        name: ?[]const u8 = null,
        index: usize = 0,
    };

    pub fn init(start: Value) Cursor {
        return .{ .pending = start, .budget = start.frame.len / 16 + 8 };
    }

    fn charge(self: *Cursor, units: usize) DecoderError!void {
        if (units > self.budget) return DecoderError.WorkExceeded;
        self.budget -= units;
    }

    /// Next event, or null at the end. Yields an error instead of walking past hostile data.
    pub fn next(self: *Cursor) DecoderError!?Item {
        var item: Item = undefined;
        if (self.pending) |start| {
            self.pending = null;
            item = .{ .tag = .value, .value = start };
        } else {
            if (self.top == 0) return null;
            const it = &self.stack[self.top - 1];
            if (it.index == it.count) {
                self.top -= 1;
                return .{ .tag = .close, .value = .{ .ty = it.ty, .frame = it.frame } };
            }
            item = .{ .tag = .value, .value = undefined, .index = it.index };
            if (it.ty.kind == .tuple) item.name = it.ty.kind.tuple[it.index].name;
            item.value = try it.next();
        }
        const ty = item.value.ty;
        if (ty.dynamic or !ty.isComposite()) try self.charge(1);
        if (ty.isComposite()) {
            if (self.top == self.stack.len) return DecoderError.WorkExceeded;
            self.stack[self.top] = try item.value.iter();
            self.top += 1;
            item.tag = .open;
        } else if (ty.dynamic) {
            try self.charge((try item.value.bytes()).len / 32 + 1);
        }
        return item;
    }
};

/// Validates a log against `frag` and returns its root value: a tuple of all inputs in declaration order,
/// indexed ones read from `topics`. Indexed strings, bytes, arrays and tuples surface as their 32-byte hash.
pub fn logRoot(frag: *const Fragment, topics: []const [32]u8, data: []const u8) DecoderError!Value {
    if (frag.kind == .function) return DecoderError.KindMismatch;
    var rest = topics;
    if (!frag.anonymous) {
        if (rest.len == 0) return DecoderError.TopicCount;
        if (!std.mem.eql(u8, &rest[0], &frag.hash)) return DecoderError.TopicMismatch;
        rest = rest[1..];
    }
    if (rest.len != frag.indexed) return DecoderError.TopicCount;
    return .{ .ty = &frag.root, .frame = data, .topics = rest };
}

/// Checks the 4-byte selector of `input` and returns the arguments as a root tuple.
pub fn calldataRoot(frag: *const Fragment, input: []const u8) DecoderError!Value {
    if (frag.kind == .event) return DecoderError.KindMismatch;
    if (input.len < 4) return DecoderError.OutOfBounds;
    if (!std.mem.eql(u8, input[0..4], frag.hash[0..4])) return DecoderError.SelectorMismatch;
    return .{ .ty = &frag.root, .frame = input[4..] };
}

fn parseIndex(s: []const u8) ?usize {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

/// Walks `path` from `root` with no allocation: names and positions joined by dots, `[i]` for elements,
/// e.g. `offer[2].token` or `1.0`. Cost is O(depth * fields), independent of `data`, so no budget applies.
pub fn decodeField(root: Value, path: []const u8) DecoderError!Value {
    var v = root;
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '[') {
            const close = std.mem.indexOfScalarPos(u8, path, i, ']') orelse return DecoderError.InvalidPath;
            v = try v.at(parseIndex(path[i + 1 .. close]) orelse return DecoderError.InvalidPath);
            i = close + 1;
            continue;
        }
        if (i > 0) {
            if (path[i] != '.') return DecoderError.InvalidPath;
            i += 1;
        }
        const start = i;
        while (i < path.len and path[i] != '.' and path[i] != '[') i += 1;
        const segment = path[start..i];
        if (segment.len == 0) return DecoderError.InvalidPath;
        v = if (parseIndex(segment)) |index| try v.at(index) else try v.named(segment);
    }
    return v;
}

/// Largest integer magnitude rendered as a JSON number; above it JSON readers lose precision.
const MAX_JSON_INT: u256 = 1 << 53;

const Out = struct {
    dest: []u8,
    n: usize = 0,

    fn rest(self: *Out) []u8 {
        return self.dest[self.n..];
    }

    fn put(self: *Out, s: []const u8) DecoderError!void {
        if (s.len > self.dest.len - self.n) return DecoderError.BufferTooSmall;
        @memcpy(self.rest()[0..s.len], s);
        self.n += s.len;
    }

    fn decimal(self: *Out, magnitude: u256, negative: bool, quoted: bool) DecoderError!void {
        if (quoted) try self.put("\"");
        if (negative) try self.put("-");
        self.n += (u256_math.formatDecimal(magnitude, self.rest()) catch return DecoderError.BufferTooSmall).len;
        if (quoted) try self.put("\"");
    }

    fn hexString(self: *Out, raw: []const u8) DecoderError!void {
        try self.put("\"0x");
        self.n += (hex.encodeHex(raw, self.rest()) catch return DecoderError.BufferTooSmall).len;
        try self.put("\"");
    }

    fn jsonString(self: *Out, s: []const u8) DecoderError!void {
        if (!std.unicode.utf8ValidateSlice(s)) return DecoderError.InvalidUtf8;
        try self.put("\"");
        var run: usize = 0;
        for (s, 0..) |c, i| {
            if (c >= 0x20 and c != '"' and c != '\\') continue;
            try self.put(s[run..i]);
            run = i + 1;
            const escape = [_]u8{ '\\', 'u', '0', '0', hex.HEX_LOWER[c >> 4], hex.HEX_LOWER[c & 0xF] };
            try self.put(if (c == '"') "\\\"" else if (c == '\\') "\\\\" else &escape);
        }
        try self.put(s[run..]);
        try self.put("\"");
    }

    fn key(self: *Out, name: []const u8, index: usize) DecoderError!void {
        try self.put("\"");
        if (name.len > 0) {
            try self.put(name);
        } else {
            try self.decimal(index, false, false);
        }
        try self.put("\":");
    }

    fn leaf(self: *Out, v: Value) DecoderError!void {
        switch (v.ty.kind) {
            .uint => {
                const x = try v.uint();
                try self.decimal(x, false, x > MAX_JSON_INT);
            },
            .int => {
                const x = try v.int();
                try self.decimal(@abs(x), x < 0, @abs(x) > MAX_JSON_INT);
            },
            .address => try self.hexString(try v.address()),
            .boolean => try self.put(if (try v.boolean()) "true" else "false"),
            .fixed_bytes, .bytes => try self.hexString(try v.bytes()),
            .string => try self.jsonString(try v.bytes()),
            else => return DecoderError.TypeMismatch,
        }
    }
};

/// Writes `v` as compact JSON into `dest`. Tuples are objects keyed by field name, or by position when unnamed;
/// arrays are arrays; integers beyond 2^53 are decimal strings; bytes and addresses are lowercase 0x hex.
pub fn renderJson(v: Value, dest: []u8) DecoderError![]const u8 {
    var out: Out = .{ .dest = dest };
    var cursor = Cursor.init(v);
    var comma = false;
    while (try cursor.next()) |item| {
        const is_tuple = item.value.ty.kind == .tuple;
        if (item.tag == .close) {
            try out.put(if (is_tuple) "}" else "]");
            comma = true;
            continue;
        }
        if (comma) try out.put(",");
        if (item.name) |name| try out.key(name, item.index);
        if (item.tag == .open) {
            try out.put(if (is_tuple) "{" else "[");
            comma = false;
        } else {
            try out.leaf(item.value);
            comma = true;
        }
    }
    return dest[0..out.n];
}

/// One field of a log, located without allocation.
pub fn decodeLogField(frag: *const Fragment, topics: []const [32]u8, data: []const u8, path: []const u8) DecoderError!Value {
    return decodeField(try logRoot(frag, topics, data), path);
}

/// One argument of a call, located without allocation.
pub fn decodeCalldataField(frag: *const Fragment, input: []const u8, path: []const u8) DecoderError!Value {
    return decodeField(try calldataRoot(frag, input), path);
}

/// Whole log as JSON. This is the hot call for structured DEX log decoding.
pub fn renderLogJson(frag: *const Fragment, topics: []const [32]u8, data: []const u8, dest: []u8) DecoderError![]const u8 {
    return renderJson(try logRoot(frag, topics, data), dest);
}

/// Row shape of `renderLogJson`: `topics` is the concatenated 32-byte topics, as a SQL BLOB column holds them.
pub fn renderLogJsonFlat(frag: *const Fragment, topics: []const u8, data: []const u8, dest: []u8) DecoderError![]const u8 {
    if (topics.len % 32 != 0) return DecoderError.TopicCount;
    return renderLogJson(frag, std.mem.bytesAsSlice([32]u8, topics), data, dest);
}

/// Whole calldata as JSON.
pub fn renderCalldataJson(frag: *const Fragment, input: []const u8, dest: []u8) DecoderError![]const u8 {
    return renderJson(try calldataRoot(frag, input), dest);
}

const testing = std.testing;
const core_fuzz = @import("../../core/fuzz.zig");
const vectors = @import("abi_vectors.zig");

/// Hex literal with spaces or newlines allowed, decoded into `buf`.
fn unhex(text: []const u8, buf: []u8) ![]u8 {
    var clean: [65536]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        clean[n] = c;
        n += 1;
    }
    return hex.decodeHex(clean[0..n], buf);
}

fn word(comptime value: u256) [32]u8 {
    return u256_math.toBytes(value, .big);
}

fn expectCalldataJson(sig: []const u8, input_hex: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frag = try abi.parseSignature(arena.allocator(), sig);
    var input: [4096]u8 = undefined;
    var dest: [4096]u8 = undefined;
    try testing.expectEqualStrings(expected, try renderCalldataJson(&frag, try unhex(input_hex, &input), &dest));
}

// Source for the next four: Solidity ABI spec, docs/abi-spec.rst, "Examples" section (ethereum/solidity develop).
test "REQ-EVM-03 spec example baz(uint32,bool)" {
    try expectCalldataJson("function baz(uint32 x, bool y)",
        \\cdcd77c0
        \\0000000000000000000000000000000000000000000000000000000000000045
        \\0000000000000000000000000000000000000000000000000000000000000001
    ,
        \\{"x":69,"y":true}
    );
}

test "REQ-EVM-03 spec example sam(bytes,bool,uint256[])" {
    try expectCalldataJson("function sam(bytes,bool,uint256[])",
        \\a5643bf2
        \\0000000000000000000000000000000000000000000000000000000000000060
        \\0000000000000000000000000000000000000000000000000000000000000001
        \\00000000000000000000000000000000000000000000000000000000000000a0
        \\0000000000000000000000000000000000000000000000000000000000000004
        \\6461766500000000000000000000000000000000000000000000000000000000
        \\0000000000000000000000000000000000000000000000000000000000000003
        \\0000000000000000000000000000000000000000000000000000000000000001
        \\0000000000000000000000000000000000000000000000000000000000000002
        \\0000000000000000000000000000000000000000000000000000000000000003
    ,
        \\{"0":"0x64617665","1":true,"2":[1,2,3]}
    );
}

test "REQ-EVM-03 spec example f(uint256,uint32[],bytes10,bytes)" {
    try expectCalldataJson("function f(uint256,uint32[],bytes10,bytes)",
        \\8be65246
        \\0000000000000000000000000000000000000000000000000000000000000123
        \\0000000000000000000000000000000000000000000000000000000000000080
        \\3132333435363738393000000000000000000000000000000000000000000000
        \\00000000000000000000000000000000000000000000000000000000000000e0
        \\0000000000000000000000000000000000000000000000000000000000000002
        \\0000000000000000000000000000000000000000000000000000000000000456
        \\0000000000000000000000000000000000000000000000000000000000000789
        \\000000000000000000000000000000000000000000000000000000000000000d
        \\48656c6c6f2c20776f726c642100000000000000000000000000000000000000
    ,
        \\{"0":291,"1":[1110,1929],"2":"0x31323334353637383930","3":"0x48656c6c6f2c20776f726c6421"}
    );
}

const spec_g_input =
    \\2289b18c
    \\0000000000000000000000000000000000000000000000000000000000000040
    \\0000000000000000000000000000000000000000000000000000000000000140
    \\0000000000000000000000000000000000000000000000000000000000000002
    \\0000000000000000000000000000000000000000000000000000000000000040
    \\00000000000000000000000000000000000000000000000000000000000000a0
    \\0000000000000000000000000000000000000000000000000000000000000002
    \\0000000000000000000000000000000000000000000000000000000000000001
    \\0000000000000000000000000000000000000000000000000000000000000002
    \\0000000000000000000000000000000000000000000000000000000000000001
    \\0000000000000000000000000000000000000000000000000000000000000003
    \\0000000000000000000000000000000000000000000000000000000000000003
    \\0000000000000000000000000000000000000000000000000000000000000060
    \\00000000000000000000000000000000000000000000000000000000000000a0
    \\00000000000000000000000000000000000000000000000000000000000000e0
    \\0000000000000000000000000000000000000000000000000000000000000003
    \\6f6e650000000000000000000000000000000000000000000000000000000000
    \\0000000000000000000000000000000000000000000000000000000000000003
    \\74776f0000000000000000000000000000000000000000000000000000000000
    \\0000000000000000000000000000000000000000000000000000000000000005
    \\7468726565000000000000000000000000000000000000000000000000000000
;

test "REQ-EVM-03 spec example g(uint256[][],string[])" {
    try expectCalldataJson("function g(uint256[][] a, string[] b)", spec_g_input,
        \\{"a":[[1,2],[3]],"b":["one","two","three"]}
    );
}

test "REQ-EVM-03 real Seaport calldata" {
    const abi_json = @import("abi_json.zig");
    for (vectors.calls) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const frag = try abi_json.parseFragment(arena.allocator(), c.fragment);
        var input: [4096]u8 = undefined;
        var dest: [8192]u8 = undefined;
        try testing.expectEqualStrings(c.json, try renderCalldataJson(&frag, try hex.decodeHex(c.input, &input), &dest));
    }
}

test "REQ-EVM-03 calldata checks the selector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frag = try abi.parseSignature(a, "function baz(uint32 x, bool y)");
    var dest: [64]u8 = undefined;
    try testing.expectError(DecoderError.OutOfBounds, renderCalldataJson(&frag, "\xcd\xcd", &dest));
    try testing.expectError(DecoderError.SelectorMismatch, renderCalldataJson(&frag, "\x00\x00\x00\x00", &dest));
    const ev = try abi.parseSignature(a, "event E(uint indexed a)");
    try testing.expectError(DecoderError.KindMismatch, calldataRoot(&ev, "\x00\x00\x00\x00"));
    // A bare signature can serve as either kind.
    const bare = try abi.parseSignature(a, "baz(uint32,bool)");
    const input = "\xcd\xcd\x77\xc0" ++ word(69) ++ word(1);
    try testing.expectEqual(@as(u256, 69), try (try decodeCalldataField(&bare, input, "0")).uint());
}

test "REQ-EVM-03 decodeField by name, position and element, across dynamic layers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frag = try abi.parseSignature(arena.allocator(), "function g(uint256[][] a, string[] b)");
    var buf: [4096]u8 = undefined;
    const input = try unhex(spec_g_input, &buf);

    try testing.expectEqual(@as(u256, 2), try (try decodeCalldataField(&frag, input, "a[0][1]")).uint());
    try testing.expectEqual(@as(u256, 3), try (try decodeCalldataField(&frag, input, "0[1][0]")).uint());
    try testing.expectEqualStrings("three", try (try decodeCalldataField(&frag, input, "b[2]")).bytes());
    try testing.expectEqualStrings("two", try (try decodeCalldataField(&frag, input, "1.1")).bytes());
    try testing.expectEqual(@as(usize, 2), try (try decodeCalldataField(&frag, input, "a")).len());

    try testing.expectError(DecoderError.OutOfBounds, decodeCalldataField(&frag, input, "a[2]"));
    try testing.expectError(DecoderError.NoSuchField, decodeCalldataField(&frag, input, "c"));
    try testing.expectError(DecoderError.NoSuchField, decodeCalldataField(&frag, input, "7"));
    for ([_][]const u8{ "a.", "a..b", "a[", "a[x]", "[0]b", ".a" }) |p| {
        if (decodeCalldataField(&frag, input, p)) |_| return error.TestExpectedError else |e| {
            try testing.expect(e == DecoderError.InvalidPath or e == DecoderError.NoSuchField or e == DecoderError.TypeMismatch);
        }
    }
    try testing.expectError(DecoderError.TypeMismatch, (try decodeCalldataField(&frag, input, "a[0][0]")).int());
}

test "REQ-EVM-03 Cursor is flat and does not allocate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frag = try abi.parseSignature(arena.allocator(), "function g(uint256[][] a, string[] b)");
    var buf: [4096]u8 = undefined;
    var cursor = Cursor.init(try calldataRoot(&frag, try unhex(spec_g_input, &buf)));
    var leaves: usize = 0;
    var opens: usize = 0;
    var closes: usize = 0;
    while (try cursor.next()) |item| switch (item.tag) {
        .value => leaves += 1,
        .open => opens += 1,
        .close => closes += 1,
    };
    try testing.expectEqual(@as(usize, 6), leaves);
    // root, a, a[0], a[1], b
    try testing.expectEqual(@as(usize, 5), opens);
    try testing.expectEqual(opens, closes);
}

// Source: ethereum/tests ABITests/basic_abi_tests.json. GithubWikiTest is identical to the spec's f() above.
test "REQ-EVM-03 ethereum/tests basic ABI vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const single = try abi.parseSignature(a, "f(uint256)");
    const pair = try abi.parseSignature(a, "f(uint256,address)");
    var buf: [64]u8 = undefined;
    var dest: [128]u8 = undefined;
    const one = try hex.decodeHex("0000000000000000000000000000000000000000000000000000000005d94e83", &buf);
    try testing.expectEqualStrings("{\"0\":98127491}", try renderJson(.{ .ty = &single.root, .frame = one }, &dest));
    const two = try hex.decodeHex("000000000000000000000000000000000000000000000000000000000004f21c000000000000000000000000cd2a3d9f938e13cd947ec05abc7fe734df8dd826", &buf);
    try testing.expectEqualStrings("{\"0\":324124,\"1\":\"0xcd2a3d9f938e13cd947ec05abc7fe734df8dd826\"}", try renderJson(.{ .ty = &pair.root, .frame = two }, &dest));
}

test "REQ-EVM-03 eth_abi differential cases" {
    var input: [4096]u8 = undefined;
    var dest: [16384]u8 = undefined;
    for (vectors.cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const frag = try abi.parseSignature(arena.allocator(), c.signature);
        const data = try hex.decodeHex(c.data, &input);
        const root: Value = .{ .ty = &frag.root, .frame = data };
        try testing.expectEqualStrings(c.json, try renderJson(root, &dest));
    }
}

test "REQ-EVM-03 real mainnet logs: Uniswap v3 Swap, ERC-20 Transfer, Seaport OrderFulfilled" {
    var seen: [3]bool = @splat(false);
    for (vectors.logs) |l| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const frag = try abi.parseSignature(arena.allocator(), l.signature);
        var topics: [4][32]u8 = undefined;
        for (l.topics, 0..) |t, i| _ = try hex.decodeHex(t, &topics[i]);
        var data: [4096]u8 = undefined;
        var dest: [8192]u8 = undefined;
        const out = try renderLogJson(&frag, topics[0..l.topics.len], try hex.decodeHex(l.data, &data), &dest);
        try testing.expectEqualStrings(l.json, out);
        seen[if (l.name[0] == 'U') 0 else if (l.name[0] == 'E') 1 else 2] = true;
    }
    try testing.expect(seen[0] and seen[1] and seen[2]);
}

test "REQ-EVM-03 log field extraction and topic validation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frag = try abi.parseSignature(a, vectors.logs[2].signature);
    const l = vectors.logs[2];
    var topics: [3][32]u8 = undefined;
    for (l.topics, 0..) |t, i| _ = try hex.decodeHex(t, &topics[i]);
    var data: [256]u8 = undefined;
    const d = try hex.decodeHex(l.data, &data);

    try testing.expectEqualSlices(u8, topics[1][12..], try (try decodeLogField(&frag, &topics, d, "sender")).address());
    try testing.expectEqualSlices(u8, topics[2][12..], try (try decodeLogField(&frag, &topics, d, "1")).address());
    _ = try (try decodeLogField(&frag, &topics, d, "tick")).int();

    try testing.expectError(DecoderError.TopicCount, logRoot(&frag, &.{}, d));
    try testing.expectError(DecoderError.TopicCount, logRoot(&frag, topics[0..2], d));
    var wrong = topics;
    wrong[0][0] ^= 1;
    try testing.expectError(DecoderError.TopicMismatch, logRoot(&frag, &wrong, d));
    var dest: [512]u8 = undefined;
    try testing.expectError(DecoderError.OutOfBounds, renderLogJson(&frag, &topics, d[0..64], &dest));
    const f = try abi.parseSignature(a, "function x()");
    try testing.expectError(DecoderError.KindMismatch, logRoot(&f, &topics, d));
}

test "REQ-EVM-03 flat topics match the array form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frag = try abi.parseSignature(arena.allocator(), "event E(uint8 indexed a, uint b)");
    const topics = frag.hash ++ word(7);
    const data = word(9);
    var dest: [64]u8 = undefined;
    try testing.expectEqualStrings("{\"a\":7,\"b\":9}", try renderLogJsonFlat(&frag, &topics, &data, &dest));
    try testing.expectError(DecoderError.TopicCount, renderLogJsonFlat(&frag, topics[0..33], &data, &dest));
}

test "REQ-EVM-03 indexed reference types surface as their hash, anonymous logs use every topic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frag = try abi.parseSignature(arena.allocator(), "event E(string indexed a, uint[2] indexed b, (uint,bool) indexed c, uint8 indexed d, uint e) anonymous");
    const topics = [_][32]u8{ @splat(0xaa), @splat(0xbb), @splat(0xcc), word(7) };
    const data = word(9);
    var dest: [512]u8 = undefined;
    const out = try renderLogJson(&frag, &topics, &data, &dest);
    const expected = "{\"a\":\"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"b\":\"0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"c\":\"0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"d\":7,\"e\":9}";
    try testing.expectEqualStrings(expected, out);
}

test "REQ-EVM-03 dirty values are rejected, not truncated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Bad = struct { sig: []const u8, word: [32]u8 };
    const bad = [_]Bad{
        .{ .sig = "f(uint8)", .word = word(256) },
        .{ .sig = "f(int8)", .word = word(128) },
        .{ .sig = "f(int8)", .word = word(std.math.maxInt(u256) - 128) },
        .{ .sig = "f(address)", .word = word(1 << 160) },
        .{ .sig = "f(bool)", .word = word(2) },
        .{ .sig = "f(bool)", .word = word(1 << 8) },
        .{ .sig = "f(bytes1)", .word = word(1) },
    };
    var dest: [128]u8 = undefined;
    for (bad) |b| {
        const frag = try abi.parseSignature(a, b.sig);
        try testing.expectError(DecoderError.InvalidValue, renderJson(.{ .ty = &frag.root, .frame = &b.word }, &dest));
    }
    const ok = try abi.parseSignature(a, "f(int8,int256)");
    const edge = word(std.math.maxInt(u256)) ++ word(1 << 255);
    const out = try renderJson(.{ .ty = &ok.root, .frame = &edge }, &dest);
    try testing.expectEqualStrings("{\"0\":-1,\"1\":\"-57896044618658097711785492504343953926634992332820282019728792003956564819968\"}", out);
}

test "REQ-EVM-03 hostile offsets and lengths are typed errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const str = try abi.parseSignature(a, "f(string)");
    const arr = try abi.parseSignature(a, "f(uint[])");
    var dest: [128]u8 = undefined;
    const max = std.math.maxInt(u256);

    const off_big = word(max);
    try testing.expectError(DecoderError.InvalidOffset, renderJson(.{ .ty = &str.root, .frame = &off_big }, &dest));
    const off_past = word(33);
    try testing.expectError(DecoderError.InvalidOffset, renderJson(.{ .ty = &arr.root, .frame = &off_past }, &dest));
    const off_end = word(32);
    try testing.expectError(DecoderError.OutOfBounds, renderJson(.{ .ty = &str.root, .frame = &off_end }, &dest));
    const len_big = word(32) ++ word(max);
    try testing.expectError(DecoderError.InvalidLength, renderJson(.{ .ty = &str.root, .frame = &len_big }, &dest));
    try testing.expectError(DecoderError.InvalidLength, renderJson(.{ .ty = &arr.root, .frame = &len_big }, &dest));
    const len_short = word(32) ++ word(33) ++ word(0);
    try testing.expectError(DecoderError.InvalidLength, renderJson(.{ .ty = &str.root, .frame = &len_short }, &dest));
    try testing.expectError(DecoderError.InvalidLength, renderJson(.{ .ty = &arr.root, .frame = &len_short }, &dest));
    // Elements of a dynamic array need 32 bytes each even when an array of arrays claims more than fit.
    const nested = try abi.parseSignature(a, "f(uint[][])");
    try testing.expectError(DecoderError.InvalidLength, renderJson(.{ .ty = &nested.root, .frame = &len_short }, &dest));
    // A word-sized offset of exactly the end is legal for an empty tail only if the length word exists.
    const unpadded = word(32) ++ word(1) ++ [_]u8{'x'};
    try testing.expectEqualStrings("{\"0\":\"x\"}", try renderJson(.{ .ty = &str.root, .frame = &unpadded }, &dest));
}

test "REQ-EVM-03 shared tails are accepted, overlap cannot go exponential" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dest: [8192]u8 = undefined;

    // Two strings pointing at one tail: legal for decoders, seen from compacting encoders.
    const two = try abi.parseSignature(a, "f(string,string)");
    const shared = word(64) ++ word(64) ++ word(1) ++ word(0x61 << 248);
    try testing.expectEqualStrings("{\"0\":\"a\",\"1\":\"a\"}", try renderJson(.{ .ty = &two.root, .frame = &shared }, &dest));

    // Each of 14 levels is two elements pointing at the same next level: 2^14 leaves from 43 words if walked naively.
    const frag = try abi.parseSignature(a, "f(uint[][][][][][][][][][][][][][])");
    var data: [32 * 43]u8 = @splat(0);
    data[0..32].* = word(32);
    for (0..14) |level| {
        data[32 + level * 96 ..][0..32].* = word(2);
        data[64 + level * 96 ..][0..32].* = word(64);
        data[96 + level * 96 ..][0..32].* = word(64);
    }
    var big: [1 << 16]u8 = undefined;
    const start = Value{ .ty = &frag.root, .frame = &data };
    var cursor = Cursor.init(start);
    var steps: usize = 0;
    const result: DecoderError!void = while (true) {
        const item = cursor.next() catch |e| break e;
        if (item == null) break {};
        steps += 1;
    };
    try testing.expectError(DecoderError.WorkExceeded, result);
    try testing.expect(steps <= 2 * data.len);
    try testing.expectError(DecoderError.WorkExceeded, renderJson(start, &big));
}

test "REQ-EVM-03 renderJson refuses to truncate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frag = try abi.parseSignature(arena.allocator(), "function g(uint256[][] a, string[] b)");
    var buf: [4096]u8 = undefined;
    const input = try unhex(spec_g_input, &buf);
    var dest: [64]u8 = undefined;
    const full = try renderCalldataJson(&frag, input, &dest);
    var i: usize = 0;
    while (i < full.len) : (i += 1) {
        var small: [64]u8 = undefined;
        try testing.expectError(DecoderError.BufferTooSmall, renderCalldataJson(&frag, input, small[0..i]));
    }
}

test "REQ-EVM-03 renderJson escapes strings and refuses invalid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frag = try abi.parseSignature(arena.allocator(), "f(string s)");
    var dest: [128]u8 = undefined;
    const quoted = word(32) ++ word(4) ++ word(@as(u256, 0x22_5c_0a_41) << 224);
    try testing.expectEqualStrings("{\"s\":\"\\\"\\\\\\u000aA\"}", try renderJson(.{ .ty = &frag.root, .frame = &quoted }, &dest));
    const invalid = word(32) ++ word(1) ++ word(@as(u256, 0xff) << 248);
    try testing.expectError(DecoderError.InvalidUtf8, renderJson(.{ .ty = &frag.root, .frame = &invalid }, &dest));
    try testing.expectEqualStrings("\xff", try (try decodeField(.{ .ty = &frag.root, .frame = &invalid }, "s")).bytes());
}

test "REQ-EVM-03 integers switch to strings beyond 2^53" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frag = try abi.parseSignature(arena.allocator(), "f(uint64 a, uint64 b)");
    const data = word(1 << 53) ++ word((1 << 53) + 1);
    var dest: [64]u8 = undefined;
    try testing.expectEqualStrings("{\"a\":9007199254740992,\"b\":\"9007199254740993\"}", try renderJson(.{ .ty = &frag.root, .frame = &data }, &dest));
}

/// Fragments and paths the decoder stress and fuzz tests run every input through.
const Bound = struct {
    frags: [5]Fragment,

    const signatures = [_][]const u8{
        vectors.logs[2].signature,
        vectors.logs[3].signature,
        "function g(uint256[][] a, string[] b)",
        "function n(((uint8,string)[2],bytes)[][] a, bytes32[3] b, (bool,int24) c)",
        "function d(uint[][][][][][][][][][][][][][] a)",
    };

    fn init(allocator: std.mem.Allocator) !Bound {
        var self: Bound = undefined;
        for (signatures, &self.frags) |s, *f| f.* = try abi.parseSignature(allocator, s);
        return self;
    }
};

fn decodeAll(bound: *const Bound, data: []const u8) void {
    var dest: [2048]u8 = undefined;
    const topics = [_][32]u8{ @splat(0), @splat(0) };
    const paths = [_][]const u8{ "", "0", "1", "a[0]", "a[1][0]", "0[0].0[1].1", "a[0][0].1", "b[2]", "offer[0].token", "consideration[1].recipient", "c.1", "tick" };
    for (&bound.frags) |*frag| {
        const root: Value = .{ .ty = &frag.root, .frame = data, .topics = if (frag.indexed > 0) topics[0..frag.indexed] else &.{} };
        _ = renderJson(root, &dest) catch {};
        for (paths) |p| {
            const v = decodeField(root, p) catch continue;
            _ = renderJson(v, &dest) catch {};
        }
        _ = renderCalldataJson(frag, data, &dest) catch {};
        _ = renderLogJson(frag, &topics, data, &dest) catch {};
    }
}

test "REQ-EVM-03 decoder stress" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bound = try Bound.init(a);
    var seeds: std.ArrayList([]const u8) = .empty;
    for (vectors.logs) |l| try seeds.append(a, try hex.decodeHex(l.data, try a.alloc(u8, l.data.len / 2)));
    for (vectors.cases) |c| try seeds.append(a, try hex.decodeHex(c.data, try a.alloc(u8, c.data.len / 2)));
    var spec: [4096]u8 = undefined;
    try seeds.append(a, (try unhex(spec_g_input, &spec))[4..]);
    core_fuzz.stress(200_000, seeds.items, &bound, decodeAll);
}

test "REQ-EVM-03 decoder fuzz" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bound = try Bound.init(arena.allocator());
    try testing.fuzz(&bound, struct {
        fn f(ctx: *const Bound, smith: *testing.Smith) !void {
            var buf: [1024]u8 = undefined;
            decodeAll(ctx, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

fn parseThenDecode(_: void, bytes: []const u8) void {
    // First line is a signature, the rest is data, so hostile types meet hostile bytes.
    const split = std.mem.indexOfScalar(u8, bytes, '\n') orelse return;
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const frag = abi.parseSignature(fba.allocator(), bytes[0..split]) catch return;
    var dest: [1024]u8 = undefined;
    _ = renderJson(.{ .ty = &frag.root, .frame = bytes[split + 1 ..] }, &dest) catch {};
}

test "REQ-EVM-03 signature plus data stress" {
    var seed: [1024]u8 = undefined;
    const prefix = "f(((uint8,string)[2],bytes)[][],bytes32[3],(bool,int24))\n";
    @memcpy(seed[0..prefix.len], prefix);
    for (prefix.len..seed.len) |i| seed[i] = if (i % 32 == 31) 32 else 0;
    core_fuzz.stress(200_000, &.{&seed}, {}, parseThenDecode);
}

test "REQ-EVM-03 signature plus data fuzz" {
    try testing.fuzz({}, struct {
        fn f(_: void, smith: *testing.Smith) !void {
            var buf: [512]u8 = undefined;
            parseThenDecode({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}
