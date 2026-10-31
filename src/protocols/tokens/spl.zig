//! SPL Token instruction data, per `TokenInstruction::unpack` in solana-program/token
//! interface/src/instruction.rs. Token-2022 shares these tags; its extension instructions, and the
//! Batch instruction, are `UnknownInstruction`. Trailing bytes are ignored, as `unpack` ignores them.
const std = @import("std");
const base58 = @import("../../core/encodings/base58.zig");
const fuzz = @import("../../core/fuzz.zig");
const json = @import("json.zig");

pub const Kind = enum(u8) {
    initialize_mint = 0,
    initialize_account = 1,
    initialize_multisig = 2,
    transfer = 3,
    approve = 4,
    revoke = 5,
    set_authority = 6,
    mint_to = 7,
    burn = 8,
    close_account = 9,
    freeze_account = 10,
    thaw_account = 11,
    transfer_checked = 12,
    approve_checked = 13,
    mint_to_checked = 14,
    burn_checked = 15,
    initialize_account2 = 16,
    sync_native = 17,
    initialize_account3 = 18,
    initialize_multisig2 = 19,
    initialize_mint2 = 20,
    get_account_data_size = 21,
    initialize_immutable_owner = 22,
    amount_to_ui_amount = 23,
    ui_amount_to_amount = 24,
    withdraw_excess_lamports = 38,
    unwrap_lamports = 45,
};

pub const SplError = error{
    UnknownInstruction,
    TruncatedInstruction,
    /// A `COption` tag other than 0 or 1, or a UI amount that is not plain text.
    InvalidInstruction,
    BufferTooSmall,
};

/// Reads the fields after the tag and writes each as `,"name":value`.
const Fields = struct {
    rest: []const u8,
    out: json.Out,

    fn take(self: *Fields, n: usize) SplError![]const u8 {
        if (self.rest.len < n) return SplError.TruncatedInstruction;
        defer self.rest = self.rest[n..];
        return self.rest[0..n];
    }

    fn key(self: *Fields, name: []const u8) SplError!void {
        try self.out.raw(",\"");
        try self.out.raw(name);
        try self.out.raw("\":");
    }

    fn int(self: *Fields, name: []const u8, comptime T: type) SplError!void {
        const bytes = try self.take(@sizeOf(T));
        try self.key(name);
        try self.out.int(std.mem.readInt(T, bytes[0..@sizeOf(T)], .little));
    }

    fn writePubkey(self: *Fields) SplError!void {
        var buf: [base58.MAX_ENCODED_LEN]u8 = undefined;
        const encoded = base58.encodeBase58(try self.take(32), &buf) catch unreachable; // 32 bytes always fit
        try self.out.raw("\"");
        try self.out.raw(encoded);
        try self.out.raw("\"");
    }

    fn pubkey(self: *Fields, name: []const u8) SplError!void {
        try self.key(name);
        try self.writePubkey();
    }

    /// True when a `COption` holds a value, which comes next.
    fn present(self: *Fields) SplError!bool {
        return switch ((try self.take(1))[0]) {
            0 => false,
            1 => true,
            else => SplError.InvalidInstruction,
        };
    }

    fn optionalPubkey(self: *Fields, name: []const u8) SplError!void {
        try self.key(name);
        if (try self.present()) try self.writePubkey() else try self.out.raw("null");
    }

    fn optionalAmount(self: *Fields, name: []const u8) SplError!void {
        if (try self.present()) return self.int(name, u64);
        try self.key(name);
        try self.out.raw("null");
    }

    fn text(self: *Fields, name: []const u8) SplError!void {
        for (self.rest) |c| if (c < 0x20 or c > 0x7e or c == '"' or c == '\\') return SplError.InvalidInstruction;
        try self.key(name);
        try self.out.raw("\"");
        try self.out.raw(self.rest);
        try self.out.raw("\"");
    }
};

/// Decoded instruction as compact JSON. Accounts live in the account list, not in instruction data.
pub fn renderJson(data: []const u8, dest: []u8) SplError![]const u8 {
    if (data.len == 0) return SplError.TruncatedInstruction;
    const kind = std.enums.fromInt(Kind, data[0]) orelse return SplError.UnknownInstruction;
    var f: Fields = .{ .rest = data[1..], .out = .{ .dest = dest } };
    try f.out.raw("{\"type\":\"");
    try f.out.raw(@tagName(kind));
    try f.out.raw("\"");
    switch (kind) {
        .initialize_account, .revoke, .close_account, .freeze_account, .thaw_account, .sync_native, .get_account_data_size, .initialize_immutable_owner, .withdraw_excess_lamports => {},
        .initialize_multisig, .initialize_multisig2 => try f.int("m", u8),
        .transfer, .approve, .mint_to, .burn, .amount_to_ui_amount => try f.int("amount", u64),
        .transfer_checked, .approve_checked, .mint_to_checked, .burn_checked => {
            try f.int("amount", u64);
            try f.int("decimals", u8);
        },
        .initialize_mint, .initialize_mint2 => {
            try f.int("decimals", u8);
            try f.pubkey("mint_authority");
            try f.optionalPubkey("freeze_authority");
        },
        .set_authority => {
            try f.int("authority_type", u8);
            try f.optionalPubkey("new_authority");
        },
        .initialize_account2, .initialize_account3 => try f.pubkey("owner"),
        .ui_amount_to_amount => try f.text("ui_amount"),
        .unwrap_lamports => try f.optionalAmount("amount"),
    }
    try f.out.raw("}");
    return f.out.written();
}

// solana-program/token interface/src/instruction.rs test_instruction_packing.
const TRANSFER = [_]u8{ 3, 1, 0, 0, 0, 0, 0, 0, 0 };
const APPROVE = [_]u8{ 4, 1, 0, 0, 0, 0, 0, 0, 0 };
const TRANSFER_CHECKED = [_]u8{ 12, 1, 0, 0, 0, 0, 0, 0, 0, 2 };
const APPROVE_CHECKED = [_]u8{ 13, 1, 0, 0, 0, 0, 0, 0, 0, 2 };
const KEY_ONES: [32]u8 = @splat(1); // Base58: 4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi

fn expectJson(want: []const u8, data: []const u8) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(want, try renderJson(data, &buf));
}

test "REQ-PROT-02 SPL amounts" {
    try expectJson("{\"type\":\"transfer\",\"amount\":1}", &TRANSFER);
    try expectJson("{\"type\":\"approve\",\"amount\":1}", &APPROVE);
    try expectJson("{\"type\":\"transfer_checked\",\"amount\":1,\"decimals\":2}", &TRANSFER_CHECKED);
    try expectJson("{\"type\":\"approve_checked\",\"amount\":1,\"decimals\":2}", &APPROVE_CHECKED);
    try expectJson("{\"type\":\"mint_to\",\"amount\":1}", &[_]u8{ 7, 1, 0, 0, 0, 0, 0, 0, 0 });
    try expectJson("{\"type\":\"burn\",\"amount\":1}", &[_]u8{ 8, 1, 0, 0, 0, 0, 0, 0, 0 });
    try expectJson("{\"type\":\"mint_to_checked\",\"amount\":1,\"decimals\":2}", &[_]u8{ 14, 1, 0, 0, 0, 0, 0, 0, 0, 2 });
    try expectJson("{\"type\":\"burn_checked\",\"amount\":1,\"decimals\":2}", &[_]u8{ 15, 1, 0, 0, 0, 0, 0, 0, 0, 2 });
    try expectJson("{\"type\":\"amount_to_ui_amount\",\"amount\":1}", &[_]u8{ 23, 1, 0, 0, 0, 0, 0, 0, 0 });
    var max: [9]u8 = @splat(0xff);
    max[0] = 3;
    try expectJson("{\"type\":\"transfer\",\"amount\":\"18446744073709551615\"}", &max);
}

test "REQ-PROT-02 SPL instructions with no fields, seen on mainnet" {
    inline for ([_]Kind{ .initialize_account, .revoke, .close_account, .freeze_account, .thaw_account, .sync_native, .get_account_data_size, .initialize_immutable_owner, .withdraw_excess_lamports }) |k| {
        try expectJson("{\"type\":\"" ++ @tagName(k) ++ "\"}", &[_]u8{@backingInt(k)});
    }
}

test "REQ-PROT-02 SPL pubkeys and COptions" {
    const owner = [_]u8{18} ++ KEY_ONES;
    try expectJson("{\"type\":\"initialize_account3\",\"owner\":\"4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi\"}", &owner);
    const mint = [_]u8{ 20, 6 } ++ KEY_ONES ++ [_]u8{1} ++ KEY_ONES;
    try expectJson("{\"type\":\"initialize_mint2\",\"decimals\":6,\"mint_authority\":\"4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi\",\"freeze_authority\":\"4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi\"}", &mint);
    const no_freeze = [_]u8{ 0, 6 } ++ KEY_ONES ++ [_]u8{0};
    try expectJson("{\"type\":\"initialize_mint\",\"decimals\":6,\"mint_authority\":\"4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi\",\"freeze_authority\":null}", &no_freeze);
    try expectJson("{\"type\":\"set_authority\",\"authority_type\":2,\"new_authority\":null}", &[_]u8{ 6, 2, 0 });
    try expectJson("{\"type\":\"initialize_multisig2\",\"m\":3}", &[_]u8{ 19, 3 });
    try expectJson("{\"type\":\"ui_amount_to_amount\",\"ui_amount\":\"1.5\"}", &([_]u8{24} ++ "1.5".*));
    try expectJson("{\"type\":\"unwrap_lamports\",\"amount\":null}", &[_]u8{ 45, 0 });
    try expectJson("{\"type\":\"unwrap_lamports\",\"amount\":7}", &[_]u8{ 45, 1, 7, 0, 0, 0, 0, 0, 0, 0 });
}

test "REQ-PROT-02 SPL rejects what unpack rejects" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson("", &buf));
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson(TRANSFER[0..8], &buf));
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson(TRANSFER_CHECKED[0..9], &buf));
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson(&[_]u8{18}, &buf));
    try std.testing.expectError(SplError.UnknownInstruction, renderJson(&[_]u8{25}, &buf));
    try std.testing.expectError(SplError.UnknownInstruction, renderJson(&[_]u8{255}, &buf));
    try std.testing.expectError(SplError.InvalidInstruction, renderJson(&[_]u8{ 6, 2, 2 }, &buf));
    try std.testing.expectError(SplError.InvalidInstruction, renderJson(&[_]u8{ 24, '"' }, &buf));
    const trailing = TRANSFER ++ [_]u8{0xff};
    try expectJson("{\"type\":\"transfer\",\"amount\":1}", &trailing);
    try std.testing.expectError(SplError.BufferTooSmall, renderJson(&TRANSFER, buf[0..10]));
}

fn exercise(_: void, bytes: []const u8) void {
    var dest: [192]u8 = undefined;
    _ = renderJson(bytes, &dest) catch {};
    _ = renderJson(bytes, dest[0 .. bytes.len % 64]) catch {};
}

test "REQ-PROT-02 SPL fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [80]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-02 SPL stress" {
    const mint = [_]u8{ 20, 6 } ++ KEY_ONES ++ [_]u8{1} ++ KEY_ONES;
    fuzz.stress(200_000, &.{ &TRANSFER, &APPROVE, &TRANSFER_CHECKED, &APPROVE_CHECKED, &mint, &[_]u8{ 6, 2, 1 }, &[_]u8{24} ++ "1.5" }, {}, exercise);
}
