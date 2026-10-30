const std = @import("std");
const keccak = @import("../../core/crypto/keccak.zig");

pub const WASM_SCRATCH_BUF_SIZE: usize = 65536;

pub fn executeKeccak(input: []const u8, out: *[32]u8) void {
    keccak.hash(input, out);
}

test "wasm bindings helper" {
    var out: [32]u8 = undefined;
    executeKeccak("test", &out);
    try std.testing.expect(out.len == 32);
}
