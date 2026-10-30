pub const duckdb_ext = @import("duckdb_ext/root.zig");
pub const wasm_udf = @import("wasm_udf/root.zig");

test {
    _ = @import("duckdb_ext/root.zig");
    _ = @import("wasm_udf/root.zig");
}
