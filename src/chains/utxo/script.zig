//! Bitcoin-family script iteration, scriptPubKey classification and address derivation.
const std = @import("std");
const base58 = @import("../../core/encodings/base58.zig");
const bech32 = @import("../../core/encodings/bech32.zig");
const network = @import("network.zig");
const vectors = @import("vectors.zig");
const hex = @import("../../core/encodings/hex.zig");
const fuzz = @import("../../core/fuzz.zig");

pub const ScriptError = error{
    TruncatedScript,
    /// The script has no address form (P2PK, bare multisig, OP_RETURN, nonstandard).
    NoAddress,
    BufferTooSmall,
};

pub const OP_0 = 0x00;
pub const OP_PUSHDATA1 = 0x4c;
pub const OP_PUSHDATA4 = 0x4e;
pub const OP_1 = 0x51;
pub const OP_13 = 0x5d;
pub const OP_16 = 0x60;
pub const OP_IF = 0x63;
pub const OP_ENDIF = 0x68;
pub const OP_RETURN = 0x6a;
pub const OP_DUP = 0x76;
pub const OP_EQUAL = 0x87;
pub const OP_EQUALVERIFY = 0x88;
pub const OP_HASH160 = 0xa9;
pub const OP_CHECKSIG = 0xac;
pub const OP_CHECKMULTISIG = 0xae;

pub const Instruction = struct {
    opcode: u8,
    /// Pushed bytes; empty for non-push opcodes and for OP_0.
    data: []const u8 = &.{},

    pub fn isPush(self: Instruction) bool {
        return self.opcode <= OP_PUSHDATA4;
    }
};

/// Walks a script one instruction at a time, with bounds checks on every push length.
pub const Iterator = struct {
    rest: []const u8,

    pub fn init(script: []const u8) Iterator {
        return .{ .rest = script };
    }

    /// Returns the next instruction, null at the end. A push running past the script end is
    /// `TruncatedScript`, after which the iterator is exhausted.
    pub fn next(self: *Iterator) ScriptError!?Instruction {
        if (self.rest.len == 0) return null;
        const op = self.rest[0];
        if (op == 0 or op > OP_PUSHDATA4) {
            self.rest = self.rest[1..];
            return .{ .opcode = op };
        }
        var hdr: usize = 1;
        var len: usize = op;
        if (op >= OP_PUSHDATA1) {
            const n = @as(usize, 1) << @intCast(op - OP_PUSHDATA1);
            if (self.rest.len - 1 < n) return self.fail();
            len = 0;
            for (self.rest[1..][0..n], 0..) |b, i| len |= @as(usize, b) << @intCast(8 * i);
            hdr += n;
        }
        if (self.rest.len - hdr < len) return self.fail();
        const data = self.rest[hdr .. hdr + len];
        self.rest = self.rest[hdr + len ..];
        return .{ .opcode = op, .data = data };
    }

    fn fail(self: *Iterator) ScriptError {
        self.rest = &.{};
        return ScriptError.TruncatedScript;
    }
};

pub const ScriptType = enum {
    p2pk,
    p2pkh,
    p2sh,
    p2wpkh,
    p2wsh,
    p2tr,
    /// Bare m-of-n multisig, see `multisigParams`.
    multisig,
    /// A well-formed witness program of a version/length with no defined meaning (v1 non-32, v2..v16).
    witness_unknown,
    op_return,
    unknown,
};

pub const Multisig = struct { m: u8, n: u8 };

fn smallInt(op: u8) ?u8 {
    return if (op >= OP_1 and op <= OP_16) op - 0x50 else null;
}

fn pubkeyLen(header: u8) ?usize {
    return switch (header) {
        2, 3 => 33,
        4, 6, 7 => 65,
        else => null,
    };
}

/// Parses `OP_m <pubkey>... OP_n OP_CHECKMULTISIG`; null if `script` is not that.
pub fn multisigParams(script: []const u8) ?Multisig {
    var it = Iterator.init(script);
    const first = (it.next() catch return null) orelse return null;
    const m = smallInt(first.opcode) orelse return null;
    var keys: u8 = 0;
    while (true) {
        const ins = (it.next() catch return null) orelse return null;
        if (smallInt(ins.opcode)) |n| {
            const last = (it.next() catch return null) orelse return null;
            if (last.opcode != OP_CHECKMULTISIG or it.rest.len != 0) return null;
            if (m > n or keys != n) return null;
            return .{ .m = m, .n = n };
        }
        if (!ins.isPush() or ins.data.len == 0 or pubkeyLen(ins.data[0]) != ins.data.len) return null;
        if (keys == 16) return null;
        keys += 1;
    }
}

pub const WitnessProgram = struct { version: u8, program: []const u8 };

/// Returns the witness program if `script` is `OP_n <2..40 byte push>` spanning the whole script (BIP-141).
pub fn witnessProgram(script: []const u8) ?WitnessProgram {
    if (script.len < 4 or script.len > 42) return null;
    const version: u8 = if (script[0] == OP_0) 0 else smallInt(script[0]) orelse return null;
    if (script[1] != script.len - 2) return null;
    return .{ .version = version, .program = script[2..] };
}

/// Classifies a scriptPubKey. Never fails; anything unrecognised is `.unknown`.
pub fn classifyScript(script: []const u8) ScriptType {
    if (script.len == 0) return .unknown;
    if (script[0] == OP_RETURN) return .op_return;
    if (script.len == 25 and script[0] == OP_DUP and script[1] == OP_HASH160 and script[2] == 20 and
        script[23] == OP_EQUALVERIFY and script[24] == OP_CHECKSIG) return .p2pkh;
    if (script.len == 23 and script[0] == OP_HASH160 and script[1] == 20 and script[22] == OP_EQUAL) return .p2sh;
    if (witnessProgram(script)) |w| {
        return switch (w.version) {
            0 => switch (w.program.len) {
                20 => .p2wpkh,
                32 => .p2wsh,
                else => .unknown, // BIP-141: other v0 lengths are invalid
            },
            1 => if (w.program.len == 32) .p2tr else .witness_unknown,
            else => .witness_unknown,
        };
    }
    if (script.len >= 35 and script[script.len - 1] == OP_CHECKSIG and
        pubkeyLen(script[1]) == script[0] and script.len == script[0] + 2) return .p2pk;
    if (multisigParams(script) != null) return .multisig;
    return .unknown;
}

/// Derives the address Bitcoin Core would show for `script` on `net`.
/// P2PK, bare multisig, OP_RETURN and nonstandard scripts have none: `NoAddress`.
pub fn deriveAddress(net: network.Network, script: []const u8, dest: []u8) ScriptError![]const u8 {
    switch (classifyScript(script)) {
        .p2pkh => return base58Address(net.p2pkh_version, script[3..23], dest),
        .p2sh => return base58Address(net.p2sh_version, script[2..22], dest),
        .p2wpkh, .p2wsh, .p2tr, .witness_unknown => {
            const w = witnessProgram(script).?;
            return bech32.encodeSegwit(net.segwit_hrp, w.version, w.program, dest) catch |e| return mapErr(e);
        },
        else => return ScriptError.NoAddress,
    }
}

fn base58Address(version: u8, hash: []const u8, dest: []u8) ScriptError![]const u8 {
    var payload: [21]u8 = undefined;
    payload[0] = version;
    @memcpy(payload[1..], hash);
    return base58.encodeCheck(&payload, dest) catch |e| return mapErr(e);
}

fn mapErr(e: anyerror) ScriptError {
    return if (e == error.BufferTooSmall) ScriptError.BufferTooSmall else ScriptError.NoAddress;
}

/// Writes `{"type":"p2pkh","address":"1..."}` (address null when none) into `dest`.
pub fn renderJson(net: network.Network, script: []const u8, dest: []u8) ScriptError![]const u8 {
    var addr_buf: [96]u8 = undefined;
    const kind = classifyScript(script);
    const addr: ?[]const u8 = deriveAddress(net, script, &addr_buf) catch |e| switch (e) {
        error.NoAddress => null,
        else => return e,
    };
    if (addr) |a| {
        return std.fmt.bufPrint(dest, "{{\"type\":\"{s}\",\"address\":\"{s}\"}}", .{ @tagName(kind), a }) catch ScriptError.BufferTooSmall;
    }
    return std.fmt.bufPrint(dest, "{{\"type\":\"{s}\",\"address\":null}}", .{@tagName(kind)}) catch ScriptError.BufferTooSmall;
}

fn filled(comptime n: usize, b: u8) [n]u8 {
    return @splat(b);
}

fn hexToBytes(s: []const u8, buf: []u8) []u8 {
    return hex.decodeHex(s, buf) catch unreachable; // test vectors are valid hex
}

test "REQ-UTXO-01 classify matches Bitcoin Core script_tests.json templates" {
    var buf: [128]u8 = undefined;
    for (vectors.CLASSES) |v| {
        const s = hexToBytes(v.script, &buf);
        try std.testing.expectEqualStrings(v.kind, @tagName(classifyScript(s)));
    }
}

test "REQ-UTXO-01 classify multisig, p2pk, witness unknown and rejects" {
    // BIP-11 style 1-of-2 with compressed keys
    const k = [_]u8{0x02} ++ filled(32, 0x11);
    const ms = [_]u8{0x51} ++ [_]u8{33} ++ k ++ [_]u8{33} ++ k ++ [_]u8{ 0x52, OP_CHECKMULTISIG };
    try std.testing.expectEqual(ScriptType.multisig, classifyScript(&ms));
    try std.testing.expectEqual(Multisig{ .m = 1, .n = 2 }, multisigParams(&ms).?);
    // m > n, key count mismatch, trailing byte
    var bad = ms;
    bad[bad.len - 2] = 0x51;
    bad[0] = 0x52;
    try std.testing.expectEqual(ScriptType.unknown, classifyScript(&bad));
    bad = ms;
    bad[bad.len - 2] = 0x53;
    try std.testing.expectEqual(ScriptType.unknown, classifyScript(&bad));
    try std.testing.expectEqual(ScriptType.unknown, classifyScript(&(ms ++ [_]u8{0x51})));
    // BIP-173 witness v16 (2 bytes) and v0 with a bad length
    try std.testing.expectEqual(ScriptType.witness_unknown, classifyScript(&[_]u8{ 0x60, 0x02, 0x75, 0x1e }));
    try std.testing.expectEqual(ScriptType.unknown, classifyScript(&[_]u8{ 0x00, 0x02, 0x75, 0x1e }));
    try std.testing.expectEqual(ScriptType.unknown, classifyScript(&[_]u8{ 0x51, 0x22 } ++ filled(32, 2)));
    try std.testing.expectEqual(ScriptType.op_return, classifyScript(&[_]u8{0x6a}));
    try std.testing.expectEqual(ScriptType.unknown, classifyScript(&.{}));
    // P2PK with a header that disagrees with the length
    const p2pk = [_]u8{33} ++ k ++ [_]u8{OP_CHECKSIG};
    try std.testing.expectEqual(ScriptType.p2pk, classifyScript(&p2pk));
    var wrong = p2pk;
    wrong[1] = 0x04;
    try std.testing.expectEqual(ScriptType.unknown, classifyScript(&wrong));
}

test "REQ-UTXO-01 derive addresses match Bitcoin Core and Litecoin Core key_io_valid.json" {
    var sbuf: [128]u8 = undefined;
    var abuf: [128]u8 = undefined;
    for (vectors.ADDRESSES) |v| {
        const s = hexToBytes(v.script, &sbuf);
        const got = try deriveAddress(network.all[v.net], s, &abuf);
        try std.testing.expectEqualStrings(v.address, got);
    }
}

test "REQ-UTXO-01 derive addresses for BIP-173, BIP-350 and BIP-86 scripts" {
    // sources: BIP-350 "Test vectors" (valid segwit addresses), BIP-86 test vector 1 (first receiving address)
    const cases = [_]struct { script: []const u8, addr: []const u8 }{
        .{ .script = "0014751e76e8199196d454941c45d1b3a323f1433bd6", .addr = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4" },
        .{ .script = "5128751e76e8199196d454941c45d1b3a323f1433bd6751e76e8199196d454941c45d1b3a323f1433bd6", .addr = "bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kt5nd6y" },
        .{ .script = "6002751e", .addr = "bc1sw50qgdz25j" },
        .{ .script = "5210751e76e8199196d454941c45d1b3a323", .addr = "bc1zw508d6qejxtdg4y5r3zarvaryvaxxpcs" },
        .{ .script = "0020000000c4a5cad46221b2a187905e5266362b99d5e91c6ce24d165dab93e86433", .addr = "tb1qqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesrxh6hy" },
        .{ .script = "5120000000c4a5cad46221b2a187905e5266362b99d5e91c6ce24d165dab93e86433", .addr = "tb1pqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesf3hn0c" },
        .{ .script = "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", .addr = "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0" },
        .{ .script = "5120a60869f0dbcf1dc659c9cecbaf8050135ea9e8cdc487053f1dc6880949dc684c", .addr = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr" },
    };
    var sbuf: [64]u8 = undefined;
    var abuf: [96]u8 = undefined;
    for (cases) |c| {
        const s = hexToBytes(c.script, &sbuf);
        const net = if (std.mem.startsWith(u8, c.addr, "tb")) network.bitcoin_testnet else network.bitcoin_mainnet;
        try std.testing.expectEqualStrings(c.addr, try deriveAddress(net, s, &abuf));
    }
    // same program, other network HRP (BIP-173 lists tb1qw508... for the mainnet program above)
    const prog = hexToBytes("0014751e76e8199196d454941c45d1b3a323f1433bd6", &sbuf);
    try std.testing.expectEqualStrings("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", try deriveAddress(network.bitcoin_testnet, prog, &abuf));
}

test "REQ-UTXO-01 no address and buffer errors" {
    var buf: [100]u8 = undefined;
    try std.testing.expectError(ScriptError.NoAddress, deriveAddress(network.bitcoin_mainnet, &[_]u8{0x6a}, &buf));
    try std.testing.expectError(ScriptError.NoAddress, deriveAddress(network.bitcoin_mainnet, &.{}, &buf));
    var s = [_]u8{ 0x76, 0xa9, 20 } ++ filled(20, 0x11) ++ [_]u8{ 0x88, 0xac };
    try std.testing.expectError(ScriptError.BufferTooSmall, deriveAddress(network.bitcoin_mainnet, &s, buf[0..10]));
    try std.testing.expectEqualStrings("{\"type\":\"op_return\",\"address\":null}", try renderJson(network.bitcoin_mainnet, &[_]u8{0x6a}, &buf));
    try std.testing.expectError(ScriptError.BufferTooSmall, renderJson(network.bitcoin_mainnet, &s, buf[0..10]));
    _ = &s;
}

test "REQ-UTXO-02 iterator decodes pushes and flags truncation" {
    const s = [_]u8{ 0x00, 0x02, 'a', 'b', 0x4c, 0x01, 'c', 0x4d, 0x01, 0x00, 'd', 0x51, 0xac };
    var it = Iterator.init(&s);
    try std.testing.expectEqual(@as(usize, 0), (try it.next()).?.data.len);
    try std.testing.expectEqualStrings("ab", (try it.next()).?.data);
    try std.testing.expectEqualStrings("c", (try it.next()).?.data);
    try std.testing.expectEqualStrings("d", (try it.next()).?.data);
    try std.testing.expect(!(try it.next()).?.isPush());
    try std.testing.expectEqual(@as(u8, 0xac), (try it.next()).?.opcode);
    try std.testing.expect((try it.next()) == null);
    for ([_][]const u8{ &.{0x05}, &.{ 0x4c, 0x05, 1 }, &.{0x4d}, &.{ 0x4e, 0xff, 0xff, 0xff, 0xff } }) |bad| {
        var bi = Iterator.init(bad);
        try std.testing.expectError(ScriptError.TruncatedScript, bi.next());
        try std.testing.expect((try bi.next()) == null);
    }
}

fn walk(_: void, bytes: []const u8) void {
    var it = Iterator.init(bytes);
    while (it.next() catch null) |_| {}
    _ = multisigParams(bytes);
    const t = classifyScript(bytes);
    var out: [128]u8 = undefined;
    for (network.all) |n| {
        _ = deriveAddress(n, bytes, &out) catch {};
        _ = renderJson(n, bytes, &out) catch {};
    }
    _ = t;
}

test "REQ-UTXO-01 script fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [128]u8 = undefined;
            const n = smith.slice(&buf);
            walk({}, buf[0..n]);
        }
    }.f, .{});
}

test "REQ-UTXO-01 script mutation stress" {
    var sbuf: [128]u8 = undefined;
    var seeds: [vectors.CLASSES.len + vectors.ADDRESSES.len][]const u8 = undefined;
    var store: [seeds.len][80]u8 = undefined;
    var i: usize = 0;
    for (vectors.CLASSES) |v| {
        seeds[i] = hexToBytes(v.script, &store[i]);
        i += 1;
    }
    for (vectors.ADDRESSES) |v| {
        seeds[i] = hexToBytes(v.script, &store[i]);
        i += 1;
    }
    _ = &sbuf;
    fuzz.stress(200_000, &seeds, {}, walk);
}
