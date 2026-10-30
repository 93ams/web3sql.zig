pub const @"u256" = @import("u256.zig");
pub const @"u512" = @import("u512.zig");

pub const U256 = @"u256".U256;
pub const I256 = @"u256".I256;
pub const U128 = @"u256".U128;
pub const I128 = @"u256".I128;
pub const U512 = @"u512".U512;
pub const mulDiv = @"u256".mulDiv;
pub const mulDivRoundingUp = @"u256".mulDivRoundingUp;
pub const divTrunc = @"u256".divTrunc;
pub const divFloor = @"u256".divFloor;
pub const isqrt = @"u256".isqrt;
pub const toBytes = @"u256".toBytes;
pub const fromBytes = @"u256".fromBytes;
pub const parseDecimal = @"u256".parseDecimal;
pub const parseDecimalSigned = @"u256".parseDecimalSigned;
pub const formatDecimal = @"u256".formatDecimal;
pub const formatDecimalSigned = @"u256".formatDecimalSigned;
pub const MAX_DECIMAL_LEN = @"u256".MAX_DECIMAL_LEN;
pub const checkedAdd = @"u256".checkedAdd;
pub const checkedSub = @"u256".checkedSub;
pub const checkedMul = @"u256".checkedMul;
pub const MathError = @"u256".MathError;

test {
    _ = @import("u256.zig");
    _ = @import("u512.zig");
}
