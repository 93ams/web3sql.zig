const std = @import("std");
const keccak = @import("../../core/crypto/keccak.zig");
const hex = @import("../../core/encodings/hex.zig");
const core_fuzz = @import("../../core/fuzz.zig");
const vectors = @import("abi_vectors.zig");

pub const Address = [20]u8;

pub const AddressError = error{
    InvalidLength,
    InvalidHex,
    ChecksumFailed,
    BufferTooSmall,
};

/// Formats an address with its EIP-55 mixed-case checksum.
pub fn toChecksumAddress(addr: *const Address, dest: *[42]u8) void {
    dest[0] = '0';
    dest[1] = 'x';
    var hex_raw: [40]u8 = undefined;
    for (addr, 0..) |b, i| {
        hex_raw[i * 2] = hex.HEX_LOWER[b >> 4];
        hex_raw[i * 2 + 1] = hex.HEX_LOWER[b & 0x0F];
    }

    var hash_buf: [32]u8 = undefined;
    keccak.hash(&hex_raw, &hash_buf);

    for (0..40) |i| {
        const c = hex_raw[i];
        if (c >= 'a' and c <= 'f') {
            const hash_byte = hash_buf[i / 2];
            const nibble: u4 = if (i % 2 == 0) @intCast(hash_byte >> 4) else @intCast(hash_byte & 0x0F);
            if (nibble >= 8) {
                dest[2 + i] = c - 32; // Uppercase
            } else {
                dest[2 + i] = c;
            }
        } else {
            dest[2 + i] = c;
        }
    }
}

/// Row shape of `toChecksumAddress`: 20 raw bytes in, 42 checksummed characters out.
pub fn checksumAddress(raw: []const u8, dest: []u8) AddressError![]const u8 {
    if (raw.len != 20) return AddressError.InvalidLength;
    if (dest.len < 42) return AddressError.BufferTooSmall;
    toChecksumAddress(raw[0..20], dest[0..42]);
    return dest[0..42];
}

/// Parses 40 hex characters, with or without 0x, ignoring letter case. Use `validateChecksumAddress` to enforce EIP-55.
pub fn parseAddress(s: []const u8) AddressError!Address {
    const has_prefix = s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X');
    if (s.len != @as(usize, if (has_prefix) 42 else 40)) return AddressError.InvalidLength;
    var addr: Address = undefined;
    _ = hex.decodeHex(s, &addr) catch return AddressError.InvalidHex;
    return addr;
}

/// Derives a CREATE address: keccak256(rlp([sender, nonce]))[12..].
pub fn deriveCreateAddress(sender: *const Address, nonce: u64) Address {
    // list payload: 0x94 + 20 address bytes + nonce item (at most 9 bytes)
    var buf: [1 + 1 + 20 + 9]u8 = undefined;
    var n: usize = 2;
    buf[1] = 0x94;
    @memcpy(buf[n..][0..20], sender);
    n += 20;
    if (nonce == 0) {
        buf[n] = 0x80;
        n += 1;
    } else if (nonce < 0x80) {
        buf[n] = @intCast(nonce);
        n += 1;
    } else {
        var be: [8]u8 = undefined;
        std.mem.writeInt(u64, &be, nonce, .big);
        const lead = @clz(nonce) / 8;
        const len = 8 - lead;
        buf[n] = 0x80 + @as(u8, @intCast(len));
        @memcpy(buf[n + 1 ..][0..len], be[lead..]);
        n += 1 + len;
    }
    buf[0] = 0xc0 + @as(u8, @intCast(n - 1));
    var out: [32]u8 = undefined;
    keccak.hash(buf[0..n], &out);
    return out[12..32].*;
}

/// Derives a CREATE2 address (EIP-1014): keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))[12..].
pub fn deriveCreate2Address(sender: *const Address, salt: *const [32]u8, init_code_hash: *const [32]u8) Address {
    var buf: [1 + 20 + 32 + 32]u8 = undefined;
    buf[0] = 0xff;
    @memcpy(buf[1..21], sender);
    @memcpy(buf[21..53], salt);
    @memcpy(buf[53..85], init_code_hash);
    var out: [32]u8 = undefined;
    keccak.hash(&buf, &out);
    return out[12..32].*;
}

/// Validates an EIP-55 address string. All-lower or all-upper hex is accepted (no checksum claimed);
/// mixed case must match the checksum.
pub fn validateChecksumAddress(s: []const u8) AddressError!Address {
    if (s.len != 42 or s[0] != '0' or (s[1] != 'x' and s[1] != 'X')) return AddressError.InvalidLength;
    var addr: Address = undefined;
    _ = hex.decodeHex(s, &addr) catch return AddressError.InvalidHex;
    var lower = false;
    var upper = false;
    for (s[2..]) |c| {
        if (c >= 'a' and c <= 'f') lower = true;
        if (c >= 'A' and c <= 'F') upper = true;
    }
    if (lower and upper) {
        var expected: [42]u8 = undefined;
        toChecksumAddress(&addr, &expected);
        if (!std.mem.eql(u8, s[2..], expected[2..])) return AddressError.ChecksumFailed;
    }
    return addr;
}

fn parseAddr(s: []const u8) Address {
    var a: Address = undefined;
    _ = hex.decodeHex(s, &a) catch unreachable;
    return a;
}

test "REQ-EVM-01 CREATE address" {
    // Well-known deployer 0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0, nonces 0..2
    const sender = parseAddr("6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0");
    try std.testing.expectEqual(parseAddr("cd234a471b72ba2f1ccf0a70fcaba648a5eecd8d"), deriveCreateAddress(&sender, 0));
    try std.testing.expectEqual(parseAddr("343c43a37d37dff08ae8c4a11544c718abb4fcf8"), deriveCreateAddress(&sender, 1));
    try std.testing.expectEqual(parseAddr("f778b86fa74e846c4f0a1fbd1335fe81c00a0c91"), deriveCreateAddress(&sender, 2));
}

test "REQ-EVM-01 CREATE2 address (EIP-1014 examples)" {
    var h: [32]u8 = undefined;
    keccak.hash("\x00", &h);
    const zero: Address = @splat(0);
    const salt: [32]u8 = @splat(0);
    try std.testing.expectEqual(parseAddr("4D1A2e2bB4F88F0250f26Ffff098B0b30B26BF38"), deriveCreate2Address(&zero, &salt, &h));
    const dead = parseAddr("deadbeef00000000000000000000000000000000");
    try std.testing.expectEqual(parseAddr("B928f69Bb1D91Cd65274e3c79d8986362984fDA3"), deriveCreate2Address(&dead, &salt, &h));
}

test "REQ-EVM-01 validate checksum" {
    _ = try validateChecksumAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
    _ = try validateChecksumAddress("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
    try std.testing.expectError(AddressError.ChecksumFailed, validateChecksumAddress("0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"));
    try std.testing.expectError(AddressError.InvalidLength, validateChecksumAddress("0x1234"));
}

// Source: EIP-55, "Test Cases" (all caps, all lower, normal). EIP-1014 examples 0..6 for CREATE2.
test "REQ-EVM-01 EIP-55 vectors round-trip" {
    const cases = [_][]const u8{
        "0x52908400098527886E0F7030069857D2E4169EE7", "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
        "0xde709f2102306220921060314715629080e2fb77", "0x27b1fdb04752bbc536007a920d24acb045561c26",
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB", "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
    };
    for (cases) |c| {
        const addr = try validateChecksumAddress(c);
        var out: [42]u8 = undefined;
        try std.testing.expectEqualStrings(c, try checksumAddress(&addr, &out));
    }
}

test "REQ-EVM-01 parseAddress ignores checksum, rejects bad shapes" {
    const want = parseAddr("5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
    try std.testing.expectEqual(want, try parseAddress("0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"));
    try std.testing.expectEqual(want, try parseAddress("5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"));
    try std.testing.expectError(AddressError.InvalidLength, parseAddress("0x5aAe"));
    try std.testing.expectError(AddressError.InvalidLength, parseAddress(""));
    try std.testing.expectError(AddressError.InvalidHex, parseAddress("0xzzAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"));
    var out: [41]u8 = undefined;
    try std.testing.expectError(AddressError.BufferTooSmall, checksumAddress(&want, &out));
    try std.testing.expectError(AddressError.InvalidLength, checksumAddress("short", &out));
}

test "REQ-EVM-01 CREATE at RLP nonce boundaries" {
    const sender = parseAddr(vectors.create_sender);
    for (vectors.creates) |c| try std.testing.expectEqual(parseAddr(c.address), deriveCreateAddress(&sender, c.nonce));
}

test "REQ-EVM-01 CREATE2 remaining EIP-1014 examples" {
    const Case = struct { sender: []const u8, salt: []const u8, code: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .sender = "deadbeef00000000000000000000000000000000", .salt = "000000000000000000000000feed000000000000000000000000000000000000", .code = "00", .want = "D04116cDd17beBE565EB2422F2497E06cC1C9833" },
        .{ .sender = "0000000000000000000000000000000000000000", .salt = "0000000000000000000000000000000000000000000000000000000000000000", .code = "deadbeef", .want = "70f2b2914A2a4b783FaEFb75f459A580616Fcb5e" },
        .{ .sender = "00000000000000000000000000000000deadbeef", .salt = "00000000000000000000000000000000000000000000000000000000cafebabe", .code = "deadbeef", .want = "60f3f640a8508fC6a86d45DF051962668E1e8AC7" },
        .{ .sender = "00000000000000000000000000000000deadbeef", .salt = "00000000000000000000000000000000000000000000000000000000cafebabe", .code = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef", .want = "1d8bfDC5D46DC4f61D6b6115972536eBE6A8854C" },
        .{ .sender = "0000000000000000000000000000000000000000", .salt = "0000000000000000000000000000000000000000000000000000000000000000", .code = "", .want = "E33C0C7F7df4809055C3ebA6c09CFe4BaF1BD9e0" },
    };
    for (cases) |c| {
        const sender = parseAddr(c.sender);
        var salt: [32]u8 = undefined;
        _ = try hex.decodeHex(c.salt, &salt);
        var code: [64]u8 = undefined;
        var code_hash: [32]u8 = undefined;
        keccak.hash(try hex.decodeHex(c.code, &code), &code_hash);
        try std.testing.expectEqual(parseAddr(c.want), deriveCreate2Address(&sender, &salt, &code_hash));
    }
}

fn parseAll(_: void, bytes: []const u8) void {
    _ = parseAddress(bytes) catch {};
    _ = validateChecksumAddress(bytes) catch {};
    var out: [42]u8 = undefined;
    _ = checksumAddress(bytes, &out) catch {};
}

test "REQ-EVM-01 address parser stress" {
    core_fuzz.stress(200_000, &.{ "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed", "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13" }, {}, parseAll);
}

test "REQ-EVM-01 address parser fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [64]u8 = undefined;
            parseAll({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "eip55 checksum" {
    // 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed
    var addr_bytes: [20]u8 = undefined;
    _ = try hex.decodeHex("5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", &addr_bytes);

    var formatted: [42]u8 = undefined;
    toChecksumAddress(&addr_bytes, &formatted);
    try std.testing.expectEqualStrings("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", &formatted);
}
