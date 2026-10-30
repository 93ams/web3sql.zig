const std = @import("std");

pub const Keccak256 = std.crypto.hash.sha3.Keccak256;
pub const DIGEST_LENGTH: usize = Keccak256.digest_length;

/// Computes zero-allocation Keccak-256 hash.
pub fn hash(data: []const u8, out: *[DIGEST_LENGTH]u8) void {
    Keccak256.hash(data, out, .{});
}

/// Hashes each input into the matching output slot. `inputs.len` must equal `outs.len`.
pub fn hashBatch(inputs: []const []const u8, outs: [][DIGEST_LENGTH]u8) void {
    std.debug.assert(inputs.len == outs.len);
    for (inputs, outs) |input, *out| hash(input, out);
}

test "keccak256 empty string" {
    var out: [DIGEST_LENGTH]u8 = undefined;
    hash("", &out);
    // keccak256("") = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const expected = "\xc5\xd2\x46\x01\x86\xf7\x23\x3c\x92\x7e\x7d\xb2\xdc\xc7\x03\xc0\xe5\x00\xb6\x53\xca\x82\x27\x3b\x7b\xfa\xd8\x04\x5d\x85\xa4\x70";
    try std.testing.expectEqualStrings(expected, &out);
}

test "REQ-CORE-03 keccak streaming and batch agree with one-shot" {
    var one: [DIGEST_LENGTH]u8 = undefined;
    hash("hello world, this spans more than one update", &one);
    var s = Keccak256.init(.{});
    s.update("hello world, ");
    s.update("this spans more than one update");
    var two: [DIGEST_LENGTH]u8 = undefined;
    s.final(&two);
    try std.testing.expectEqualSlices(u8, &one, &two);

    var outs: [2][DIGEST_LENGTH]u8 = undefined;
    hashBatch(&.{ "", "hello world, this spans more than one update" }, &outs);
    try std.testing.expectEqualSlices(u8, &one, &outs[1]);
}
