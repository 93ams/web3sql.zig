const std = @import("std");

pub const SplTransfer = struct {
    amount: u64,
};

pub const SplError = error{
    InvalidInstruction,
    BufferTooSmall,
};

/// Fast-path decoder for SPL Token Transfer instruction (Instruction tag 3 followed by u64 amount little endian).
pub fn decodeSplTransfer(data: []const u8) SplError!SplTransfer {
    if (data.len < 9) return SplError.BufferTooSmall;
    if (data[0] != 3) return SplError.InvalidInstruction; // SPL Transfer opcode

    const amount = std.mem.readInt(u64, data[1..9], .little);
    return .{ .amount = amount };
}

test "spl transfer decode" {
    var payload: [9]u8 = undefined;
    payload[0] = 3; // Transfer opcode
    std.mem.writeInt(u64, payload[1..9], 5_000_000, .little);

    const res = try decodeSplTransfer(&payload);
    try std.testing.expectEqual(@as(u64, 5_000_000), res.amount);
}
