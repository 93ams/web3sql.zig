//! Address parameters for the supported Bitcoin-family networks.
//! Source: bitcoin/bitcoin src/kernel/chainparams.cpp and litecoin-project/litecoin src/chainparams.cpp
//! (base58Prefixes PUBKEY_ADDRESS / SCRIPT_ADDRESS, bech32_hrp), fetched.
const std = @import("std");

pub const Network = struct {
    name: []const u8,
    p2pkh_version: u8,
    p2sh_version: u8,
    segwit_hrp: []const u8,
};

pub const bitcoin_mainnet = Network{ .name = "bitcoin", .p2pkh_version = 0, .p2sh_version = 5, .segwit_hrp = "bc" };
pub const bitcoin_testnet = Network{ .name = "bitcoin-testnet", .p2pkh_version = 111, .p2sh_version = 196, .segwit_hrp = "tb" };
pub const bitcoin_regtest = Network{ .name = "bitcoin-regtest", .p2pkh_version = 111, .p2sh_version = 196, .segwit_hrp = "bcrt" };
// Litecoin Core encodes P2SH with SCRIPT_ADDRESS2 (50, "M..."); version 5 is accepted on decode only.
pub const litecoin_mainnet = Network{ .name = "litecoin", .p2pkh_version = 48, .p2sh_version = 50, .segwit_hrp = "ltc" };

pub const all = [_]Network{ bitcoin_mainnet, bitcoin_testnet, bitcoin_regtest, litecoin_mainnet };

/// Looks a network up by its `name`; null when unknown.
pub fn byName(name: []const u8) ?Network {
    for (all) |n| if (std.mem.eql(u8, n.name, name)) return n;
    return null;
}
