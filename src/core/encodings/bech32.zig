const std = @import("std");
const vectors = @import("bech32_vectors.zig");

pub const Bech32Error = error{
    InvalidCharacter,
    InvalidChecksum,
    InvalidLength,
    InvalidHrp,
    InvalidPadding,
    InvalidWitness,
    MixedCase,
    BufferTooSmall,
};

pub const CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
pub const MAX_LENGTH: usize = 90;
pub const MAX_HRP_LENGTH: usize = 83;
const CHECKSUM_LENGTH = 6;

/// Bech32 encoding variant
pub const Variant = enum(u32) {
    bech32 = 1,
    bech32m = 0x2bc830a3,
};

const GENERATOR = [_]u32{ 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };

const CHARSET_REV: [256]u8 = blk: {
    var map: [256]u8 = @splat(0xFF);
    for (CHARSET, 0..) |c, i| map[c] = i;
    break :blk map;
};

fn polymodStep(chk: u32, v: u5) u32 {
    const top: u5 = @intCast(chk >> 25);
    var next = ((chk & 0x1ffffff) << 5) ^ v;
    for (GENERATOR, 0..) |g, i| {
        if ((top >> @intCast(i)) & 1 != 0) next ^= g;
    }
    return next;
}

/// Polymod checksum computation for Bech32/Bech32m.
pub fn polymod(values: []const u5) u32 {
    var chk: u32 = 1;
    for (values) |v| chk = polymodStep(chk, v);
    return chk;
}

fn hrpChecksum(hrp: []const u8) u32 {
    var chk: u32 = 1;
    for (hrp) |c| chk = polymodStep(chk, @intCast(c >> 5));
    chk = polymodStep(chk, 0);
    for (hrp) |c| chk = polymodStep(chk, @truncate(c));
    return chk;
}

fn validateHrp(hrp: []const u8) Bech32Error!void {
    if (hrp.len == 0 or hrp.len > MAX_HRP_LENGTH) return Bech32Error.InvalidHrp;
    for (hrp) |c| {
        if (c < 33 or c > 126 or std.ascii.isUpper(c)) return Bech32Error.InvalidHrp;
    }
}

/// Encodes 5-bit `data` under a lowercase `hrp`, appending the six-character checksum.
pub fn encode(hrp: []const u8, data: []const u5, variant: Variant, dest: []u8) Bech32Error![]const u8 {
    try validateHrp(hrp);
    const total = hrp.len + 1 + data.len + CHECKSUM_LENGTH;
    if (total > MAX_LENGTH) return Bech32Error.InvalidLength;
    if (dest.len < total) return Bech32Error.BufferTooSmall;

    @memcpy(dest[0..hrp.len], hrp);
    dest[hrp.len] = '1';
    var chk = hrpChecksum(hrp);
    for (data, dest[hrp.len + 1 ..][0..data.len]) |d, *out| {
        chk = polymodStep(chk, d);
        out.* = CHARSET[d];
    }
    for (0..CHECKSUM_LENGTH) |_| chk = polymodStep(chk, 0);
    chk ^= @backingInt(variant);
    for (dest[total - CHECKSUM_LENGTH .. total], 0..) |*out, i| {
        out.* = CHARSET[(chk >> @intCast(5 * (5 - i))) & 31];
    }
    return dest[0..total];
}

pub const Decoded = struct {
    hrp: []const u8,
    data: []const u5,
    variant: Variant,
};

/// Decodes and verifies a Bech32 or Bech32m string. The HRP is returned lowercased.
pub fn decode(src: []const u8, hrp_buf: []u8, data_buf: []u5) Bech32Error!Decoded {
    if (src.len < CHECKSUM_LENGTH + 2 or src.len > MAX_LENGTH) return Bech32Error.InvalidLength;
    var has_lower = false;
    var has_upper = false;
    var sep: ?usize = null;
    for (src, 0..) |c, i| {
        if (c < 33 or c > 126) return Bech32Error.InvalidCharacter;
        has_lower = has_lower or std.ascii.isLower(c);
        has_upper = has_upper or std.ascii.isUpper(c);
        if (c == '1') sep = i;
    }
    if (has_lower and has_upper) return Bech32Error.MixedCase;
    const pos = sep orelse return Bech32Error.InvalidCharacter;
    if (pos == 0 or pos > MAX_HRP_LENGTH) return Bech32Error.InvalidHrp;
    if (src.len - pos - 1 < CHECKSUM_LENGTH) return Bech32Error.InvalidLength;

    if (hrp_buf.len < pos) return Bech32Error.BufferTooSmall;
    const hrp = std.ascii.lowerString(hrp_buf[0..pos], src[0..pos]);
    const part = src[pos + 1 ..];
    const data_len = part.len - CHECKSUM_LENGTH;
    if (data_buf.len < data_len) return Bech32Error.BufferTooSmall;

    var chk = hrpChecksum(hrp);
    for (part, 0..) |c, i| {
        const v = CHARSET_REV[std.ascii.toLower(c)];
        if (v == 0xFF) return Bech32Error.InvalidCharacter;
        chk = polymodStep(chk, @intCast(v));
        if (i < data_len) data_buf[i] = @intCast(v);
    }
    const variant: Variant = switch (chk) {
        @backingInt(Variant.bech32) => .bech32,
        @backingInt(Variant.bech32m) => .bech32m,
        else => return Bech32Error.InvalidChecksum,
    };
    return .{ .hrp = hrp, .data = data_buf[0..data_len], .variant = variant };
}

/// Regroups bytes into 5-bit groups, zero-padding the last one.
pub fn bytesToFive(src: []const u8, dest: []u5) Bech32Error![]const u5 {
    const out_len = (src.len * 8 + 4) / 5;
    if (dest.len < out_len) return Bech32Error.BufferTooSmall;
    var acc: u16 = 0;
    var bits: u4 = 0;
    var at: usize = 0;
    for (src) |b| {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            dest[at] = @truncate(acc >> bits);
            at += 1;
        }
        acc &= (@as(u16, 1) << bits) - 1;
    }
    if (bits > 0) {
        dest[at] = @truncate(acc << (5 - bits));
        at += 1;
    }
    return dest[0..at];
}

/// Regroups 5-bit groups into bytes. Padding must be under 5 bits and all zero (BIP-173).
pub fn fiveToBytes(src: []const u5, dest: []u8) Bech32Error![]u8 {
    const out_len = src.len * 5 / 8;
    if (dest.len < out_len) return Bech32Error.BufferTooSmall;
    var acc: u16 = 0;
    var bits: u4 = 0;
    var at: usize = 0;
    for (src) |v| {
        acc = (acc << 5) | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            dest[at] = @truncate(acc >> bits);
            at += 1;
        }
        acc &= (@as(u16, 1) << bits) - 1;
    }
    if (bits >= 5 or acc != 0) return Bech32Error.InvalidPadding;
    return dest[0..at];
}

fn validateWitness(version: u8, program_len: usize) Bech32Error!void {
    if (version > 16 or program_len < 2 or program_len > 40) return Bech32Error.InvalidWitness;
    if (version == 0 and program_len != 20 and program_len != 32) return Bech32Error.InvalidWitness;
}

/// Encodes a Segwit address (BIP-173 for v0, BIP-350 for v1+).
pub fn encodeSegwit(hrp: []const u8, version: u8, program: []const u8, dest: []u8) Bech32Error![]const u8 {
    try validateWitness(version, program.len);
    var data: [66]u5 = undefined;
    data[0] = @intCast(version);
    const five = try bytesToFive(program, data[1..]);
    return encode(hrp, data[0 .. five.len + 1], if (version == 0) .bech32 else .bech32m, dest);
}

pub const SegwitAddress = struct {
    hrp: []const u8,
    version: u8,
    program: []const u8,
};

/// Decodes and validates a Segwit address. Caller checks `hrp` against its network.
pub fn decodeSegwit(src: []const u8, hrp_buf: []u8, program_buf: []u8) Bech32Error!SegwitAddress {
    var data: [MAX_LENGTH]u5 = undefined;
    const d = try decode(src, hrp_buf, &data);
    if (d.data.len == 0) return Bech32Error.InvalidWitness;
    const version = d.data[0];
    if (d.variant != (if (version == 0) Variant.bech32 else Variant.bech32m)) return Bech32Error.InvalidChecksum;
    const program = try fiveToBytes(d.data[1..], program_buf);
    try validateWitness(version, program.len);
    return .{ .hrp = d.hrp, .version = version, .program = program };
}

test "bech32 polymod sanity" {
    const vals = [_]u5{ 0, 1, 2 };
    const p = polymod(&vals);
    try std.testing.expect(p != 0);
}

test "REQ-CORE-02 bech32 BIP-173 and BIP-350 checksum vectors" {
    var hrp: [MAX_HRP_LENGTH]u8 = undefined;
    var data: [MAX_LENGTH]u5 = undefined;
    var txt: [MAX_LENGTH]u8 = undefined;
    for (vectors.VALID_BECH32) |s| {
        const d = try decode(s, &hrp, &data);
        try std.testing.expectEqual(Variant.bech32, d.variant);
        const re = try encode(d.hrp, d.data, d.variant, &txt);
        try std.testing.expect(std.ascii.eqlIgnoreCase(s, re));
    }
    for (vectors.VALID_BECH32M) |s| {
        const d = try decode(s, &hrp, &data);
        try std.testing.expectEqual(Variant.bech32m, d.variant);
        const re = try encode(d.hrp, d.data, d.variant, &txt);
        try std.testing.expect(std.ascii.eqlIgnoreCase(s, re));
    }
    for (vectors.INVALID_BECH32) |s| {
        if (decode(s, &hrp, &data)) |d| {
            try std.testing.expect(d.variant != .bech32);
        } else |_| {}
    }
    for (vectors.INVALID_BECH32M) |s| {
        if (decode(s, &hrp, &data)) |d| {
            try std.testing.expect(d.variant != .bech32m);
        } else |_| {}
    }
}

test "REQ-CORE-02 bech32 segwit address vectors" {
    const hex = @import("hex.zig");
    var hrp: [MAX_HRP_LENGTH]u8 = undefined;
    var prog: [MAX_LENGTH]u8 = undefined;
    var script: [64]u8 = undefined;
    var txt: [MAX_LENGTH]u8 = undefined;
    for (vectors.VALID_ADDRESS) |v| {
        const a = try decodeSegwit(v.addr, &hrp, &prog);
        const expected = try hex.decodeHex(v.script_hex, &script);
        try std.testing.expectEqual(if (a.version == 0) @as(u8, 0) else a.version + 0x50, expected[0]);
        try std.testing.expectEqual(a.program.len, expected[1]);
        try std.testing.expectEqualSlices(u8, expected[2..], a.program);
        const re = try encodeSegwit(a.hrp, a.version, a.program, &txt);
        try std.testing.expect(std.ascii.eqlIgnoreCase(v.addr, re));
    }
    for (vectors.INVALID_ADDRESS) |s| {
        if (decodeSegwit(s, &hrp, &prog)) |a| {
            // Only the deliberately unknown-HRP vector decodes; a network check rejects it.
            try std.testing.expect(!std.mem.eql(u8, a.hrp, "bc") and !std.mem.eql(u8, a.hrp, "tb"));
        } else |_| {}
    }
    const zeros: [64]u8 = @splat(0);
    for (vectors.INVALID_ADDRESS_ENC) |v| {
        if (encodeSegwit(v.hrp, v.version, zeros[0..v.len], &txt)) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "REQ-CORE-02 bech32 convert bits padding" {
    var five: [8]u5 = undefined;
    var bytes: [5]u8 = undefined;
    const in = [_]u8{ 0xAB, 0xCD, 0xEF, 0x01, 0x23 };
    const f = try bytesToFive(&in, &five);
    try std.testing.expectEqual(@as(usize, 8), f.len);
    try std.testing.expectEqualSlices(u8, &in, try fiveToBytes(f, &bytes));
    try std.testing.expectError(Bech32Error.InvalidPadding, fiveToBytes(&[_]u5{ 1, 1 }, &bytes));
    try std.testing.expectError(Bech32Error.InvalidPadding, fiveToBytes(&[_]u5{0}, &bytes));
    try std.testing.expectError(Bech32Error.BufferTooSmall, bytesToFive(&in, five[0..7]));
}

test "bech32 fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [128]u8 = undefined;
            var hrp: [MAX_HRP_LENGTH]u8 = undefined;
            var data: [MAX_LENGTH]u5 = undefined;
            var prog: [MAX_LENGTH]u8 = undefined;
            const n = smith.slice(&buf);
            _ = decode(buf[0..n], &hrp, &data) catch {};
            _ = decodeSegwit(buf[0..n], &hrp, &prog) catch {};
        }
    }.f, .{});
}
