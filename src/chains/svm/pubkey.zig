//! Solana public keys and program derived addresses (PDAs).
const std = @import("std");
const base58 = @import("../../core/encodings/base58.zig");
const sha256 = @import("../../core/crypto/sha256.zig");
const ed25519 = @import("../../core/crypto/ed25519.zig");

pub const Pubkey = [32]u8;

pub const SvmError = error{
    InvalidPubkey,
    NoBumpFound,
    BufferTooSmall,
    TooManySeeds,
    SeedTooLong,
    /// The derived address lies on the Ed25519 curve, so it is not a valid PDA.
    InvalidSeeds,
};

pub const MAX_SEEDS = 16;
pub const MAX_SEED_LEN = 32;
const PDA_MARKER = "ProgramDerivedAddress";

/// Encodes pubkey into Base58 representation.
pub fn toBase58(pubkey: *const Pubkey, dest: []u8) SvmError![]const u8 {
    return base58.encodeBase58(pubkey, dest) catch SvmError.BufferTooSmall;
}

/// Parses a Base58 address; anything but exactly 32 decoded bytes is `InvalidPubkey`.
pub fn fromBase58(text: []const u8) SvmError!Pubkey {
    var buf: [base58.MAX_DECODED_LEN]u8 = undefined;
    const bytes = base58.decodeBase58(text, &buf) catch return SvmError.InvalidPubkey;
    if (bytes.len != 32) return SvmError.InvalidPubkey;
    return bytes[0..32].*;
}

pub fn isOnCurve(pubkey: *const Pubkey) bool {
    return ed25519.isOnCurve(pubkey);
}

/// sha256(seeds || program_id || "ProgramDerivedAddress"); rejected when on the curve.
pub fn createProgramAddress(seeds: []const []const u8, program_id: *const Pubkey) SvmError!Pubkey {
    if (seeds.len > MAX_SEEDS) return SvmError.TooManySeeds;
    var pre: [MAX_SEEDS * MAX_SEED_LEN + 32 + PDA_MARKER.len]u8 = undefined;
    var n: usize = 0;
    for (seeds) |s| {
        if (s.len > MAX_SEED_LEN) return SvmError.SeedTooLong;
        @memcpy(pre[n..][0..s.len], s);
        n += s.len;
    }
    @memcpy(pre[n..][0..32], program_id);
    n += 32;
    @memcpy(pre[n..][0..PDA_MARKER.len], PDA_MARKER);
    n += PDA_MARKER.len;
    var out: Pubkey = undefined;
    sha256.hash(pre[0..n], &out);
    if (isOnCurve(&out)) return SvmError.InvalidSeeds;
    return out;
}

pub const Pda = struct { address: Pubkey, bump: u8 };

/// Searches bump 255 down to 0 for the first off-curve address. The bump takes one seed slot,
/// so at most 15 caller seeds are accepted.
pub fn findProgramAddress(seeds: []const []const u8, program_id: *const Pubkey) SvmError!Pda {
    if (seeds.len >= MAX_SEEDS) return SvmError.TooManySeeds;
    var all: [MAX_SEEDS][]const u8 = undefined;
    @memcpy(all[0..seeds.len], seeds);
    var bump: u8 = 255;
    while (true) : (bump -= 1) {
        all[seeds.len] = &.{bump};
        if (createProgramAddress(all[0 .. seeds.len + 1], program_id)) |address| {
            return .{ .address = address, .bump = bump };
        } else |err| if (err != SvmError.InvalidSeeds) return err;
        if (bump == 0) return SvmError.NoBumpFound;
    }
}

test "REQ-SVM-01 pubkey base58 round trip" {
    const pk: Pubkey = @splat(0);
    var buf: [64]u8 = undefined;
    const b58 = try toBase58(&pk, &buf);
    try std.testing.expectEqualStrings("11111111111111111111111111111111", b58);
    try std.testing.expectEqual(pk, try fromBase58(b58));
    try std.testing.expectError(SvmError.InvalidPubkey, fromBase58("1111111111111111111111111111111")); // 31 bytes
    try std.testing.expectError(SvmError.InvalidPubkey, fromBase58("0OIl"));
    try std.testing.expectError(SvmError.InvalidPubkey, fromBase58(""));
    var small: [8]u8 = undefined;
    try std.testing.expectError(SvmError.BufferTooSmall, toBase58(&pk, &small));
}

fn key(text: []const u8) Pubkey {
    return fromBase58(text) catch unreachable; // test helper, constant inputs
}

test "REQ-SVM-01 createProgramAddress vectors from the Solana SDK" {
    // Source: anza-xyz/solana-sdk address/src/lib.rs `test_create_program_address`.
    const program_id = key("BPFLoaderUpgradeab1e11111111111111111111111");
    const seed_pubkey = key("SeedPubey1111111111111111111111111111111111");
    const cases = [_]struct { seeds: []const []const u8, want: []const u8 }{
        .{ .seeds = &.{ "", &.{1} }, .want = "BwqrghZA2htAcqq8dzP1WDAhTXYTYWj7CHxF5j7TDBAe" },
        .{ .seeds = &.{ "\u{2609}", &.{0} }, .want = "13yWmRpaTR4r5nAktwLqMpRNr28tnVUZw26rTvPSSB19" },
        .{ .seeds = &.{ "Talking", "Squirrels" }, .want = "2fnQrngrQT4SeLcdToJAD96phoEjNL2man2kfRLCASVk" },
        .{ .seeds = &.{ &seed_pubkey, &.{1} }, .want = "976ymqVnfE32QFe6NfGDctSvVa36LWnvYxhU6G2232YL" },
    };
    for (cases) |c| {
        try std.testing.expectEqual(key(c.want), try createProgramAddress(c.seeds, &program_id));
    }
    // Same file: limits. 17 seeds / 33-byte seed fail, 16 seeds / 32-byte seed pass.
    const max_seed: [32]u8 = @splat(0);
    _ = try createProgramAddress(&.{&max_seed}, &program_id);
    const too_long: [33]u8 = @splat(127);
    try std.testing.expectError(SvmError.SeedTooLong, createProgramAddress(&.{&too_long}, &program_id));
    try std.testing.expectError(SvmError.SeedTooLong, createProgramAddress(&.{ "short_seed", &too_long }, &program_id));
    const s16: [16][]const u8 = .{ &.{1}, &.{2}, &.{3}, &.{4}, &.{5}, &.{6}, &.{7}, &.{8}, &.{9}, &.{10}, &.{11}, &.{12}, &.{13}, &.{14}, &.{15}, &.{16} };
    _ = try createProgramAddress(&s16, &program_id);
    const s17 = s16 ++ [1][]const u8{&.{17}};
    try std.testing.expectError(SvmError.TooManySeeds, createProgramAddress(&s17, &program_id));
    try std.testing.expectError(SvmError.TooManySeeds, findProgramAddress(&s16, &program_id));
}

test "REQ-SVM-01 findProgramAddress vectors" {
    // Reference: solders (Rust solana-pubkey bindings) Pubkey.find_program_address, run once in a dev venv.
    // Associated token account of wallet vines1vz... for USDC: seeds [wallet, Tokenkeg..., mint], bump 253.
    const ata_program = key("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
    const token_program = key("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
    const wallet = key("vines1vzrYbzLMRdu58ou5XTby4qAqVRLmqo36NKPTg");
    const mint = key("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
    const ata = try findProgramAddress(&.{ &wallet, &token_program, &mint }, &ata_program);
    try std.testing.expectEqual(key("9jrTvdU2Am3UmgSAX8EKS9wwrSufkWRbZzEukDogqpQg"), ata.address);
    try std.testing.expectEqual(@as(u8, 253), ata.bump);
    try std.testing.expect(!isOnCurve(&ata.address));
    // The bump must reproduce through createProgramAddress.
    try std.testing.expectEqual(ata.address, try createProgramAddress(&.{ &wallet, &token_program, &mint, &.{253} }, &ata_program));

    const loader = key("BPFLoaderUpgradeab1e11111111111111111111111");
    const lil = try findProgramAddress(&.{ "Lil", "Bits" }, &loader);
    try std.testing.expectEqual(key("5UkTw9cib2gLTgfG8APHJxgJKHffr2P5kV86qogEfwLW"), lil.address);
    try std.testing.expectEqual(@as(u8, 255), lil.bump);

    const sys = key("11111111111111111111111111111111");
    try std.testing.expectEqual(key("Cu7NwqCXSmsR5vgGA3Vw9uYVViPi3kQvkbKByVQ8nPY9"), (try findProgramAddress(&.{}, &sys)).address);
}

test "REQ-SVM-01 isOnCurve on real keys" {
    // Wallets are Ed25519 public keys, so they are on the curve (PDAs above are not).
    const wallet = key("vines1vzrYbzLMRdu58ou5XTby4qAqVRLmqo36NKPTg");
    try std.testing.expect(isOnCurve(&wallet)); // a wallet is an Ed25519 public key
}

test "REQ-SVM-01 pda fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [600]u8 = undefined;
            const n = smith.slice(&buf);
            var seeds: [8][]const u8 = undefined;
            var count: usize = 0;
            var rest: []const u8 = buf[0..n];
            while (count < seeds.len and rest.len > 0) : (count += 1) {
                const take = @min(rest.len, 1 + rest[0] % 40);
                seeds[count] = rest[0..take];
                rest = rest[take..];
            }
            _ = findProgramAddress(seeds[0..count], &@splat(7)) catch {};
            _ = fromBase58(buf[0..n]) catch {};
        }
    }.f, .{});
}
