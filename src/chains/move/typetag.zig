const std = @import("std");
const MoveAddress = @import("address.zig").MoveAddress;

pub const TypeTagKind = enum {
    bool_type,
    u8_type,
    u16_type,
    u32_type,
    u64_type,
    u128_type,
    u256_type,
    address_type,
    signer_type,
    vector_type,
    struct_type,
};

pub const StructTag = struct {
    address: MoveAddress,
    module_name: []const u8,
    struct_name: []const u8,
};

test "type tag kind enum check" {
    const kind = TypeTagKind.u64_type;
    try std.testing.expect(kind == .u64_type);
}
