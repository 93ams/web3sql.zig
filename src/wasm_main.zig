//! WASM UDF ABI. Hosts: `web3_free()`, `web3_alloc` for an argv of `Slot`s, each argument and the
//! output buffer, then `<function>(argv, argc, out, cap)`, which returns the output length or -1.
const std = @import("std");
const web3sql = @import("web3sql");

const catalog = web3sql.targets.catalog;
const functions = web3sql.targets.wasm_functions;

/// `ptr`/`len` of a byte argument, or the low/high halves of an int argument.
const Slot = extern struct { ptr: u32, len: u32 };

const SCRATCH_LEN = 60 * 1024;
const SCHEMA_ARENA_LEN = 32 * 1024;

var scratch: [SCRATCH_LEN]u8 align(16) = undefined;
var used: usize = 0;

var schema_arena: [SCHEMA_ARENA_LEN]u8 = undefined;
var schema_key: [4096]u8 = undefined;
var schema_key_len: usize = 0;
var schema_owner: ?*const anyopaque = null;
var schema_value: *const anyopaque = undefined;

/// Bump allocation out of the row scratch; returns 0 when full, which the host maps to NULL.
export fn web3_alloc(len: u32) u32 {
    const start = std.mem.alignForward(usize, used, 8);
    if (len > SCRATCH_LEN - @min(start, SCRATCH_LEN)) return 0;
    used = start + len;
    return @intFromPtr(&scratch) + start;
}

/// Releases everything `web3_alloc` handed out. Called once per row.
export fn web3_free() void {
    used = 0;
}

/// Bytes still available, so the host can give the rest to the output buffer.
export fn web3_available() u32 {
    return @intCast(SCRATCH_LEN - @min(std.mem.alignForward(usize, used, 8), SCRATCH_LEN));
}

fn slotBytes(s: Slot) []const u8 {
    if (s.len == 0) return &.{};
    return @as([*]const u8, @ptrFromInt(s.ptr))[0..s.len];
}

fn cachedSchema(comptime f: *const catalog.Function, text: []const u8) catalog.CallError!*const anyopaque {
    const owner: *const anyopaque = @ptrCast(f.prepared.?.prepare);
    if (schema_owner == owner and std.mem.eql(u8, schema_key[0..schema_key_len], text)) return schema_value;
    schema_owner = null;
    var fba = std.heap.FixedBufferAllocator.init(&schema_arena);
    const parsed = try f.prepared.?.prepare(fba.allocator(), text);
    // A schema too long to key is parsed but not cached.
    if (text.len <= schema_key.len) {
        @memcpy(schema_key[0..text.len], text);
        schema_key_len = text.len;
        schema_value = parsed;
        schema_owner = owner;
    }
    return parsed;
}

// Comptime, so an export references only its own function: sql_gen links each one alone.
inline fn dispatch(comptime f: *const catalog.Function, argv: [*]const Slot, argc: u32, out: [*]u8, cap: u32) i32 {
    if (argc != f.args.len or argc > 8) return -1;
    var args: [8]catalog.Arg = undefined;
    for (f.args, argv[0..argc], 0..) |kind, slot, i| {
        args[i] = switch (kind) {
            .bytes, .text => .{ .bytes = slotBytes(slot) },
            .int, .boolean => .{ .int = @bitCast((@as(u64, slot.len) << 32) | slot.ptr) },
        };
    }
    const dest = out[0..cap];
    const value = blk: {
        if (f.prepared) |p| {
            const schema = cachedSchema(f, args[0].bytes) catch return -1;
            break :blk p.call(schema, args[1..argc], dest) catch return -1;
        }
        break :blk f.call(args[0..argc], dest) catch return -1;
    };
    switch (f.ret) {
        .bytes, .text => {
            if (value.bytes.len > cap) return -1; // a slice of the argument can outgrow `dest`
            if (value.bytes.ptr != dest.ptr) std.mem.copyForwards(u8, dest[0..value.bytes.len], value.bytes);
            return @intCast(value.bytes.len);
        },
        .boolean => {
            if (cap < 1) return -1;
            out[0] = @intFromBool(value.boolean);
            return 1;
        },
        .int => {
            if (cap < 8) return -1;
            std.mem.writeInt(i64, out[0..8], value.int, .little);
            return 8;
        },
    }
}

fn Export(comptime index: usize) type {
    return struct {
        fn call(argv: [*]const Slot, argc: u32, out: [*]u8, cap: u32) callconv(.c) i32 {
            return dispatch(comptime &functions[index], argv, argc, out, cap);
        }
    };
}

comptime {
    for (functions, 0..) |*f, i| @export(&Export(i).call, .{ .name = f.name });
}
