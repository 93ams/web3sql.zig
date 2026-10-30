const std = @import("std");
const web3sql = @import("web3sql");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("web3sql.zig: High-performance blockchain SQL & binary decoding library initialized.\n", .{});
}

test "main module smoke test" {
    try std.testing.expect(true);
}
