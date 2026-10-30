pub const catalog = @import("catalog.zig");
pub const wasm_udf = @import("wasm_udf/bindings.zig");

/// Every function enabled by the build flags.
pub const functions = @import("functions_core.zig").entries;

test {
    _ = @import("catalog.zig");
    _ = @import("functions_core.zig");
    _ = @import("wasm_udf/bindings.zig");
}
