//! The SQL function table. DuckDB, WASM and the SQL generators all read this, so they cannot drift.
const std = @import("std");

/// SQL-facing argument kinds: BLOB, VARCHAR and BIGINT in DuckDB.
pub const ArgType = enum { bytes, text, int };
/// SQL-facing return kinds: BLOB, VARCHAR, BOOLEAN and BIGINT in DuckDB.
pub const RetType = enum { bytes, text, boolean, int };

pub const Arg = union { bytes: []const u8, int: i64 };
pub const Out = union { bytes: []const u8, boolean: bool, int: i64 };

/// Every library error becomes this at the target layer, which maps it to SQL NULL (REQ-DUCK-04).
pub const CallError = error{Failed};

pub const Function = struct {
    name: [:0]const u8,
    doc: []const u8,
    args: []const ArgType,
    ret: RetType,
    call: *const fn (args: []const Arg, dest: []u8) CallError!Out,
    /// Set when the first argument is a schema (ABI, IDL, ...): hosts parse it once with `prepare`
    /// and call `call_prepared` per row with the remaining arguments.
    prepared: ?Prepared = null,
};

pub const Prepared = struct {
    prepare: *const fn (gpa: std.mem.Allocator, schema: []const u8) CallError!*const anyopaque,
    call: *const fn (schema: *const anyopaque, args: []const Arg, dest: []u8) CallError!Out,
};

fn ReturnPayload(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |e| e.payload,
        else => R,
    };
}

fn toOut(value: anytype, comptime ret: RetType) CallError!Out {
    return switch (ret) {
        .bytes, .text => .{ .bytes = value },
        .boolean => .{ .boolean = value },
        .int => .{ .int = std.math.cast(i64, value) orelse return error.Failed },
    };
}

/// Adapts `impl(<one param per arg>, [dest: []u8])` to the uniform call shape.
fn Adapter(comptime impl: anytype, comptime skip: usize, comptime ret: RetType) type {
    const F = @TypeOf(impl);
    const params = @typeInfo(F).@"fn".param_types;
    return struct {
        fn invoke(prefix: anytype, args: []const Arg, dest: []u8) CallError!Out {
            var tuple: std.meta.ArgsTuple(F) = undefined;
            for (0..skip) |i| tuple[i] = prefix[i];
            inline for (params[skip..], skip..) |P, i| {
                const T = P.?;
                if (T == i64) {
                    tuple[i] = args[i - skip].int;
                } else if (T == []const u8) {
                    tuple[i] = args[i - skip].bytes;
                } else if (T == []u8) {
                    tuple[i] = dest;
                } else if (@typeInfo(T) == .int) {
                    tuple[i] = std.math.cast(T, args[i - skip].int) orelse return error.Failed;
                } else {
                    @compileError("unsupported catalogue parameter type " ++ @typeName(T));
                }
            }
            const result = @call(.auto, impl, tuple);
            const value = if (@typeInfo(@TypeOf(result)) == .error_union) (result catch return error.Failed) else result;
            return toOut(value, ret);
        }
        fn call(args: []const Arg, dest: []u8) CallError!Out {
            return invoke(.{}, args, dest);
        }
    };
}

/// A plain row function.
pub fn func(comptime name: [:0]const u8, comptime doc: []const u8, comptime args: []const ArgType, comptime ret: RetType, comptime impl: anytype) Function {
    comptime std.debug.assert(ReturnPayload(@TypeOf(impl)) != void);
    return .{ .name = name, .doc = doc, .args = args, .ret = ret, .call = Adapter(impl, 0, ret).call };
}

/// A row function whose first SQL argument is a schema parsed once by `parse`.
pub fn schemaFunc(comptime name: [:0]const u8, comptime doc: []const u8, comptime args: []const ArgType, comptime ret: RetType, comptime parse: anytype, comptime impl: anytype) Function {
    const Ptr = ReturnPayload(@TypeOf(parse));
    const S = struct {
        fn prepare(gpa: std.mem.Allocator, schema: []const u8) CallError!*const anyopaque {
            const p: Ptr = parse(gpa, schema) catch return error.Failed;
            return @ptrCast(p);
        }
        fn prepared(schema: *const anyopaque, row: []const Arg, dest: []u8) CallError!Out {
            const p: Ptr = @ptrCast(@alignCast(schema));
            return Adapter(impl, 1, ret).invoke(.{p}, row, dest);
        }
        // Uncached route for hosts with no bind phase. 32 KB covers the largest schema M7 accepts.
        fn direct(all: []const Arg, dest: []u8) CallError!Out {
            var buf: [32 * 1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            return prepared(try prepare(fba.allocator(), all[0].bytes), all[1..], dest);
        }
    };
    return .{ .name = name, .doc = doc, .args = args, .ret = ret, .call = S.direct, .prepared = .{ .prepare = S.prepare, .call = S.prepared } };
}

test "catalog adapter maps params and errors" {
    const impl = struct {
        fn f(a: []const u8, n: u8, dest: []u8) error{Bad}![]const u8 {
            if (n == 0) return error.Bad;
            dest[0] = a[0] +% n;
            return dest[0..1];
        }
    }.f;
    const entry = func("t", "doc", &.{ .bytes, .int }, .bytes, impl);
    var buf: [4]u8 = undefined;
    const out = try entry.call(&.{ .{ .bytes = "a" }, .{ .int = 1 } }, &buf);
    try std.testing.expectEqualStrings("b", out.bytes);
    try std.testing.expectError(error.Failed, entry.call(&.{ .{ .bytes = "a" }, .{ .int = 0 } }, &buf));
    try std.testing.expectError(error.Failed, entry.call(&.{ .{ .bytes = "a" }, .{ .int = 300 } }, &buf));
}
