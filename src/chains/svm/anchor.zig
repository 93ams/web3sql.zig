const std = @import("std");
const sha256 = @import("../../core/crypto/sha256.zig");
const base64 = @import("../../core/encodings/base64.zig");

pub const Discriminator = [8]u8;

pub const AnchorError = error{ NameTooLong, NotProgramData, InvalidBase64, BufferTooSmall };

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

/// Prefix Anchor's `emit!` log line carries before the base64 payload.
pub const PROGRAM_DATA_PREFIX = "Program data: ";

/// `emit_cpi!` self-invocation instruction data starts with these 8 bytes, then the event discriminator and payload.
pub const EVENT_IX_TAG: Discriminator = .{ 0xe4, 0x45, 0xa5, 0x2e, 0x51, 0xcb, 0x9a, 0x1d };

/// Decodes a `Program data: <base64>` log line (as found in transaction logs) into `dest`.
/// The result is discriminator || Borsh payload.
pub fn decodeProgramData(line: []const u8, dest: []u8) AnchorError![]u8 {
    if (!std.mem.startsWith(u8, line, PROGRAM_DATA_PREFIX)) return AnchorError.NotProgramData;
    return base64.decode(.standard, line[PROGRAM_DATA_PREFIX.len..], dest) catch |e| switch (e) {
        error.BufferTooSmall => AnchorError.BufferTooSmall,
        else => AnchorError.InvalidBase64,
    };
}

/// For `emit_cpi!` instruction data: strips `EVENT_IX_TAG`, leaving event discriminator || payload.
pub fn stripEventCpiTag(ix_data: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, ix_data, &EVENT_IX_TAG)) ix_data[EVENT_IX_TAG.len..] else null;
}

test "REQ-SVM-02 anchor discriminators" {
    // Well-known: global:initialize -> [175,175,109,31,13,152,155,237]
    try std.testing.expectEqual(Discriminator{ 175, 175, 109, 31, 13, 152, 155, 237 }, try instructionDiscriminator("initialize"));
    const long: [MAX_NAME_LEN + 1]u8 = @splat('a');
    try std.testing.expectError(AnchorError.NameTooLong, instructionDiscriminator(&long));
}

test "REQ-SVM-02 anchor program data log and event cpi tag" {
    // base64 of the 12 bytes below, computed independently with Python's base64 module.
    const ev = [_]u8{ 96, 184, 197, 243, 139, 2, 90, 148, 9, 0, 0, 0 };
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &ev, try decodeProgramData("Program data: YLjF84sCWpQJAAAA", &buf));
    try std.testing.expectEqual(try eventDiscriminator("MyEvent"), ev[0..8].*);
    try std.testing.expectError(AnchorError.NotProgramData, decodeProgramData("Program log: hi", &buf));
    try std.testing.expectError(AnchorError.InvalidBase64, decodeProgramData("Program data: !!!!", &buf));
    var small: [4]u8 = undefined;
    try std.testing.expectError(AnchorError.BufferTooSmall, decodeProgramData("Program data: YLjF84sCWpQJAAAA", &small));
    try std.testing.expectEqualSlices(u8, &ev, stripEventCpiTag(&(EVENT_IX_TAG ++ ev)).?);
    try std.testing.expect(stripEventCpiTag(&ev) == null);
}
