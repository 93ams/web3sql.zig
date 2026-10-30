pub const @"u256" = @import("u256.zig");
pub const @"u512" = @import("u512.zig");

pub const U256 = @"u256".U256;
pub const I256 = @"u256".I256;
pub const U128 = @"u256".U128;
pub const I128 = @"u256".I128;
pub const U512 = @"u512".U512;
pub const mulDiv = @"u256".mulDiv;
pub const checkedAdd = @"u256".checkedAdd;
pub const checkedSub = @"u256".checkedSub;
pub const checkedMul = @"u256".checkedMul;
pub const MathError = @"u256".MathError;

test {
    _ = @import("u256.zig");
    _ = @import("u512.zig");
}
