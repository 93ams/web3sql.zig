pub const keccak = @import("keccak.zig");
pub const sha256 = @import("sha256.zig");
pub const ripemd160 = @import("ripemd160.zig");
pub const blake2b = @import("blake2b.zig");
pub const blake3 = @import("blake3.zig");
pub const ed25519 = @import("ed25519.zig");

pub const keccak256 = keccak.hash;
pub const sha256d = sha256.doubleHash;
pub const hash160 = ripemd160.hash160;

test {
    _ = @import("keccak.zig");
    _ = @import("sha256.zig");
    _ = @import("ripemd160.zig");
    _ = @import("blake2b.zig");
    _ = @import("blake3.zig");
    _ = @import("ed25519.zig");
}
