//! Catalogue entries for Solana.
const std = @import("std");
const core = @import("../core/root.zig");
const svm = @import("../chains/svm/root.zig");
const catalog = @import("catalog.zig");
const func = catalog.func;
const schemaFunc = catalog.schemaFunc;

fn isOnCurve(pubkey: []const u8) error{InvalidPubkey}!bool {
    if (pubkey.len != 32) return error.InvalidPubkey;
    return svm.pubkey.isOnCurve(pubkey[0..32]);
}

/// Splits comma-separated hex seeds into `storage`, returning at most MAX_SEEDS slices.
fn parseSeeds(text: []const u8, storage: *[svm.pubkey.MAX_SEEDS][svm.pubkey.MAX_SEED_LEN]u8, out: *[svm.pubkey.MAX_SEEDS][]const u8) error{InvalidSeeds}![]const []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |hex_seed| {
        if (n == out.len) return error.InvalidSeeds;
        out[n] = core.encodings.hex.decodeHex(hex_seed, &storage[n]) catch return error.InvalidSeeds;
        n += 1;
    }
    return out[0..n];
}

fn findPda(program: []const u8, seeds_text: []const u8) !svm.pubkey.Pda {
    var storage: [svm.pubkey.MAX_SEEDS][svm.pubkey.MAX_SEED_LEN]u8 = undefined;
    var seeds: [svm.pubkey.MAX_SEEDS][]const u8 = undefined;
    const id = try svm.pubkey.fromBase58(program);
    return svm.pubkey.findProgramAddress(try parseSeeds(seeds_text, &storage, &seeds), &id);
}

fn pdaAddress(program: []const u8, seeds_text: []const u8, dest: []u8) ![]const u8 {
    return svm.pubkey.toBase58(&(try findPda(program, seeds_text)).address, dest);
}

fn pdaBump(program: []const u8, seeds_text: []const u8) !i64 {
    return (try findPda(program, seeds_text)).bump;
}

fn discriminatorFn(comptime compute: fn ([]const u8) svm.anchor.AnchorError!svm.anchor.Discriminator) fn ([]const u8, []u8) anyerror![]const u8 {
    return struct {
        fn f(name: []const u8, dest: []u8) anyerror![]const u8 {
            if (dest.len < 8) return error.BufferTooSmall;
            dest[0..8].* = try compute(name);
            return dest[0..8];
        }
    }.f;
}

fn parseBorsh(gpa: std.mem.Allocator, text: []const u8) svm.schema.SchemaError!*const svm.borsh.Type {
    return svm.schema.parse(gpa, text);
}

fn parseIdl(gpa: std.mem.Allocator, json: []const u8) !*const svm.idl.Idl {
    const idl = try gpa.create(svm.idl.Idl);
    idl.* = try svm.idl.Idl.parse(gpa, json);
    return idl;
}

fn decodeInstruction(idl: *const svm.idl.Idl, data: []const u8, dest: []u8) ![]const u8 {
    return idl.decodeInstruction(data, dest);
}
fn decodeEvent(idl: *const svm.idl.Idl, data: []const u8, dest: []u8) ![]const u8 {
    return idl.decodeEvent(data, dest);
}
fn decodeAccount(idl: *const svm.idl.Idl, data: []const u8, dest: []u8) ![]const u8 {
    return idl.decodeAccount(data, dest);
}
fn decodeAccountRaw(idl: *const svm.idl.Idl, name: []const u8, data: []const u8, dest: []u8) ![]const u8 {
    return idl.decodeAccountRaw(name, data, dest);
}
fn decodeEventLog(idl: *const svm.idl.Idl, line: []const u8, dest: []u8) ![]const u8 {
    if (dest.len < 2) return error.BufferTooSmall;
    const half = dest.len / 2;
    return idl.decodeEventLog(line, dest[half..], dest[0..half]);
}

pub const entries = [_]catalog.Function{
    func("web3_sol_is_on_curve", "True if 32 bytes are an Ed25519 point", &.{.bytes}, .boolean, isOnCurve),
    func("web3_sol_pda", "Program derived address from Base58 program id and comma-separated hex seeds", &.{ .text, .text }, .text, pdaAddress),
    func("web3_sol_pda_bump", "Bump seed of web3_sol_pda", &.{ .text, .text }, .int, pdaBump),
    func("web3_anchor_instruction_discriminator", "Anchor global:<name> discriminator", &.{.text}, .bytes, discriminatorFn(svm.anchor.instructionDiscriminator)),
    func("web3_anchor_account_discriminator", "Anchor account:<Name> discriminator", &.{.text}, .bytes, discriminatorFn(svm.anchor.accountDiscriminator)),
    func("web3_anchor_event_discriminator", "Anchor event:<Name> discriminator", &.{.text}, .bytes, discriminatorFn(svm.anchor.eventDiscriminator)),
    schemaFunc("web3_borsh_decode", "JSON from Borsh bytes and a text schema", &.{ .text, .bytes }, .text, parseBorsh, svm.borsh.renderJson),
    catalog.nativeOnly(schemaFunc("web3_anchor_decode_instruction", "JSON from an IDL and instruction data", &.{ .text, .bytes }, .text, parseIdl, decodeInstruction)),
    catalog.nativeOnly(schemaFunc("web3_anchor_decode_event", "JSON from an IDL and event data", &.{ .text, .bytes }, .text, parseIdl, decodeEvent)),
    catalog.nativeOnly(schemaFunc("web3_anchor_decode_account", "JSON from an IDL and account data", &.{ .text, .bytes }, .text, parseIdl, decodeAccount)),
    catalog.nativeOnly(schemaFunc("web3_anchor_decode_account_raw", "JSON from an IDL, an account type name and account data with no discriminator, such as Metaplex's", &.{ .text, .text, .bytes }, .text, parseIdl, decodeAccountRaw)),
    catalog.nativeOnly(schemaFunc("web3_anchor_decode_event_log", "JSON from an IDL and a 'Program data:' log line", &.{ .text, .text }, .text, parseIdl, decodeEventLog)),
};
