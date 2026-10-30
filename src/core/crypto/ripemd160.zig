const std = @import("std");

pub const DIGEST_LENGTH: usize = 20;
pub const BLOCK_LENGTH: usize = 64;

pub const Ripemd160 = struct {
    state: [5]u32,
    count: u64,
    buf: [BLOCK_LENGTH]u8,
    buf_len: usize,

    pub const digest_length = DIGEST_LENGTH;
    pub const block_length = BLOCK_LENGTH;

    pub fn init() Ripemd160 {
        return .{
            .state = [_]u32{
                0x67452301,
                0xefcdab89,
                0x98badcfe,
                0x10325476,
                0xc3d2e1f0,
            },
            .count = 0,
            .buf = undefined,
            .buf_len = 0,
        };
    }

    pub fn update(self: *Ripemd160, data: []const u8) void {
        var in = data;
        self.count +%= in.len;

        if (self.buf_len > 0) {
            const need = BLOCK_LENGTH - self.buf_len;
            if (in.len < need) {
                @memcpy(self.buf[self.buf_len..][0..in.len], in);
                self.buf_len += in.len;
                return;
            }
            @memcpy(self.buf[self.buf_len..][0..need], in[0..need]);
            self.compress(&self.buf);
            self.buf_len = 0;
            in = in[need..];
        }

        while (in.len >= BLOCK_LENGTH) {
            self.compress(in[0..BLOCK_LENGTH]);
            in = in[BLOCK_LENGTH..];
        }

        if (in.len > 0) {
            @memcpy(self.buf[0..in.len], in);
            self.buf_len = in.len;
        }
    }

    pub fn final(self: *Ripemd160, out: *[DIGEST_LENGTH]u8) void {
        var pad: [BLOCK_LENGTH * 2]u8 = undefined;
        @memset(&pad, 0);
        pad[0] = 0x80;

        const bit_len = self.count *% 8;
        std.mem.writeInt(u64, pad[pad.len - 8 ..][0..8], bit_len, .little);

        const pad_len = if (self.buf_len < 56) 56 - self.buf_len else 120 - self.buf_len;
        self.update(pad[0..pad_len]);
        self.update(pad[pad.len - 8 ..]);

        for (0..5) |i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], self.state[i], .little);
        }
    }

    pub fn hash(data: []const u8, out: *[DIGEST_LENGTH]u8, options: struct {}) void {
        _ = options;
        var h = init();
        h.update(data);
        h.final(out);
    }

    fn compress(self: *Ripemd160, block: *const [BLOCK_LENGTH]u8) void {
        var x: [16]u32 = undefined;
        for (0..16) |i| {
            x[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
        }

        var al = self.state[0];
        var bl = self.state[1];
        var cl = self.state[2];
        var dl = self.state[3];
        var el = self.state[4];

        var ar = self.state[0];
        var br = self.state[1];
        var cr = self.state[2];
        var dr = self.state[3];
        var er = self.state[4];

        const rl = [_]u4{
            0, 1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
            7, 4,  13, 1,  10, 6,  15, 3,  12, 0, 9,  5,  2,  14, 11, 8,
            3, 10, 14, 4,  9,  15, 8,  1,  2,  7, 0,  6,  13, 11, 5,  12,
            1, 9,  11, 10, 0,  8,  12, 4,  13, 3, 7,  15, 14, 5,  6,  2,
            4, 0,  5,  9,  7,  12, 2,  10, 14, 1, 3,  8,  11, 6,  15, 13,
        };

        const rr = [_]u4{
            5,  14, 7,  0, 9, 2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12,
            6,  11, 3,  7, 0, 13, 5,  10, 14, 15, 8,  12, 4,  9,  1,  2,
            15, 5,  1,  3, 7, 14, 6,  9,  11, 8,  12, 2,  10, 0,  4,  13,
            8,  6,  4,  1, 3, 11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14,
            12, 15, 10, 4, 1, 5,  8,  7,  6,  2,  13, 14, 0,  3,  9,  11,
        };

        const sl = [_]u5{
            11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,
            7,  6,  8,  13, 11, 9,  7,  15, 7,  12, 15, 9,  11, 7,  13, 12,
            11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,  5,  12, 7,  5,
            11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12,
            9,  15, 5,  11, 6,  8,  13, 12, 5,  12, 13, 14, 11, 8,  5,  6,
        };

        const sr = [_]u5{
            8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,
            9,  13, 15, 7,  12, 8,  9,  11, 7,  7,  12, 7,  6,  15, 13, 11,
            9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14, 13, 13, 7,  5,
            15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8,
            8,  5,  12, 9,  12, 5,  14, 6,  8,  13, 6,  5,  15, 13, 11, 11,
        };

        inline for (0..80) |j| {
            // Left round
            var tl = al +% x[rl[j]];
            if (j < 16) {
                tl +%= (bl ^ cl ^ dl);
            } else if (j < 32) {
                tl +%= ((bl & cl) | (~bl & dl)) +% 0x5a827999;
            } else if (j < 48) {
                tl +%= ((bl | ~cl) ^ dl) +% 0x6ed9eba1;
            } else if (j < 64) {
                tl +%= ((bl & dl) | (cl & ~dl)) +% 0x8f1bbcdc;
            } else {
                tl +%= (bl ^ (cl | ~dl)) +% 0xa953fd4e;
            }
            tl = std.math.rotl(u32, tl, sl[j]) +% el;
            al = el;
            el = dl;
            dl = std.math.rotl(u32, cl, 10);
            cl = bl;
            bl = tl;

            // Right round
            var tr = ar +% x[rr[j]];
            if (j < 16) {
                tr +%= (br ^ (cr | ~dr)) +% 0x50a28be6;
            } else if (j < 32) {
                tr +%= ((br & dr) | (cr & ~dr)) +% 0x5c4dd124;
            } else if (j < 48) {
                tr +%= ((br | ~cr) ^ dr) +% 0x6d703ef3;
            } else if (j < 64) {
                tr +%= ((br & cr) | (~br & dr)) +% 0x7a6d76e9;
            } else {
                tr +%= (br ^ cr ^ dr);
            }
            tr = std.math.rotl(u32, tr, sr[j]) +% er;
            ar = er;
            er = dr;
            dr = std.math.rotl(u32, cr, 10);
            cr = br;
            br = tr;
        }

        const t = self.state[1] +% cl +% dr;
        self.state[1] = self.state[2] +% dl +% er;
        self.state[2] = self.state[3] +% el +% ar;
        self.state[3] = self.state[4] +% al +% br;
        self.state[4] = self.state[0] +% bl +% cr;
        self.state[0] = t;
    }
};

/// Computes RIPEMD160 hash.
pub fn hash(data: []const u8, out: *[DIGEST_LENGTH]u8) void {
    Ripemd160.hash(data, out, .{});
}

/// Computes Bitcoin HASH160: RIPEMD160(SHA256(data)).
pub fn hash160(data: []const u8, out: *[DIGEST_LENGTH]u8) void {
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &sha_out, .{});
    Ripemd160.hash(&sha_out, out, .{});
}

test "ripemd160 standard test vectors" {
    var out: [DIGEST_LENGTH]u8 = undefined;
    // ripemd160("") = 9c1185a5c5e9fc54612808977ee8f548b2258d31
    hash("", &out);
    const expected_empty = "\x9c\x11\x85\xa5\xc5\xe9\xfc\x54\x61\x28\x08\x97\x7e\xe8\xf5\x48\xb2\x25\x8d\x31";
    try std.testing.expectEqualStrings(expected_empty, &out);

    // ripemd160("abc") = 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
    hash("abc", &out);
    const expected_abc = "\x8e\xb2\x08\xf7\xe0\x5d\x98\x7a\x9b\x04\x4a\x8e\x98\xc6\xb0\x87\xf1\x5a\x0b\xfc";
    try std.testing.expectEqualStrings(expected_abc, &out);
}

test "REQ-CORE-03 ripemd160 official vectors" {
    // homes.esat.kuleuven.be/~bosselae/ripemd160.html, "Test vectors" table.
    const cases = [_][2][]const u8{
        .{ "", "9c1185a5c5e9fc54612808977ee8f548b2258d31" },
        .{ "a", "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe" },
        .{ "abc", "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc" },
        .{ "message digest", "5d0689ef49d2fae572b881b123a85ffa21595f36" },
        .{ "abcdefghijklmnopqrstuvwxyz", "f71c27109c692c1b56bbdceb5b9d2865b3708dbc" },
        .{ "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "12a053384a9c0c88e405a06c27dcf49ada62eb2b" },
        .{ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "b0e20b6e3116640286ed3a87a5713079b21f5189" },
        .{ "12345678901234567890123456789012345678901234567890123456789012345678901234567890", "9b752e45573d4b39f4dbd3323cab82bf63326bfb" },
    };
    var out: [DIGEST_LENGTH]u8 = undefined;
    var expected: [DIGEST_LENGTH]u8 = undefined;
    for (cases) |c| {
        hash(c[0], &out);
        _ = try std.fmt.hexToBytes(&expected, c[1]);
        try std.testing.expectEqualSlices(u8, &expected, &out);
    }
}
