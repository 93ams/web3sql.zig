//! Deterministic mutation stress, the in-tree proof that decoders survive hostile bytes under
//! Debug safety checks. Complements `std.testing.fuzz`, which only runs one input without `--fuzz`.
const std = @import("std");

/// Copies `seed` into `buf` and applies a few random byte flips, truncations or length-field smashes.
pub fn mutate(rand: std.Random, seed: []const u8, buf: []u8) []u8 {
    const n = @min(seed.len, buf.len);
    @memcpy(buf[0..n], seed[0..n]);
    var len = n;
    for (0..rand.intRangeAtMost(usize, 1, 8)) |_| {
        if (len == 0) break;
        const at = rand.uintLessThan(usize, len);
        switch (rand.uintLessThan(u8, 5)) {
            0 => buf[at] = rand.int(u8),
            1 => buf[at] ^= @as(u8, 1) << rand.int(u3),
            2 => buf[at] = 0xFF,
            3 => buf[at] = 0,
            else => len = at + 1,
        }
    }
    return buf[0..len];
}

/// Calls `decode(ctx, bytes)` on `iterations` mutants drawn from `seeds` plus pure noise.
/// `decode` must swallow its own errors; a panic or safety trap fails the test.
pub fn stress(comptime iterations: usize, seeds: []const []const u8, ctx: anytype, comptime decode: fn (@TypeOf(ctx), []const u8) void) void {
    var prng = std.Random.DefaultPrng.init(0x66757a7a);
    const rand = prng.random();
    var buf: [4096]u8 = undefined;
    for (0..iterations) |i| {
        if (seeds.len == 0 or i % 8 == 0) {
            const n = rand.uintAtMost(usize, 256);
            rand.bytes(buf[0..n]);
            decode(ctx, buf[0..n]);
        } else {
            decode(ctx, mutate(rand, seeds[i % seeds.len], &buf));
        }
    }
}

test "mutate stays in bounds" {
    stress(10_000, &.{"seed bytes"}, {}, struct {
        fn f(_: void, bytes: []const u8) void {
            std.debug.assert(bytes.len <= 4096);
        }
    }.f);
}
