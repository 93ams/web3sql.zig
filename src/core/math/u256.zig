const std = @import("std");

pub const U256 = u256;
pub const I256 = i256;
pub const U128 = u128;
pub const I128 = i128;

pub const MathError = error{
    Overflow,
    DivisionByZero,
    InvalidCharacter,
    BufferTooSmall,
};

/// Longest decimal rendering of a u256 / i256 (i256 min has a sign and 77 digits).
pub const MAX_DECIMAL_LEN: usize = 78;

/// Computes floor((a * b) / c) with intermediate u512 precision.
pub fn mulDiv(a: u256, b: u256, c: u256) MathError!u256 {
    if (c == 0) return MathError.DivisionByZero;
    const prod = @as(u512, a) * b;
    return std.math.cast(u256, prod / c) orelse MathError.Overflow;
}

/// Computes ceil((a * b) / c), Uniswap `FullMath.mulDivRoundingUp`.
pub fn mulDivRoundingUp(a: u256, b: u256, c: u256) MathError!u256 {
    if (c == 0) return MathError.DivisionByZero;
    const prod = @as(u512, a) * b;
    const quotient = prod / c;
    const rounded = quotient + @intFromBool(prod % c != 0);
    return std.math.cast(u256, rounded) orelse MathError.Overflow;
}

/// Checked addition (u256 or i256) returning MathError on overflow.
pub fn checkedAdd(a: anytype, b: @TypeOf(a)) MathError!@TypeOf(a) {
    const res, const ov = @addWithOverflow(a, b);
    if (ov != 0) return MathError.Overflow;
    return res;
}

/// Checked subtraction (u256 or i256) returning MathError on overflow/underflow.
pub fn checkedSub(a: anytype, b: @TypeOf(a)) MathError!@TypeOf(a) {
    const res, const ov = @subWithOverflow(a, b);
    if (ov != 0) return MathError.Overflow;
    return res;
}

/// Checked multiplication (u256 or i256) returning MathError on overflow.
pub fn checkedMul(a: anytype, b: @TypeOf(a)) MathError!@TypeOf(a) {
    const res, const ov = @mulWithOverflow(a, b);
    if (ov != 0) return MathError.Overflow;
    return res;
}

/// Signed division rounding toward zero. `minInt / -1` is an overflow, not a panic.
pub fn divTrunc(a: i256, b: i256) MathError!i256 {
    if (b == 0) return MathError.DivisionByZero;
    if (a == std.math.minInt(i256) and b == -1) return MathError.Overflow;
    return @divTrunc(a, b);
}

/// Signed division rounding toward negative infinity.
pub fn divFloor(a: i256, b: i256) MathError!i256 {
    if (b == 0) return MathError.DivisionByZero;
    if (a == std.math.minInt(i256) and b == -1) return MathError.Overflow;
    return @divFloor(a, b);
}

/// floor(sqrt(x)).
pub fn isqrt(x: u256) u128 {
    return std.math.sqrt(x);
}

pub fn toBytes(value: u256, endian: std.builtin.Endian) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, value, endian);
    return out;
}

pub fn fromBytes(bytes: *const [32]u8, endian: std.builtin.Endian) u256 {
    return std.mem.readInt(u256, bytes, endian);
}

/// Strict decimal parser: ASCII digits only, no sign, no separators.
pub fn parseDecimal(s: []const u8) MathError!u256 {
    if (s.len == 0) return MathError.InvalidCharacter;
    var value: u256 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return MathError.InvalidCharacter;
        value = try checkedAdd(try checkedMul(value, 10), @as(u256, c - '0'));
    }
    return value;
}

/// Strict decimal parser with an optional leading '-'.
pub fn parseDecimalSigned(s: []const u8) MathError!i256 {
    if (s.len > 0 and s[0] == '-') {
        const magnitude = try parseDecimal(s[1..]);
        if (magnitude > @as(u256, 1) << 255) return MathError.Overflow;
        return @intCast(-@as(i257, magnitude));
    }
    return std.math.cast(i256, try parseDecimal(s)) orelse MathError.Overflow;
}

/// Limb-wise conversion, because generic u256 division per digit dominates SQL VARCHAR output.
pub fn formatDecimal(value: u256, dest: []u8) MathError![]const u8 {
    var limbs: [8]u32 = undefined;
    var v = value;
    for (&limbs) |*l| {
        l.* = @truncate(v);
        v >>= 32;
    }
    var buf: [81]u8 = undefined; // whole 9-digit chunks: 78 digits round up to 81
    var at: usize = buf.len;
    while (true) {
        var rem: u64 = 0;
        var i: usize = limbs.len;
        while (i > 0) {
            i -= 1;
            const acc = (rem << 32) | limbs[i];
            limbs[i] = @intCast(acc / 1_000_000_000);
            rem = acc % 1_000_000_000;
        }
        var chunk: u32 = @intCast(rem);
        for (0..9) |_| {
            at -= 1;
            buf[at] = '0' + @as(u8, @intCast(chunk % 10));
            chunk /= 10;
        }
        if (std.mem.allEqual(u32, &limbs, 0)) break;
    }
    while (at < buf.len - 1 and buf[at] == '0') at += 1;
    const digits = buf[at..];
    if (dest.len < digits.len) return MathError.BufferTooSmall;
    @memcpy(dest[0..digits.len], digits);
    return dest[0..digits.len];
}

pub fn formatDecimalSigned(value: i256, dest: []u8) MathError![]const u8 {
    if (value >= 0) return formatDecimal(@intCast(value), dest);
    if (dest.len == 0) return MathError.BufferTooSmall;
    dest[0] = '-';
    const digits = try formatDecimal(@abs(value), dest[1..]);
    return dest[0 .. digits.len + 1];
}

test "u256 checked arithmetic" {
    const a: u256 = 1000;
    const b: u256 = 2000;
    try std.testing.expectEqual(@as(u256, 3000), try checkedAdd(a, b));
    try std.testing.expectEqual(@as(u256, 1000), try checkedSub(b, a));
    try std.testing.expectError(MathError.Overflow, checkedSub(a, b));
}

test "u256 mulDiv" {
    const a: u256 = 1 << 200;
    const b: u256 = 1 << 50;
    const c: u256 = 1 << 50;
    try std.testing.expectEqual(a, try mulDiv(a, b, c));
    try std.testing.expectError(MathError.DivisionByZero, mulDiv(a, b, 0));
}

test "REQ-CORE-01 i256 edges" {
    const min: i256 = std.math.minInt(i256);
    const max: i256 = std.math.maxInt(i256);
    try std.testing.expectError(MathError.Overflow, checkedAdd(max, @as(i256, 1)));
    try std.testing.expectError(MathError.Overflow, checkedSub(min, @as(i256, 1)));
    try std.testing.expectError(MathError.Overflow, checkedMul(min, @as(i256, -1)));
    try std.testing.expectError(MathError.Overflow, divTrunc(min, -1));
    try std.testing.expectError(MathError.Overflow, divFloor(min, -1));
    try std.testing.expectError(MathError.DivisionByZero, divFloor(1, 0));
    try std.testing.expectEqual(@as(i256, -3), try divTrunc(-7, 2));
    try std.testing.expectEqual(@as(i256, -4), try divFloor(-7, 2));
}

test "REQ-CORE-01 mulDivRoundingUp and isqrt" {
    try std.testing.expectEqual(@as(u256, 3), try mulDivRoundingUp(5, 1, 2));
    try std.testing.expectEqual(@as(u256, 2), try mulDivRoundingUp(4, 1, 2));
    const max: u256 = std.math.maxInt(u256);
    try std.testing.expectEqual(max, try mulDivRoundingUp(max, max, max));
    try std.testing.expectError(MathError.Overflow, mulDivRoundingUp(max, max, max - 1));
    try std.testing.expectEqual(@as(u128, std.math.maxInt(u128)), isqrt(max));
    try std.testing.expectEqual(@as(u128, 3), isqrt(15));
    try std.testing.expectEqual(@as(u128, 4), isqrt(16));
    try std.testing.expectEqual(@as(u128, 0), isqrt(0));
}

test "REQ-CORE-01 decimal parse and format" {
    var buf: [MAX_DECIMAL_LEN + 1]u8 = undefined;
    const max_s = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    try std.testing.expectEqualStrings(max_s, try formatDecimal(std.math.maxInt(u256), &buf));
    try std.testing.expectEqual(std.math.maxInt(u256), try parseDecimal(max_s));
    try std.testing.expectError(MathError.Overflow, parseDecimal("115792089237316195423570985008687907853269984665640564039457584007913129639936"));
    const min_s = "-57896044618658097711785492504343953926634992332820282019728792003956564819968";
    try std.testing.expectEqualStrings(min_s, try formatDecimalSigned(std.math.minInt(i256), &buf));
    try std.testing.expectEqual(@as(i256, std.math.minInt(i256)), try parseDecimalSigned(min_s));
    try std.testing.expectError(MathError.Overflow, parseDecimalSigned("-57896044618658097711785492504343953926634992332820282019728792003956564819969"));
    try std.testing.expectError(MathError.Overflow, parseDecimalSigned("57896044618658097711785492504343953926634992332820282019728792003956564819968"));
    for ([_][]const u8{ "", "-", "+1", "1_000", " 1", "0x10", "12a" }) |bad| {
        try std.testing.expectError(MathError.InvalidCharacter, parseDecimal(bad));
    }
    try std.testing.expectEqualStrings("0", try formatDecimal(0, &buf));
    try std.testing.expectEqualStrings("1000000000", try formatDecimal(1_000_000_000, &buf));
    try std.testing.expectEqualStrings("1000000000000000000", try formatDecimal(1_000_000_000_000_000_000, &buf));
    try std.testing.expectEqualStrings("-7", try formatDecimalSigned(-7, &buf));
    try std.testing.expectError(MathError.BufferTooSmall, formatDecimal(1000, buf[0..3]));
}

test "REQ-CORE-01 byte conversion" {
    const v: u256 = 0x0102030405060708091011121314151617181920212223242526272829303132;
    const be = toBytes(v, .big);
    try std.testing.expectEqual(@as(u8, 0x01), be[0]);
    try std.testing.expectEqual(@as(u8, 0x32), be[31]);
    try std.testing.expectEqual(v, fromBytes(&be, .big));
    const le = toBytes(v, .little);
    try std.testing.expectEqual(@as(u8, 0x32), le[0]);
    try std.testing.expectEqual(v, fromBytes(&le, .little));
}

test "REQ-CORE-01 property: mulDiv, signed division, isqrt, format vs big.int oracle" {
    const Big = std.math.big.int.Managed;
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7765623373716c);
    const rand = prng.random();
    var a = try Big.init(gpa);
    defer a.deinit();
    var b = try Big.init(gpa);
    defer b.deinit();
    var c = try Big.init(gpa);
    defer c.deinit();
    var prod = try Big.init(gpa);
    defer prod.deinit();
    var q = try Big.init(gpa);
    defer q.deinit();
    var r = try Big.init(gpa);
    defer r.deinit();
    var buf: [MAX_DECIMAL_LEN + 1]u8 = undefined;

    for (0..2000) |_| {
        // Vary magnitude so small, overflowing and non-overflowing cases are all hit.
        const x = rand.int(u256) >> rand.int(u8);
        const y = rand.int(u256) >> rand.int(u8);
        const z = (rand.int(u256) >> rand.int(u8)) | 1;
        try a.set(x);
        try b.set(y);
        try c.set(z);
        try prod.mul(&a, &b);
        try q.divFloor(&r, &prod, &c);

        const expected: MathError!u256 = q.toInt(u256) catch MathError.Overflow;
        try std.testing.expectEqual(expected, mulDiv(x, y, z));
        if (expected) |floor| {
            if (r.eqlZero()) {
                try std.testing.expectEqual(@as(MathError!u256, floor), mulDivRoundingUp(x, y, z));
            } else if (floor != std.math.maxInt(u256)) {
                try std.testing.expectEqual(@as(MathError!u256, floor + 1), mulDivRoundingUp(x, y, z));
            } else {
                try std.testing.expectError(MathError.Overflow, mulDivRoundingUp(x, y, z));
            }
        } else |_| {}

        const root = isqrt(x);
        try std.testing.expect(@as(u512, root) * root <= x);
        try std.testing.expect((@as(u512, root) + 1) * (@as(u512, root) + 1) > x);

        const s: i256 = @bitCast(x);
        const t: i256 = @bitCast(z);
        try a.set(s);
        try b.set(t);
        try q.divFloor(&r, &a, &b);
        try std.testing.expectEqual(q.toInt(i256) catch unreachable, try divFloor(s, t));
        try q.divTrunc(&r, &a, &b);
        try std.testing.expectEqual(q.toInt(i256) catch unreachable, try divTrunc(s, t));

        const str = try a.toString(gpa, 10, .lower);
        defer gpa.free(str);
        try std.testing.expectEqualStrings(str, try formatDecimalSigned(s, &buf));
        try std.testing.expectEqual(s, try parseDecimalSigned(str));
    }
}
