//! Throughput baselines. Run `zig build bench`; numbers are recorded in docs/PERF.md.
const std = @import("std");
const web3sql = @import("web3sql");

const core = web3sql.core;

const Bench = struct {
    io: std.Io,

    /// Runs `body` repeatedly for ~200ms and prints throughput; `bytes` is per-call payload (0 = ops only).
    fn run(self: Bench, name: []const u8, bytes: usize, ctx: anytype, comptime body: fn (@TypeOf(ctx)) void) void {
        const start = std.Io.Clock.awake.now(self.io);
        var calls: u64 = 0;
        var elapsed_ns: u64 = 0;
        while (elapsed_ns < 200 * std.time.ns_per_ms) {
            for (0..64) |_| body(ctx);
            calls += 64;
            elapsed_ns = @intCast(start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds());
        }
        const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const ops = @as(f64, @floatFromInt(calls)) / seconds;
        if (bytes == 0) {
            std.debug.print("{s:<28} {d:>12.0} ops/s\n", .{ name, ops });
        } else {
            std.debug.print("{s:<28} {d:>12.0} ops/s {d:>10.1} MB/s\n", .{ name, ops, ops * @as(f64, @floatFromInt(bytes)) / 1e6 });
        }
    }
};

var sink: u8 = 0;
var input_4k: [4096]u8 = undefined;
var hex_4k: [8192]u8 = undefined;
var b64_4k: [5464]u8 = undefined;

fn consume(digest: []const u8) void {
    sink +%= digest[0];
    std.mem.doNotOptimizeAway(sink);
}

pub fn main(init: std.process.Init) !void {
    const b = Bench{ .io = init.io };
    for (&input_4k, 0..) |*x, i| x.* = @truncate(i *% 0x9E37);
    _ = try core.encodings.hex.encodeHex(&input_4k, &hex_4k);
    _ = try core.encodings.base64.encodeBase64(&input_4k, &b64_4k);

    b.run("keccak256 32B", 32, {}, struct {
        fn f(_: void) void {
            var d: [32]u8 = undefined;
            core.crypto.keccak.hash(input_4k[0..32], &d);
            consume(&d);
        }
    }.f);
    b.run("keccak256 4KiB", 4096, {}, struct {
        fn f(_: void) void {
            var d: [32]u8 = undefined;
            core.crypto.keccak.hash(&input_4k, &d);
            consume(&d);
        }
    }.f);
    b.run("sha256 4KiB", 4096, {}, struct {
        fn f(_: void) void {
            var d: [32]u8 = undefined;
            core.crypto.sha256.hash(&input_4k, &d);
            consume(&d);
        }
    }.f);
    b.run("blake3 4KiB", 4096, {}, struct {
        fn f(_: void) void {
            var d: [32]u8 = undefined;
            core.crypto.blake3.hash(&input_4k, &d);
            consume(&d);
        }
    }.f);
    b.run("blake2b256 4KiB", 4096, {}, struct {
        fn f(_: void) void {
            var d: [32]u8 = undefined;
            core.crypto.blake2b.hash(&input_4k, &d);
            consume(&d);
        }
    }.f);
    b.run("ripemd160 4KiB", 4096, {}, struct {
        fn f(_: void) void {
            var d: [20]u8 = undefined;
            core.crypto.ripemd160.hash(&input_4k, &d);
            consume(&d);
        }
    }.f);
    b.run("hex encode 4KiB", 4096, {}, struct {
        fn f(_: void) void {
            var out: [8192]u8 = undefined;
            consume(core.encodings.hex.encodeHex(&input_4k, &out) catch unreachable);
        }
    }.f);
    b.run("hex decode 4KiB", 4096, {}, struct {
        fn f(_: void) void {
            var out: [4096]u8 = undefined;
            consume(core.encodings.hex.decodeHex(&hex_4k, &out) catch unreachable);
        }
    }.f);
    b.run("base64 decode 4KiB", 4096, {}, struct {
        fn f(_: void) void {
            var out: [4096]u8 = undefined;
            consume(core.encodings.base64.decodeBase64(&b64_4k, &out) catch unreachable);
        }
    }.f);
    b.run("base58 encode 32B", 32, {}, struct {
        fn f(_: void) void {
            var out: [64]u8 = undefined;
            consume(core.encodings.base58.encodeBase58(input_4k[0..32], &out) catch unreachable);
        }
    }.f);
    b.run("base58 decode 32B", 32, {}, struct {
        fn f(_: void) void {
            var out: [64]u8 = undefined;
            consume(core.encodings.base58.decodeBase58("4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi", &out) catch unreachable);
        }
    }.f);
    b.run("mulDiv u256", 0, {}, struct {
        fn f(_: void) void {
            const a = std.mem.readInt(u256, input_4k[0..32], .little);
            const c = std.mem.readInt(u256, input_4k[32..64], .little) | 1;
            consume(&core.math.toBytes(core.math.mulDiv(a >> 1, c >> 1, c) catch 0, .little));
        }
    }.f);
    b.run("decimal format u256", 0, {}, struct {
        fn f(_: void) void {
            var out: [core.math.MAX_DECIMAL_LEN]u8 = undefined;
            consume(core.math.formatDecimal(std.mem.readInt(u256, input_4k[0..32], .little), &out) catch unreachable);
        }
    }.f);
}
