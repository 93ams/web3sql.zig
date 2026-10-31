//! SPL Token and Token-2022 instruction data, per `TokenInstruction::unpack` in solana-program/token
//! and solana-program/token-2022 interface/src/instruction.rs, and the token-metadata interface.
//! Extensions with no decoder here, and Batch, surface their raw bytes. Trailing bytes are ignored,
//! as `unpack` ignores them.
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
    initialize_mint_close_authority = 25,
    transfer_fee_extension = 26,
    confidential_transfer_extension = 27,
    default_account_state_extension = 28,
    reallocate = 29,
    memo_transfer_extension = 30,
    create_native_mint = 31,
    initialize_non_transferable_mint = 32,
    interest_bearing_mint_extension = 33,
    cpi_guard_extension = 34,
    initialize_permanent_delegate = 35,
    transfer_hook_extension = 36,
    confidential_transfer_fee_extension = 37,
    withdraw_excess_lamports = 38,
    metadata_pointer_extension = 39,
    group_pointer_extension = 40,
    group_member_pointer_extension = 41,
    confidential_mint_burn_extension = 42,
    scaled_ui_amount_extension = 43,
    pausable_extension = 44,
    unwrap_lamports = 45,
    permissioned_burn_extension = 46,
    batch = 255,
};

// The first 8 bytes of sha256("spl_token_metadata_interface:<name>"), which replace the tag byte.
const METADATA_INITIALIZE = [8]u8{ 0xd2, 0xe1, 0x1e, 0xa2, 0x58, 0xb8, 0x4d, 0x8d };
const METADATA_UPDATE_FIELD = [8]u8{ 0xdd, 0xe9, 0x31, 0x2d, 0xb5, 0xca, 0xdc, 0xc8 };
const METADATA_REMOVE_KEY = [8]u8{ 0xea, 0x12, 0x20, 0x38, 0x59, 0x8d, 0x25, 0xb5 };
const METADATA_UPDATE_AUTHORITY = [8]u8{ 0xd7, 0xe4, 0xa6, 0xe4, 0x54, 0x64, 0x56, 0x7b };
const METADATA_EMIT = [8]u8{ 0xfa, 0xa6, 0xb4, 0xfa, 0x0d, 0x0c, 0xb8, 0x46 };

pub const SplError = error{
    UnknownInstruction,
    TruncatedInstruction,
    /// A `COption` tag other than 0 or 1, an odd-length extension list, or text that is not UTF-8.
    InvalidInstruction,
    BufferTooSmall,
};

/// Reads the fields after the tag and writes each as `,"name":value`.
const Fields = struct {
    rest: []const u8,
    out: json.Out,

    fn begin(self: *Fields, name: []const u8) SplError!void {
        try self.out.raw("{\"type\":\"");
        try self.out.raw(name);
        try self.out.raw("\"");
    }

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

    /// An address where all zeros means none, spelled `MaybeNull` upstream.
    fn maybeNullPubkey(self: *Fields, name: []const u8) SplError!void {
        if (self.rest.len < 32) return SplError.TruncatedInstruction;
        if (std.mem.allEqual(u8, self.rest[0..32], 0)) {
            self.rest = self.rest[32..];
            try self.key(name);
            return self.out.raw("null");
        }
        return self.pubkey(name);
    }

    fn writeText(self: *Fields, value: []const u8) SplError!void {
        if (!std.unicode.utf8ValidateSlice(value)) return SplError.InvalidInstruction;
        try self.out.string(value);
    }

    fn remainingText(self: *Fields, name: []const u8) SplError!void {
        try self.key(name);
        try self.writeText(self.rest);
    }

    /// A Borsh string: u32 little-endian length, then the bytes.
    fn takeString(self: *Fields) SplError![]const u8 {
        return self.take(std.mem.readInt(u32, (try self.take(4))[0..4], .little));
    }

    fn string(self: *Fields, name: []const u8) SplError!void {
        const value = try self.takeString();
        try self.key(name);
        try self.writeText(value);
    }

    fn extensionTypes(self: *Fields) SplError!void {
        if (self.rest.len % 2 != 0) return SplError.InvalidInstruction;
        try self.key("extension_types");
        try self.out.raw("[");
        var first = true;
        while (self.rest.len != 0) : (first = false) {
            if (!first) try self.out.raw(",");
            try self.out.int(std.mem.readInt(u16, (try self.take(2))[0..2], .little));
        }
        try self.out.raw("]");
    }

    fn remainingBytes(self: *Fields) SplError!void {
        try self.key("data");
        try self.out.bytes(self.rest);
    }
};

fn metadata(f: *Fields, disc: *const [8]u8) SplError!bool {
    if (std.mem.eql(u8, disc, &METADATA_INITIALIZE)) {
        try f.begin("initialize_token_metadata");
        try f.string("name");
        try f.string("symbol");
        try f.string("uri");
    } else if (std.mem.eql(u8, disc, &METADATA_UPDATE_FIELD)) {
        try f.begin("update_token_metadata_field");
        const field = (try f.take(1))[0];
        try f.key("field");
        switch (field) {
            0 => try f.out.raw("\"name\""),
            1 => try f.out.raw("\"symbol\""),
            2 => try f.out.raw("\"uri\""),
            3 => try f.writeText(try f.takeString()),
            else => return SplError.InvalidInstruction,
        }
        try f.string("value");
    } else if (std.mem.eql(u8, disc, &METADATA_REMOVE_KEY)) {
        try f.begin("remove_token_metadata_key");
        try f.int("idempotent", u8);
        try f.string("key");
    } else if (std.mem.eql(u8, disc, &METADATA_UPDATE_AUTHORITY)) {
        try f.begin("update_token_metadata_authority");
        try f.maybeNullPubkey("new_authority");
    } else if (std.mem.eql(u8, disc, &METADATA_EMIT)) {
        try f.begin("emit_token_metadata");
        try f.optionalAmount("start");
        try f.optionalAmount("end");
    } else return false;
    return true;
}

fn transferFee(f: *Fields) SplError!void {
    switch ((try f.take(1))[0]) {
        0 => {
            try f.begin("initialize_transfer_fee_config");
            try f.optionalPubkey("transfer_fee_config_authority");
            try f.optionalPubkey("withdraw_withheld_authority");
            try f.int("transfer_fee_basis_points", u16);
            try f.int("maximum_fee", u64);
        },
        1 => {
            try f.begin("transfer_checked_with_fee");
            try f.int("amount", u64);
            try f.int("decimals", u8);
            try f.int("fee", u64);
        },
        2 => try f.begin("withdraw_withheld_tokens_from_mint"),
        3 => {
            try f.begin("withdraw_withheld_tokens_from_accounts");
            try f.int("num_token_accounts", u8);
        },
        4 => try f.begin("harvest_withheld_tokens_to_mint"),
        5 => {
            try f.begin("set_transfer_fee");
            try f.int("transfer_fee_basis_points", u16);
            try f.int("maximum_fee", u64);
        },
        else => return SplError.UnknownInstruction,
    }
}

/// The metadata, group and group member pointers share a layout.
fn pointer(f: *Fields, comptime name: []const u8, comptime address: []const u8) SplError!void {
    switch ((try f.take(1))[0]) {
        0 => {
            try f.begin("initialize_" ++ name ++ "_pointer");
            try f.maybeNullPubkey("authority");
            try f.maybeNullPubkey(address);
        },
        1 => {
            try f.begin("update_" ++ name ++ "_pointer");
            try f.maybeNullPubkey(address);
        },
        else => return SplError.UnknownInstruction,
    }
}

/// Decoded instruction as compact JSON. Accounts live in the account list, not in instruction data.
pub fn renderJson(data: []const u8, dest: []u8) SplError![]const u8 {
    if (data.len == 0) return SplError.TruncatedInstruction;
    var f: Fields = .{ .rest = data[1..], .out = .{ .dest = dest } };
    try body(&f, data);
    try f.out.raw("}");
    return f.out.written();
}

fn body(f: *Fields, data: []const u8) SplError!void {
    if (data.len >= 8) {
        f.rest = data[8..];
        if (try metadata(f, data[0..8])) return;
        f.rest = data[1..];
    }
    const kind = std.enums.fromInt(Kind, data[0]) orelse return SplError.UnknownInstruction;
    switch (kind) {
        .transfer_fee_extension => return transferFee(f),
        .metadata_pointer_extension => return pointer(f, "metadata", "metadata_address"),
        .group_pointer_extension => return pointer(f, "group", "group_address"),
        .group_member_pointer_extension => return pointer(f, "group_member", "member_address"),
        else => {},
    }
    try f.begin(@tagName(kind));
    switch (kind) {
        .initialize_account, .revoke, .close_account, .freeze_account, .thaw_account, .sync_native, .initialize_immutable_owner, .withdraw_excess_lamports, .create_native_mint, .initialize_non_transferable_mint => {},
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
        .ui_amount_to_amount => try f.remainingText("ui_amount"),
        .unwrap_lamports => try f.optionalAmount("amount"),
        .initialize_mint_close_authority => try f.optionalPubkey("close_authority"),
        .initialize_permanent_delegate => try f.pubkey("delegate"),
        .get_account_data_size, .reallocate => try f.extensionTypes(),
        .batch => try f.remainingBytes(),
        .confidential_transfer_extension, .default_account_state_extension, .memo_transfer_extension, .interest_bearing_mint_extension, .cpi_guard_extension, .transfer_hook_extension, .confidential_transfer_fee_extension, .confidential_mint_burn_extension, .scaled_ui_amount_extension, .pausable_extension, .permissioned_burn_extension => {
            try f.int("instruction", u8);
            try f.remainingBytes();
        },
        .transfer_fee_extension, .metadata_pointer_extension, .group_pointer_extension, .group_member_pointer_extension => unreachable,
    }
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
    inline for ([_]Kind{ .initialize_account, .revoke, .close_account, .freeze_account, .thaw_account, .sync_native, .initialize_immutable_owner, .withdraw_excess_lamports, .create_native_mint, .initialize_non_transferable_mint }) |k| {
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

test "REQ-PROT-02 Token-2022 extensions, from mainnet instruction data" {
    try expectJson("{\"type\":\"transfer_checked_with_fee\",\"amount\":479338599,\"decimals\":6,\"fee\":0}", &[_]u8{ 0x1a, 0x01, 0x67, 0x20, 0x92, 0x1c, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0 });
    try expectJson("{\"type\":\"get_account_data_size\",\"extension_types\":[7]}", &[_]u8{ 0x15, 7, 0 });
    try expectJson("{\"type\":\"get_account_data_size\",\"extension_types\":[]}", &[_]u8{0x15});
    const none: [32]u8 = @splat(0);
    try expectJson("{\"type\":\"update_token_metadata_authority\",\"new_authority\":null}", &(METADATA_UPDATE_AUTHORITY ++ none));
    try expectJson("{\"type\":\"initialize_metadata_pointer\",\"authority\":\"4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi\",\"metadata_address\":null}", &([_]u8{ 39, 0 } ++ KEY_ONES ++ none));
    try expectJson("{\"type\":\"update_group_member_pointer\",\"member_address\":null}", &([_]u8{ 41, 1 } ++ none));
    try expectJson("{\"type\":\"pausable_extension\",\"instruction\":1,\"data\":\"0xab\"}", &[_]u8{ 44, 1, 0xab });
    try expectJson("{\"type\":\"batch\",\"data\":\"0x0102\"}", &[_]u8{ 255, 1, 2 });
}

test "REQ-PROT-02 token metadata strings stay valid JSON" {
    const strings = [_]u8{ 2, 0, 0, 0, '"', 0x5c, 1, 0, 0, 0, '\n', 2, 0, 0, 0, 0xc3, 0xa9 };
    try expectJson("{\"type\":\"initialize_token_metadata\",\"name\":\"\\\"\\\\\",\"symbol\":\"\\n\",\"uri\":\"\xc3\xa9\"}", &(METADATA_INITIALIZE ++ strings));
    try expectJson("{\"type\":\"update_token_metadata_field\",\"field\":\"uri\",\"value\":\"a\"}", &(METADATA_UPDATE_FIELD ++ [_]u8{ 2, 1, 0, 0, 0, 'a' }));
    try expectJson("{\"type\":\"update_token_metadata_field\",\"field\":\"k\",\"value\":\"a\"}", &(METADATA_UPDATE_FIELD ++ [_]u8{ 3, 1, 0, 0, 0, 'k', 1, 0, 0, 0, 'a' }));
    try expectJson("{\"type\":\"remove_token_metadata_key\",\"idempotent\":1,\"key\":\"k\"}", &(METADATA_REMOVE_KEY ++ [_]u8{ 1, 1, 0, 0, 0, 'k' }));
    try expectJson("{\"type\":\"emit_token_metadata\",\"start\":5,\"end\":null}", &(METADATA_EMIT ++ [_]u8{ 1, 5, 0, 0, 0, 0, 0, 0, 0, 0 }));
    var buf: [128]u8 = undefined;
    const bad_utf8 = METADATA_INITIALIZE ++ [_]u8{ 1, 0, 0, 0, 0xff };
    try std.testing.expectError(SplError.InvalidInstruction, renderJson(&bad_utf8, &buf));
}

test "REQ-PROT-02 SPL rejects what unpack rejects" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson("", &buf));
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson(TRANSFER[0..8], &buf));
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson(TRANSFER_CHECKED[0..9], &buf));
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson(&[_]u8{18}, &buf));
    try std.testing.expectError(SplError.UnknownInstruction, renderJson(&[_]u8{47}, &buf));
    try std.testing.expectError(SplError.InvalidInstruction, renderJson(&[_]u8{ 6, 2, 2 }, &buf));
    try std.testing.expectError(SplError.InvalidInstruction, renderJson(&[_]u8{ 24, 0xff }, &buf));
    try std.testing.expectError(SplError.InvalidInstruction, renderJson(&[_]u8{ 21, 7 }, &buf));
    try std.testing.expectError(SplError.UnknownInstruction, renderJson(&[_]u8{ 26, 6 }, &buf));
    try std.testing.expectError(SplError.UnknownInstruction, renderJson(&[_]u8{ 39, 2 }, &buf));
    try std.testing.expectError(SplError.InvalidInstruction, renderJson(&(METADATA_UPDATE_FIELD ++ [_]u8{4}), &buf));
    try std.testing.expectError(SplError.TruncatedInstruction, renderJson(&(METADATA_INITIALIZE ++ [_]u8{ 0xff, 0xff, 0xff, 0xff }), &buf));
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
    fuzz.stress(200_000, &.{ &TRANSFER, &APPROVE, &TRANSFER_CHECKED, &APPROVE_CHECKED, &mint, &[_]u8{ 6, 2, 1 }, &[_]u8{24} ++ "1.5", &[_]u8{ 26, 1 } ++ TRANSFER, &[_]u8{ 39, 0 } ++ KEY_ONES ++ KEY_ONES, &(METADATA_INITIALIZE ++ [_]u8{ 1, 0, 0, 0, 0x22, 0, 0, 0, 0, 1, 0, 0, 0, 0x5c }) }, {}, exercise);
}
