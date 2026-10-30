//! Fails when the wasm bundle reaches the REQ-WASM-02 budget.
const std = @import("std");

const LIMIT = 250_000;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const stat = try std.Io.Dir.cwd().statFile(init.io, args[1], .{});
    std.debug.print("web3_sql.wasm: {d} bytes (limit {d})\n", .{ stat.size, LIMIT });
    if (stat.size >= LIMIT) std.process.exit(1);
}
