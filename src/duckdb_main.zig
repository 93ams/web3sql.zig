//! DuckDB C-API extension: registers every catalogue function as a vectorized scalar.
const std = @import("std");
const web3sql = @import("web3sql");
const c = @import("duckdb_c");

const catalog = web3sql.targets.catalog;
const Function = catalog.Function;

/// Pinned stable C-API version; must match the vendored header and the footer in build.zig.
const API_VERSION = "v1.5.6";
const ROW_OUTPUT_LIMIT = 64 * 1024;

/// A copy, as in DUCKDB_EXTENSION_API_INIT: `get_api` returns memory that only lives during init.
var api: c.duckdb_ext_api_v1 = undefined;

/// Parsed schema shared by copies of DuckDB's bind data, freed when the last copy goes.
const BindState = struct {
    arena: std.heap.ArenaAllocator,
    schema: *const anyopaque,
    refs: std.atomic.Value(u32) = .init(1),
};

fn destroyBind(ptr: ?*anyopaque) callconv(.c) void {
    const state: *BindState = @ptrCast(@alignCast(ptr.?));
    if (state.refs.fetchSub(1, .acq_rel) == 1) {
        state.arena.deinit();
        std.heap.page_allocator.destroy(state);
    }
}

fn copyBind(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *BindState = @ptrCast(@alignCast(ptr.?));
    _ = state.refs.fetchAdd(1, .monotonic);
    return ptr;
}

/// REQ-DUCK-03: a constant schema argument is parsed exactly once here.
fn bind(info: c.duckdb_bind_info) callconv(.c) void {
    const function: *const Function = @ptrCast(@alignCast(api.duckdb_scalar_function_bind_get_extra_info.?(info)));
    var expr = api.duckdb_scalar_function_bind_get_argument.?(info, 0);
    defer api.duckdb_destroy_expression.?(&expr);
    if (!api.duckdb_expression_is_foldable.?(expr)) return;

    var context: c.duckdb_client_context = null;
    api.duckdb_scalar_function_get_client_context.?(info, &context);
    defer api.duckdb_destroy_client_context.?(&context);
    var value: c.duckdb_value = null;
    var err = api.duckdb_expression_fold.?(context, expr, &value);
    defer if (err != null) api.duckdb_destroy_error_data.?(&err);
    if (err != null) return; // leave it to the per-row path
    defer api.duckdb_destroy_value.?(&value);
    if (api.duckdb_is_null_value.?(value)) return;

    const text = api.duckdb_get_varchar.?(value);
    defer api.duckdb_free.?(text);
    const state = std.heap.page_allocator.create(BindState) catch return;
    state.* = .{ .arena = .init(std.heap.page_allocator), .schema = undefined };
    state.schema = function.prepared.?.prepare(state.arena.allocator(), std.mem.span(text)) catch {
        state.arena.deinit();
        std.heap.page_allocator.destroy(state);
        api.duckdb_scalar_function_bind_set_error.?(info, "web3: invalid schema argument");
        return;
    };
    api.duckdb_scalar_function_set_bind_data.?(info, state, destroyBind);
    api.duckdb_scalar_function_set_bind_data_copy.?(info, copyBind);
}

inline fn stringBytes(s: *c.duckdb_string_t) []const u8 {
    const len = s.value.inlined.length;
    if (len <= 12) return s.value.inlined.inlined[0..len];
    return s.value.pointer.ptr[0..len];
}

const Column = struct {
    data: ?*anyopaque,
    validity: ?[*]u64,
    kind: catalog.ArgType,

    inline fn isValid(self: Column, row: usize) bool {
        const mask = self.validity orelse return true;
        return (mask[row / 64] >> @intCast(row % 64)) & 1 != 0;
    }

    inline fn get(self: Column, row: usize) catalog.Arg {
        return switch (self.kind) {
            .bytes, .text => .{ .bytes = stringBytes(&@as([*]c.duckdb_string_t, @ptrCast(@alignCast(self.data)))[row]) },
            .int => .{ .int = @as([*]i64, @ptrCast(@alignCast(self.data)))[row] },
        };
    }
};

/// Per-chunk cache for a non-constant schema column: rows usually repeat one value.
const SchemaCache = struct {
    key: []const u8 = "",
    schema: ?*const anyopaque = null,
    fba: std.heap.FixedBufferAllocator,

    fn get(self: *SchemaCache, function: *const Function, text: []const u8) catalog.CallError!*const anyopaque {
        if (self.schema) |s| {
            if (std.mem.eql(u8, self.key, text)) return s;
        }
        self.fba.reset();
        self.schema = null;
        const s = try function.prepared.?.prepare(self.fba.allocator(), text);
        self.key = text;
        self.schema = s;
        return s;
    }
};

/// REQ-DUCK-02 / REQ-DUCK-04: one tight loop per chunk; NULL in or any error gives NULL out.
fn execute(info: c.duckdb_function_info, input: c.duckdb_data_chunk, output: c.duckdb_vector) callconv(.c) void {
    const function: *const Function = @ptrCast(@alignCast(api.duckdb_scalar_function_get_extra_info.?(info)));
    const rows = api.duckdb_data_chunk_get_size.?(input);
    const bound: ?*BindState = if (function.prepared != null) @ptrCast(@alignCast(api.duckdb_scalar_function_get_bind_data.?(info))) else null;

    var columns: [8]Column = undefined;
    const argc = function.args.len;
    for (function.args, 0..) |kind, i| {
        const vec = api.duckdb_data_chunk_get_vector.?(input, i);
        columns[i] = .{ .data = api.duckdb_vector_get_data.?(vec), .validity = api.duckdb_vector_get_validity.?(vec), .kind = kind };
    }

    api.duckdb_vector_ensure_validity_writable.?(output);
    const out_validity = api.duckdb_vector_get_validity.?(output);
    const out_data = api.duckdb_vector_get_data.?(output);

    var scratch: [ROW_OUTPUT_LIMIT]u8 = undefined;
    var schema_buf: [32 * 1024]u8 = undefined;
    var cache: SchemaCache = .{ .fba = .init(&schema_buf) };
    var args: [8]catalog.Arg = undefined;

    rows: for (0..rows) |row| {
        for (columns[0..argc], 0..) |col, i| {
            if (!col.isValid(row)) {
                api.duckdb_validity_set_row_invalid.?(out_validity, row);
                continue :rows;
            }
            args[i] = col.get(row);
        }
        const result = if (function.prepared) |p| blk: {
            if (bound) |b| break :blk p.call(b.schema, args[1..argc], &scratch);
            const schema = cache.get(function, args[0].bytes) catch |e| break :blk @as(catalog.CallError!catalog.Out, e);
            break :blk p.call(schema, args[1..argc], &scratch);
        } else function.call(args[0..argc], &scratch);
        const value = result catch {
            api.duckdb_validity_set_row_invalid.?(out_validity, row);
            continue;
        };
        switch (function.ret) {
            .bytes, .text => api.duckdb_vector_assign_string_element_len.?(output, row, value.bytes.ptr, value.bytes.len),
            .boolean => @as([*]bool, @ptrCast(out_data))[row] = value.boolean,
            .int => @as([*]i64, @ptrCast(@alignCast(out_data)))[row] = value.int,
        }
    }
}

fn logicalType(kind: anytype) c.duckdb_logical_type {
    const t: c.duckdb_type = switch (@tagName(kind)[0]) {
        'b' => if (std.mem.eql(u8, @tagName(kind), "bytes")) c.DUCKDB_TYPE_BLOB else c.DUCKDB_TYPE_BOOLEAN,
        't' => c.DUCKDB_TYPE_VARCHAR,
        else => c.DUCKDB_TYPE_BIGINT,
    };
    return api.duckdb_create_logical_type.?(t);
}

fn register(conn: c.duckdb_connection, function: *const Function) bool {
    var f = api.duckdb_create_scalar_function.?();
    defer api.duckdb_destroy_scalar_function.?(&f);
    api.duckdb_scalar_function_set_name.?(f, function.name.ptr);
    for (function.args) |kind| {
        var t = logicalType(kind);
        api.duckdb_scalar_function_add_parameter.?(f, t);
        api.duckdb_destroy_logical_type.?(&t);
    }
    var ret = logicalType(function.ret);
    api.duckdb_scalar_function_set_return_type.?(f, ret);
    api.duckdb_destroy_logical_type.?(&ret);
    api.duckdb_scalar_function_set_extra_info.?(f, @constCast(function), null);
    api.duckdb_scalar_function_set_function.?(f, execute);
    if (function.prepared != null) api.duckdb_scalar_function_set_bind.?(f, bind);
    return api.duckdb_register_scalar_function.?(conn, f) == c.DuckDBSuccess;
}

/// DUCKDB_EXTENSION_ENTRYPOINT expanded: `web3_init_c_api`, resolved by name from the extension file.
export fn web3_init_c_api(info: c.duckdb_extension_info, access: *c.struct_duckdb_extension_access) callconv(.c) bool {
    const raw = access.get_api.?(info, API_VERSION) orelse return false; // DuckDB sets the error
    api = @as(*const c.duckdb_ext_api_v1, @ptrCast(@alignCast(raw))).*;
    var conn: c.duckdb_connection = null;
    if (api.duckdb_connect.?(access.get_database.?(info).*, &conn) != c.DuckDBSuccess) {
        access.set_error.?(info, "web3: could not open a connection");
        return false;
    }
    defer api.duckdb_disconnect.?(&conn);
    for (web3sql.targets.functions) |*function| {
        if (!register(conn, function)) {
            access.set_error.?(info, "web3: function registration failed");
            return false;
        }
    }
    return true;
}
