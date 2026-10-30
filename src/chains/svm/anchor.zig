const std = @import("std");
const sha256 = @import("../../core/crypto/sha256.zig");

pub const Discriminator = [8]u8;

pub const AnchorError = error{NameTooLong};

/// Longest instruction/account/event name accepted (Rust identifiers are far shorter).
pub const MAX_NAME_LEN = 100;

/// Anchor discriminator: sha256("<prefix>:<name>")[..8].
pub fn computeDiscriminator(name: []const u8, prefix: []const u8) AnchorError!Discriminator {
    var preimage_buf: [128]u8 = undefined;
    if (name.len > MAX_NAME_LEN or prefix.len + 1 + name.len > preimage_buf.len) return AnchorError.NameTooLong;
    const preimage = std.fmt.bufPrint(&preimage_buf, "{s}:{s}", .{ prefix, name }) catch unreachable;
    var hash_buf: [32]u8 = undefined;
    sha256.hash(preimage, &hash_buf);
    return hash_buf[0..8].*;
}

/// Standard global instruction discriminator.
pub fn instructionDiscriminator(instruction_name: []const u8) AnchorError!Discriminator {
    return computeDiscriminator(instruction_name, "global");
}

/// Standard account discriminator.
pub fn accountDiscriminator(account_name: []const u8) AnchorError!Discriminator {
    return computeDiscriminator(account_name, "account");
}

/// Event discriminator used by `emit!`/`emit_cpi!` logs.
pub fn eventDiscriminator(event_name: []const u8) AnchorError!Discriminator {
    return computeDiscriminator(event_name, "event");
}

test "REQ-SVM-02 anchor discriminators" {
    // Well-known: global:initialize -> [175,175,109,31,13,152,155,237]
    try std.testing.expectEqual(Discriminator{ 175, 175, 109, 31, 13, 152, 155, 237 }, try instructionDiscriminator("initialize"));
    const long: [MAX_NAME_LEN + 1]u8 = @splat('a');
    try std.testing.expectError(AnchorError.NameTooLong, instructionDiscriminator(&long));
}
