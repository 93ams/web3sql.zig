const std = @import("std");
const keccak = @import("../../core/crypto/keccak.zig");
const hex = @import("../../core/encodings/hex.zig");

pub const Address = [20]u8;

pub const AddressError = error{
    InvalidLength,
    InvalidHex,
    ChecksumFailed,
    BufferTooSmall,
};

/// Validates or formats an address with EIP-55 mixed-case checksum.
pub fn toChecksumAddress(addr: *const Address, dest: *[42]u8) void {
    dest[0] = '0';
    dest[1] = 'x';
    var hex_raw: [40]u8 = undefined;
    _ = hex.encodeHex(addr, &hex_raw) catch unreachable;

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

test "eip55 checksum" {
    // 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed
    var addr_bytes: [20]u8 = undefined;
    _ = try hex.decodeHex("5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", &addr_bytes);

    var formatted: [42]u8 = undefined;
    toChecksumAddress(&addr_bytes, &formatted);
    try std.testing.expectEqualStrings("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", &formatted);
}
