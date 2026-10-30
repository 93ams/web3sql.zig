const std = @import("std");
const build_options = @import("build_options");

pub const catalog = @import("catalog.zig");
pub const wasm_udf = @import("wasm_udf/bindings.zig");

const sections = [_]struct { enabled: bool, path: type }{
    .{ .enabled = true, .path = @import("functions_core.zig") },
    .{ .enabled = build_options.chain_evm, .path = if (build_options.chain_evm) @import("functions_evm.zig") else void },
    .{ .enabled = build_options.chain_svm, .path = if (build_options.chain_svm) @import("functions_svm.zig") else void },
    .{ .enabled = build_options.chain_move, .path = if (build_options.chain_move) @import("functions_move.zig") else void },
    .{ .enabled = build_options.chain_utxo, .path = if (build_options.chain_utxo) @import("functions_utxo.zig") else void },
    .{ .enabled = build_options.chain_cosmos, .path = if (build_options.chain_cosmos) @import("functions_cosmos.zig") else void },
    .{ .enabled = build_options.protocol_clmm, .path = if (build_options.protocol_clmm) @import("functions_clmm.zig") else void },
    .{ .enabled = build_options.protocol_tokens, .path = if (build_options.protocol_tokens) @import("functions_tokens.zig") else void },
    .{ .enabled = build_options.protocol_lending, .path = if (build_options.protocol_lending) @import("functions_lending.zig") else void },
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

test "REQ-DUCK-04 every catalogue function survives hostile arguments and tiny buffers" {
    var prng = std.Random.DefaultPrng.init(0x7734);
    const rand = prng.random();
    var inputs: [8][512]u8 = undefined;
    var dest: [4096]u8 = undefined;
    var args: [8]catalog.Arg = undefined;
    for (functions) |f| {
        for (0..2_000) |_| {
            for (f.args, 0..) |kind, i| {
                if (kind == .int) {
                    args[i] = .{ .int = @bitCast(rand.int(u64) >> rand.int(u6)) };
                    continue;
                }
                const n = rand.uintAtMost(usize, inputs[i].len);
                rand.bytes(inputs[i][0..n]);
                if (kind == .text) for (inputs[i][0..n]) |*c| {
                    c.* = "0123456789abcdefABCDEF,:_x{}<>[];"[c.* % 33];
                };
                args[i] = .{ .bytes = inputs[i][0..n] };
            }
            _ = f.call(args[0..f.args.len], dest[0..rand.uintAtMost(usize, 300)]) catch {};
        }
    }
}

test "row calls take no allocator; schema parsing fails cleanly with none available" {
    // `Function.call` has no allocator parameter, so row paths cannot reach the heap through it.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (functions) |f| {
        const p = f.prepared orelse continue;
        try std.testing.expectError(error.Failed, p.prepare(failing.allocator(), "{a:u8}"));
    }
}
