const std = @import("std");

pub const ScriptType = enum {
    p2pkh,
    p2sh,
    p2wpkh,
    p2wsh,
    p2tr,
    op_return,
    unknown,
};

/// Classifies Bitcoin/UTXO scriptPubKey.
pub fn classifyScript(script: []const u8) ScriptType {
    if (script.len == 0) return .unknown;

    // OP_RETURN
    if (script[0] == 0x6a) return .op_return;

    // P2PKH: OP_DUP(0x76) OP_HASH160(0xa9) 0x14 <20 bytes> OP_EQUALVERIFY(0x88) OP_CHECKSIG(0xac)
    if (script.len == 25 and
        script[0] == 0x76 and
        script[1] == 0xa9 and
        script[2] == 0x14 and
        script[23] == 0x88 and
        script[24] == 0xac)
    {
        return .p2pkh;
    }

    // P2SH: OP_HASH160(0xa9) 0x14 <20 bytes> OP_EQUAL(0x87)
    if (script.len == 23 and
        script[0] == 0xa9 and
        script[1] == 0x14 and
        script[22] == 0x87)
    {
        return .p2sh;
    }

    // P2WPKH: OP_0(0x00) 0x14 <20 bytes>
    if (script.len == 22 and script[0] == 0x00 and script[1] == 0x14) {
        return .p2wpkh;
    }

    // P2WSH: OP_0(0x00) 0x20 <32 bytes>
    if (script.len == 34 and script[0] == 0x00 and script[1] == 0x20) {
        return .p2wsh;
    }

    // P2TR: OP_1(0x51) 0x20 <32 bytes>
    if (script.len == 34 and script[0] == 0x51 and script[1] == 0x20) {
        return .p2tr;
    }

    return .unknown;
}

test "classify scriptPubKey" {
    // P2PKH script
    var p2pkh_script: [25]u8 = undefined;
    p2pkh_script[0] = 0x76;
    p2pkh_script[1] = 0xa9;
    p2pkh_script[2] = 0x14;
    @memset(p2pkh_script[3..23], 0x11);
    p2pkh_script[23] = 0x88;
    p2pkh_script[24] = 0xac;

    try std.testing.expectEqual(ScriptType.p2pkh, classifyScript(&p2pkh_script));
}
