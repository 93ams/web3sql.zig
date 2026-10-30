const std = @import("std");

/// DuckDB C-API vectorized extension type definitions and stubs.
pub const DuckDbState = enum(c_int) {
    DuckDBSuccess = 0,
    DuckDBError = 1,
};

pub const DuckDbVector = opaque {};
pub const DuckDbValidity = opaque {};
pub const DuckDbDatabase = opaque {};
pub const DuckDbConnection = opaque {};

pub const VECTOR_STANDARD_VECTOR_SIZE: usize = 2048;

pub const ExtensionInfo = struct {
    name: []const u8 = "web3",
    version: []const u8 = "0.1.0",
};

test "duckdb extension info" {
    const info = ExtensionInfo{};
    try std.testing.expectEqualStrings("web3", info.name);
}
