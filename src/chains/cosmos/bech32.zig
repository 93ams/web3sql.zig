const std = @import("std");
const bech32_core = @import("../../core/encodings/bech32.zig");

const fuzz = @import("../../core/fuzz.zig");

pub const CosmosError = error{
    InvalidBech32,
    WrongHrp,
    BufferTooSmall,
};

/// Max Bech32 string length. shortcut: core enforces the BIP-173 limit of 90, which covers
/// 20 and 32 byte account/validator/contract addresses; Cosmos SDK itself allows longer.
pub const MAX_LENGTH = bech32_core.MAX_LENGTH;

fn mapErr(e: bech32_core.Bech32Error) CosmosError {
    return if (e == error.BufferTooSmall) CosmosError.BufferTooSmall else CosmosError.InvalidBech32;
}

/// Verifies checksum (Bech32, not Bech32m), 8-to-5 padding and a non-empty payload; with
/// `expected_hrp` also checks the prefix. Cosmos SDK `VerifyAddressFormat` semantics.
pub fn validate(address: []const u8, expected_hrp: ?[]const u8) CosmosError!void {
    var hrp_buf: [bech32_core.MAX_HRP_LENGTH]u8 = undefined;
    var data: [MAX_LENGTH]u5 = undefined;
    const d = bech32_core.decode(address, &hrp_buf, &data) catch |e| return mapErr(e);
    if (d.variant != .bech32 or d.data.len == 0) return CosmosError.InvalidBech32;
    var bytes: [MAX_LENGTH]u8 = undefined;
    const raw = bech32_core.fiveToBytes(d.data, &bytes) catch |e| return mapErr(e);
    if (raw.len == 0) return CosmosError.InvalidBech32;
    if (expected_hrp) |h| if (!std.mem.eql(u8, h, d.hrp)) return CosmosError.WrongHrp;
}

/// Re-encodes `address` under `new_hrp` (e.g. cosmos1... to osmo1...), recomputing the checksum.
/// The input is fully validated first. The result is lowercase.
pub fn convertHrp(address: []const u8, new_hrp: []const u8, dest: []u8) CosmosError![]const u8 {
    try validate(address, null);
    var hrp_buf: [bech32_core.MAX_HRP_LENGTH]u8 = undefined;
    var data: [MAX_LENGTH]u5 = undefined;
    const d = bech32_core.decode(address, &hrp_buf, &data) catch |e| return mapErr(e);
    return bech32_core.encode(new_hrp, d.data, .bech32, dest) catch |e| mapErr(e);
}

/// Decodes an address to its raw bytes (20 for accounts/validators, 32 for contracts) and HRP.
pub fn decodeAddress(address: []const u8, hrp_buf: []u8, bytes_buf: []u8) CosmosError!struct { hrp: []const u8, bytes: []const u8 } {
    try validate(address, null);
    var data: [MAX_LENGTH]u5 = undefined;
    const d = bech32_core.decode(address, hrp_buf, &data) catch |e| return mapErr(e);
    const raw = bech32_core.fiveToBytes(d.data, bytes_buf) catch |e| return mapErr(e);
    return .{ .hrp = d.hrp, .bytes = raw };
}

/// Splits a Bech32 cosmos address into its HRP and data parts.
pub fn splitHrp(address: []const u8) CosmosError!struct { hrp: []const u8, data_part: []const u8 } {
    if (address.len < 8) return CosmosError.InvalidBech32;
    const last_one = std.mem.lastIndexOfScalar(u8, address, '1') orelse return CosmosError.InvalidBech32;
    if (last_one == 0 or last_one + 7 > address.len) return CosmosError.InvalidBech32;

    return .{
        .hrp = address[0..last_one],
        .data_part = address[last_one + 1 ..],
    };
}

test "split cosmos hrp" {
    const parts = try splitHrp("cosmos1h4n0kgyu74h");
    try std.testing.expectEqualStrings("cosmos", parts.hrp);
    try std.testing.expectEqualStrings("h4n0kgyu74h", parts.data_part);
}

// Generated with the reference python `bech32` package (uv venv): bytes = sha256("web3sql")[0..20].
const CONVERT = [_][2][]const u8{
    .{ "cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", "osmo1cl2z07c0u0lurcucztxxtchnh2yzzxu7g8numu" },
    .{ "cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", "juno1cl2z07c0u0lurcucztxxtchnh2yzzxu7kwrh2j" },
    .{ "cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", "cosmosvaloper1cl2z07c0u0lurcucztxxtchnh2yzzxu79g5epa" },
    .{ "osmo1cl2z07c0u0lurcucztxxtchnh2yzzxu7g8numu", "celestia1cl2z07c0u0lurcucztxxtchnh2yzzxu73k3uhr" },
    // 32-byte contract address, sha256("web3sql")
    .{ "wasm1cl2z07c0u0lurcucztxxtchnh2yzzxu7k5fuv52ul9ykl458yntqzaf348", "cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7k5fuv52ul9ykl458yntqct9ylf" },
};

test "REQ-COSMOS-01 hrp conversion matches reference vectors" {
    var out: [96]u8 = undefined;
    for (CONVERT) |c| {
        const hrp = c[1][0..std.mem.lastIndexOfScalar(u8, c[1], '1').?];
        try std.testing.expectEqualStrings(c[1], try convertHrp(c[0], hrp, &out));
        // and back
        const hrp0 = c[0][0..std.mem.lastIndexOfScalar(u8, c[0], '1').?];
        try std.testing.expectEqualStrings(c[0], try convertHrp(c[1], hrp0, &out));
    }
    try std.testing.expectEqualStrings(CONVERT[0][1], try convertHrp("COSMOS1CL2Z07C0U0LURCUCZTXXTCHNH2YZZXU7QUQVDW", "osmo", &out));
}

test "REQ-COSMOS-01 address validation" {
    try validate("cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", "cosmos");
    try validate("cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", null);
    try std.testing.expectError(CosmosError.WrongHrp, validate("cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", "osmo"));
    try std.testing.expectError(CosmosError.InvalidBech32, validate("cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdx", null)); // checksum
    try std.testing.expectError(CosmosError.InvalidBech32, validate("", null));
    try std.testing.expectError(CosmosError.InvalidBech32, validate("cosmos1", null));
    // Bech32m is not a valid Cosmos encoding; BIP-350 vector "A1LQFN3A"/"a1lqfn3a" has an empty payload
    try std.testing.expectError(CosmosError.InvalidBech32, validate("a1lqfn3a", null));
    try std.testing.expectError(CosmosError.InvalidBech32, validate("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", null));
    // empty payload ("a12uel5l", BIP-173)
    try std.testing.expectError(CosmosError.InvalidBech32, validate("a12uel5l", null));
    var out: [10]u8 = undefined;
    try std.testing.expectError(CosmosError.BufferTooSmall, convertHrp("cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", "osmo", &out));
    var big: [96]u8 = undefined;
    try std.testing.expectError(CosmosError.InvalidBech32, convertHrp("cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", "Osmo", &big));
}

test "REQ-COSMOS-01 decode address bytes" {
    var h: [83]u8 = undefined;
    var b: [32]u8 = undefined;
    const r = try decodeAddress("cosmos1cl2z07c0u0lurcucztxxtchnh2yzzxu7quqvdw", &h, &b);
    try std.testing.expectEqualStrings("cosmos", r.hrp);
    try std.testing.expectEqual(@as(usize, 20), r.bytes.len);
    try std.testing.expectEqual(@as(u8, 0xc7), r.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x9e), r.bytes[19]);
}

fn walk(_: void, bytes: []const u8) void {
    var out: [96]u8 = undefined;
    var h: [83]u8 = undefined;
    var b: [96]u8 = undefined;
    validate(bytes, "cosmos") catch {};
    _ = convertHrp(bytes, "osmo", &out) catch {};
    _ = decodeAddress(bytes, &h, &b) catch {};
    _ = splitHrp(bytes) catch {};
}

test "REQ-COSMOS-01 bech32 fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [100]u8 = undefined;
            walk({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-COSMOS-01 bech32 mutation stress" {
    var seeds: [CONVERT.len * 2][]const u8 = undefined;
    for (CONVERT, 0..) |c, i| {
        seeds[2 * i] = c[0];
        seeds[2 * i + 1] = c[1];
    }
    fuzz.stress(200_000, &seeds, {}, walk);
}
