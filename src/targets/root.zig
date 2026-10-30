const std = @import("std");
const build_options = @import("build_options");

pub const catalog = @import("catalog.zig");
pub const wasm_udf = @import("wasm_udf/bindings.zig");

const sections = [_]struct { enabled: bool, path: type }{
    .{ .enabled = true, .path = @import("functions_core.zig") },
    .{ .enabled = build_options.chain_svm, .path = if (build_options.chain_svm) @import("functions_svm.zig") else void },
    .{ .enabled = build_options.chain_move, .path = if (build_options.chain_move) @import("functions_move.zig") else void },
    .{ .enabled = build_options.chain_utxo, .path = if (build_options.chain_utxo) @import("functions_utxo.zig") else void },
    .{ .enabled = build_options.chain_cosmos, .path = if (build_options.chain_cosmos) @import("functions_cosmos.zig") else void },
};

/// Every function enabled by the build flags.
pub const functions: []const catalog.Function = blk: {
    @setEvalBranchQuota(100_000);
    var all: []const catalog.Function = &.{};
    for (sections) |s| {
        if (s.enabled) all = all ++ &s.path.entries;
    }
    break :blk all;
};

/// The subset shipped in web3_sql.wasm and the warehouse scripts.
pub const wasm_functions = catalog.wasmFunctions(functions);

test {
    _ = @import("catalog.zig");
    _ = @import("wasm_udf/bindings.zig");
    inline for (sections) |s| {
        if (s.enabled) _ = s.path;
    }
}

test "catalogue names are unique and prefixed" {
    for (functions, 0..) |a, i| {
        try std.testing.expect(std.mem.startsWith(u8, a.name, "web3_"));
        for (functions[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    }
}
