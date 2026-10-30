//! SPL Token instruction data: u8 discriminant, u64 LE amount, optional u8 decimals.
//! Token-2022 shares these discriminants. Trailing bytes are ignored, as the program's unpack does.
const std = @import("std");
const fuzz = @import("../../core/fuzz.zig");
const json = @import("json.zig");

pub const Kind = enum(u8) {
    transfer = 3,
    approve = 4,
    transfer_checked = 12,
    approve_checked = 13,
};

pub const Instruction = struct {
    kind: Kind,
    amount: u64,
    decimals: ?u8,
};

pub const SplError = error{
    UnknownInstruction,
    TruncatedInstruction,
    BufferTooSmall,
};

/// Decodes Transfer, Approve, TransferChecked and ApproveChecked instruction data.
pub fn decode(data: []const u8) SplError!Instruction {
    if (data.len == 0) return SplError.TruncatedInstruction;
    const kind = std.enums.fromInt(Kind, data[0]) orelse return SplError.UnknownInstruction;
    if (data.len < 9) return SplError.TruncatedInstruction;
    const amount = std.mem.readInt(u64, data[1..9], .little);
    if (kind == .transfer or kind == .approve) return .{ .kind = kind, .amount = amount, .decimals = null };
    if (data.len < 10) return SplError.TruncatedInstruction;
    return .{ .kind = kind, .amount = amount, .decimals = data[9] };
}

/// Decoded instruction as compact JSON. Pubkeys live in the account list, not in instruction data.
pub fn renderJson(data: []const u8, dest: []u8) SplError![]const u8 {
    const ins = try decode(data);
    var out: json.Out = .{ .dest = dest };
    try out.raw("{\"type\":\"");
    try out.raw(@tagName(ins.kind));
    try out.raw("\",\"amount\":");
    try out.int(ins.amount);
    if (ins.decimals) |decimals| {
        try out.raw(",\"decimals\":");
        try out.int(decimals);
    }
    try out.raw("}");
    return out.written();
}

// solana-program/token interface/src/instruction.rs test_instruction_packing.
const TRANSFER = [_]u8{ 3, 1, 0, 0, 0, 0, 0, 0, 0 };
const APPROVE = [_]u8{ 4, 1, 0, 0, 0, 0, 0, 0, 0 };
const TRANSFER_CHECKED = [_]u8{ 12, 1, 0, 0, 0, 0, 0, 0, 0, 2 };
const APPROVE_CHECKED = [_]u8{ 13, 1, 0, 0, 0, 0, 0, 0, 0, 2 };

test "REQ-PROT-02 SPL instructions match test_instruction_packing" {
    try std.testing.expectEqual(Instruction{ .kind = .transfer, .amount = 1, .decimals = null }, try decode(&TRANSFER));
    try std.testing.expectEqual(Instruction{ .kind = .approve, .amount = 1, .decimals = null }, try decode(&APPROVE));
    try std.testing.expectEqual(Instruction{ .kind = .transfer_checked, .amount = 1, .decimals = 2 }, try decode(&TRANSFER_CHECKED));
    try std.testing.expectEqual(Instruction{ .kind = .approve_checked, .amount = 1, .decimals = 2 }, try decode(&APPROVE_CHECKED));
}

test "REQ-PROT-02 SPL rejects what unpack rejects" {
    try std.testing.expectError(SplError.TruncatedInstruction, decode(""));
    try std.testing.expectError(SplError.TruncatedInstruction, decode(TRANSFER[0..8]));
    try std.testing.expectError(SplError.TruncatedInstruction, decode(TRANSFER_CHECKED[0..9]));
    try std.testing.expectError(SplError.UnknownInstruction, decode(&[_]u8{ 5, 0, 0, 0, 0, 0, 0, 0, 0 }));
    const trailing = TRANSFER ++ [_]u8{0xff};
    try std.testing.expectEqual(@as(u64, 1), (try decode(&trailing)).amount);
}

test "REQ-PROT-02 SPL renderJson" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("{\"type\":\"transfer\",\"amount\":1}", try renderJson(&TRANSFER, &buf));
    try std.testing.expectEqualStrings("{\"type\":\"approve_checked\",\"amount\":1,\"decimals\":2}", try renderJson(&APPROVE_CHECKED, &buf));
    var max: [9]u8 = @splat(0xff);
    max[0] = 3;
    try std.testing.expectEqualStrings("{\"type\":\"transfer\",\"amount\":\"18446744073709551615\"}", try renderJson(&max, &buf));
    try std.testing.expectError(SplError.BufferTooSmall, renderJson(&TRANSFER, buf[0..10]));
}

fn exercise(_: void, bytes: []const u8) void {
    _ = decode(bytes) catch {};
    var dest: [96]u8 = undefined;
    _ = renderJson(bytes, &dest) catch {};
    _ = renderJson(bytes, dest[0 .. bytes.len % 64]) catch {};
}

test "REQ-PROT-02 SPL fuzz" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) !void {
            var buf: [32]u8 = undefined;
            exercise({}, buf[0..smith.slice(&buf)]);
        }
    }.f, .{});
}

test "REQ-PROT-02 SPL stress" {
    fuzz.stress(200_000, &.{ &TRANSFER, &APPROVE, &TRANSFER_CHECKED, &APPROVE_CHECKED }, {}, exercise);
}
