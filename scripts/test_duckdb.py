#!/usr/bin/env python3
"""Integration test: every catalogue function runs in DuckDB and matches an independent reference.

REQ-DUCK-01: loading through the C_STRUCT ABI footer below is itself the compliance check.

Setup: uv venv && uv pip install -r scripts/requirements-dev.txt
Usage: python scripts/test_duckdb.py [path/to/web3.duckdb_extension]
"""
import hashlib
import json
import os
import random
import struct
import sys
import time

import base58 as b58ref
import bech32 as bech32ref
import blake3 as blake3ref
import duckdb
from Crypto.Hash import RIPEMD160, keccak
from solders.pubkey import Pubkey

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")

con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")
registered = {r[0] for r in con.execute("select distinct function_name from duckdb_functions() where function_name like 'web3_%'").fetchall()}
exercised = set()


def q(name, *args):
    """Calls one function through bound parameters, so inputs are never constant-folded into SQL text."""
    exercised.add(name)
    marks = ",".join("?" for _ in args)
    return con.execute(f"select {name}({marks})", list(args)).fetchone()[0]


def eq(got, want, label):
    if got != want:
        raise AssertionError(f"{label}: got {got!r}, want {want!r}")


def keccak256(b):
    return keccak.new(digest_bits=256, data=b).digest()


def bech32m_address(hrp, version, program):
    """Taproot address per BIP-350. The PyPI bech32 package predates it and only knows Bech32."""
    data = [version] + bech32ref.convertbits(program, 8, 5)
    values = bech32ref.bech32_hrp_expand(hrp) + data
    mod = bech32ref.bech32_polymod(values + [0] * 6) ^ 0x2bc830a3
    charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    tail = data + [(mod >> 5 * (5 - i)) & 31 for i in range(6)]
    return hrp + "1" + "".join(charset[d] for d in tail)


def check_hashes():
    rng = random.Random(1)
    for n in (0, 1, 31, 32, 33, 135, 136, 137, 1000, 5000):
        b = rng.randbytes(n)
        eq(bytes(q("web3_keccak256", b)), keccak256(b), "keccak256")
        eq(bytes(q("web3_sha256", b)), hashlib.sha256(b).digest(), "sha256")
        eq(bytes(q("web3_sha256d", b)), hashlib.sha256(hashlib.sha256(b).digest()).digest(), "sha256d")
        eq(bytes(q("web3_ripemd160", b)), RIPEMD160.new(b).digest(), "ripemd160")
        eq(bytes(q("web3_hash160", b)), RIPEMD160.new(hashlib.sha256(b).digest()).digest(), "hash160")
        eq(bytes(q("web3_blake2b256", b)), hashlib.blake2b(b, digest_size=32).digest(), "blake2b")
        eq(bytes(q("web3_blake3", b)), blake3ref.blake3(b).digest(), "blake3")


def check_encodings():
    import base64

    rng = random.Random(2)
    for n in (0, 1, 15, 16, 17, 32, 64, 100):
        b = rng.randbytes(n)
        eq(q("web3_hex_encode", b), b.hex(), "hex")
        eq(bytes(q("web3_hex_decode", "0x" + b.hex())), b, "unhex")
        eq(q("web3_base58_encode", b), b58ref.b58encode(b).decode(), "base58")
        eq(bytes(q("web3_base58_decode", b58ref.b58encode(b).decode())), b, "unbase58")
        eq(q("web3_base58check_encode", b), b58ref.b58encode_check(b).decode(), "base58check")
        eq(bytes(q("web3_base58check_decode", b58ref.b58encode_check(b).decode())), b, "unbase58check")
        eq(q("web3_base64_encode", b), base64.b64encode(b).decode(), "b64")
        eq(bytes(q("web3_base64_decode", base64.b64encode(b).decode())), b, "unb64")
        url = base64.urlsafe_b64encode(b).decode().rstrip("=")
        eq(q("web3_base64url_encode", b), url, "b64url")
        eq(bytes(q("web3_base64url_decode", url)), b, "unb64url")
    eq(q("web3_hex_decode", "zz"), None, "bad hex is NULL")
    eq(q("web3_base58check_decode", "abc"), None, "bad checksum is NULL")


def check_math():
    rng = random.Random(3)
    for _ in range(200):
        a, b, c = (rng.getrandbits(rng.randint(1, 256)) for _ in range(3))
        c = c or 1
        want = a * b // c
        eq(q("web3_mul_div", str(a), str(b), str(c)), str(want) if want < 2**256 else None, "mul_div")
        eq(q("web3_u256_from_bytes", a.to_bytes(32, "big")), str(a), "u256")
        eq(bytes(q("web3_u256_to_bytes", str(a))), a.to_bytes(32, "big"), "u256 bytes")
        s = a - 2**255
        eq(q("web3_i256_from_bytes", (s % 2**256).to_bytes(32, "big")), str(s), "i256")


def check_svm():
    rng = random.Random(4)
    for _ in range(40):
        raw = rng.randbytes(32)
        eq(q("web3_sol_is_on_curve", raw), Pubkey(raw).is_on_curve(), "on curve")
    program = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    for _ in range(40):
        seeds = [rng.randbytes(rng.randint(0, 32)) for _ in range(rng.randint(1, 4))]
        addr, bump = Pubkey.find_program_address(seeds, Pubkey.from_string(program))
        text = ",".join(s.hex() for s in seeds)
        eq(q("web3_sol_pda", program, text), str(addr), "pda")
        eq(q("web3_sol_pda_bump", program, text), bump, "bump")
    for fn, prefix in (("instruction", "global"), ("account", "account"), ("event", "event")):
        eq(bytes(q(f"web3_anchor_{fn}_discriminator", "swap")), hashlib.sha256(f"{prefix}:swap".encode()).digest()[:8], "disc")
    data = struct.pack("<QB", 7, 0) + struct.pack("<I", 2) + b"hi"
    eq(json.loads(q("web3_borsh_decode", "{a:u64,b:option<u8>,c:string}", data)), {"a": 7, "b": None, "c": "hi"}, "borsh")
    eq(q("web3_borsh_decode", "{a:u64}", b"\x01"), None, "short borsh is NULL")

    idl = json.dumps({
        "address": program, "metadata": {"name": "t", "version": "0.1.0", "spec": "0.1.0"},
        "instructions": [{"name": "swap", "discriminator": list(hashlib.sha256(b"global:swap").digest()[:8]), "accounts": [], "args": [{"name": "amount", "type": "u64"}]}],
        "accounts": [{"name": "Pool", "discriminator": list(hashlib.sha256(b"account:Pool").digest()[:8])}],
        "events": [{"name": "Swapped", "discriminator": list(hashlib.sha256(b"event:Swapped").digest()[:8])}],
        "types": [{"name": "Pool", "type": {"kind": "struct", "fields": [{"name": "fee", "type": "u16"}]}},
                  {"name": "Swapped", "type": {"kind": "struct", "fields": [{"name": "out", "type": "u32"}]}}],
    })
    ix = hashlib.sha256(b"global:swap").digest()[:8] + struct.pack("<Q", 9)
    eq(json.loads(q("web3_anchor_decode_instruction", idl, ix)), {"name": "swap", "data": {"amount": 9}}, "idl ix")
    acct = hashlib.sha256(b"account:Pool").digest()[:8] + struct.pack("<H", 30)
    eq(json.loads(q("web3_anchor_decode_account", idl, acct)), {"name": "Pool", "data": {"fee": 30}}, "idl account")
    ev = hashlib.sha256(b"event:Swapped").digest()[:8] + struct.pack("<I", 4)
    eq(json.loads(q("web3_anchor_decode_event", idl, ev)), {"name": "Swapped", "data": {"out": 4}}, "idl event")
    import base64
    line = "Program data: " + base64.b64encode(ev).decode()
    eq(json.loads(q("web3_anchor_decode_event_log", idl, line)), {"name": "Swapped", "data": {"out": 4}}, "idl log")


def check_move():
    eq(q("web3_move_address", "0x1"), "0x" + "0" * 63 + "1", "move address")
    eq(q("web3_move_address_short", "0x" + "0" * 63 + "1"), "0x1", "aptos short")
    eq(q("web3_move_type_tag", "vector<0x1::coin::Coin<0x2::sui::SUI>>"),
       f"vector<0x{'0'*63}1::coin::Coin<0x{'0'*63}2::sui::SUI>>", "type tag")
    data = struct.pack("<Q", 5) + b"\x02\x01\x02" + b"\x01\x07"
    eq(json.loads(q("web3_bcs_decode", "{a:u64,b:vector<u8>,c:option<u8>}", data)), {"a": 5, "b": "0x0102", "c": 7}, "bcs")
    eq(q("web3_bcs_decode", "u8", b"\x01\x02"), None, "trailing bcs is NULL")


def check_utxo():
    h = bytes(range(20))
    w32 = bytes(range(32))
    cases = [
        (b"\x76\xa9\x14" + h + b"\x88\xac", "p2pkh", b58ref.b58encode_check(b"\x00" + h).decode()),
        (b"\xa9\x14" + h + b"\x87", "p2sh", b58ref.b58encode_check(b"\x05" + h).decode()),
        (b"\x00\x14" + h, "p2wpkh", bech32ref.encode("bc", 0, h)),
        (b"\x00\x20" + w32, "p2wsh", bech32ref.encode("bc", 0, w32)),
        (b"\x51\x20" + w32, "p2tr", bech32m_address("bc", 1, w32)),
    ]
    for spk, kind, addr in cases:
        eq(q("web3_btc_script_type", spk), kind, "script type")
        eq(q("web3_btc_address", "bitcoin", spk), addr, "address")
        eq(json.loads(q("web3_btc_script_json", "bitcoin", spk))["address"], addr, "script json")
    # BIP-350 test vector, pinned so the helper above is itself checked.
    bip350 = bytes.fromhex("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    eq(bech32m_address("bc", 1, bip350), "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", "bech32m helper")
    eq(q("web3_btc_address", "bitcoin", b"\x51\x20" + bip350), "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", "BIP-350")
    eq(q("web3_btc_address", "nosuchnet", cases[0][0]), None, "unknown network is NULL")
    eq(bytes(q("web3_btc_op_return", b"\x6a\x03abc")), b"abc", "op_return")
    runes = json.loads(q("web3_btc_runestone_json", b"\x6a\x5d\x02\x02\x05"))
    assert runes, "runestone json"
    ins = json.loads(q("web3_btc_inscription_json", b"\x00\x63\x03ord\x51\x0atext/plain\x00\x02hi\x68"))
    eq(ins["content_type"], "text/plain", "inscription")


def check_cosmos():
    raw = hashlib.sha256(b"web3sql").digest()[:20]
    five = bech32ref.convertbits(raw, 8, 5)
    atom = bech32ref.bech32_encode("cosmos", five)
    osmo = bech32ref.bech32_encode("osmo", five)
    eq(q("web3_cosmos_convert_hrp", atom, "osmo"), osmo, "hrp")
    eq(q("web3_cosmos_is_valid", atom), True, "valid")
    eq(q("web3_cosmos_is_valid", atom[:-1] + "q"), False, "invalid")
    eq(q("web3_ibc_denom", "transfer/channel-0/uatom"),
       "ibc/" + hashlib.sha256(b"transfer/channel-0/uatom").hexdigest().upper(), "ibc")
    eq(q("web3_ibc_base_denom", "transfer/channel-0/uatom"), "uatom", "base denom")


def check_vector_semantics():
    """REQ-DUCK-02: flat, constant, dictionary, filtered and NULL-bearing vectors over many chunks."""
    rows = con.execute("""
        select i, web3_hex_encode(web3_keccak256(x)) from
        (select i, case when i % 7 = 0 then null else ('row' || (i % 11))::blob end x from range(10000) t(i))
        where i % 3 = 0 order by i""").fetchall()
    eq(len(rows), 3334, "row count")
    for i, got in rows:
        want = None if i % 7 == 0 else keccak256(f"row{i % 11}".encode()).hex()
        eq(got, want, f"row {i}")
    eq(con.execute("select count(*) from (select web3_keccak256('x'::blob) from range(5000))").fetchone()[0], 5000, "constant")
    # long strings force the out-of-line duckdb_string_t path
    long_value = "z" * 100
    eq(con.execute("select web3_hex_encode(web3_sha256(?::blob)) from range(3)", [long_value]).fetchall(),
       [(hashlib.sha256(long_value.encode()).hexdigest(),)] * 3, "long strings")


def check_schema_binding():
    """REQ-DUCK-03: constant schemas parse once at bind, varying ones still work per row."""
    blob = struct.pack("<Q", 1)
    eq(con.execute("select web3_borsh_decode(s, ?) from (values ('{a:u64}'), ('{b:u64}'), (null)) t(s)", [blob]).fetchall(),
       [('{"a":1}',), ('{"b":1}',), (None,)], "non-constant schema")
    eq(con.execute("select web3_borsh_decode(s, ?) from (values ('nope')) t(s)", [blob]).fetchall(), [(None,)], "bad per-row schema is NULL")
    try:
        con.execute("select web3_borsh_decode('nope', ?)", [blob]).fetchall()
    except duckdb.Error as e:
        assert "invalid schema" in str(e), e
    else:
        raise AssertionError("constant bad schema must fail at bind")
    # Distinct rows, or DuckDB folds the call into one evaluation and the timing means nothing.
    n = 1_000_000
    rows = f"(select printf('%08d', i)::blob b, '{{a:u64}}' s from range({n}) t(i))"
    t0 = time.perf_counter()
    eq(con.execute(f"select count(distinct web3_borsh_decode('{{a:u64}}', b)) from {rows}").fetchone()[0], n, "bound schema")
    const_t = time.perf_counter() - t0
    t0 = time.perf_counter()
    eq(con.execute(f"select count(distinct web3_borsh_decode(s, b)) from {rows}").fetchone()[0], n, "column schema")
    column_t = time.perf_counter() - t0
    print(f"    {n / const_t / 1e6:.2f} M rows/s bound schema, {n / column_t / 1e6:.2f} M rows/s per-chunk schema")


def check_garbage():
    """REQ-DUCK-04: random bytes through every one-blob function complete the scan and never abort."""
    fns = con.execute("""select distinct function_name from duckdb_functions()
                         where function_name like 'web3_%' and parameter_types = ['BLOB']""").fetchall()
    for (fn,) in fns:
        con.execute(f"select count({fn}(b)) from (select cast(unhex(md5(i::varchar) || md5((i*7)::varchar)) as blob) b from range(20000) t(i))").fetchall()


def check_parquet():
    """Real samples, compared to the reference libraries row by row."""
    btc = os.path.join(REPO, "test_data", "bitcoin_txs.parquet").replace("\\", "/")
    rows = con.execute(f"""select vout_script_pub_key, web3_btc_script_type(web3_hex_decode(vout_script_pub_key)),
                                  web3_btc_address('bitcoin', web3_hex_decode(vout_script_pub_key))
                           from '{btc}'""").fetchall()
    exercised.add("web3_btc_address")
    assert rows
    for spk_hex, kind, addr in rows:
        spk = bytes.fromhex(spk_hex.removeprefix("0x"))
        if kind == "p2wpkh":
            eq(addr, bech32ref.encode("bc", 0, spk[2:]), "real p2wpkh")
        elif kind == "p2tr":
            eq(addr, bech32m_address("bc", 1, spk[2:]), "real p2tr")
        elif kind == "p2pkh":
            eq(addr, b58ref.b58encode_check(b"\x00" + spk[3:23]).decode(), "real p2pkh")
    svm = os.path.join(REPO, "test_data", "svm_instructions.parquet").replace("\\", "/")
    for text, got in con.execute(f"select instruction_data, web3_base58_decode(instruction_data) from '{svm}'").fetchall():
        eq(bytes(got), b58ref.b58decode(text), "real base58")


CHECKS = [check_hashes, check_encodings, check_math, check_svm, check_move, check_utxo, check_cosmos,
          check_vector_semantics, check_schema_binding, check_garbage, check_parquet]


def main():
    print(f"DuckDB {duckdb.__version__}, {len(registered)} functions from {EXT}")
    for check in CHECKS:
        section = check.__name__.removeprefix("check_")
        needs = {"svm": "web3_sol_pda", "move": "web3_bcs_decode", "utxo": "web3_btc_address", "cosmos": "web3_ibc_denom"}.get(section)
        if needs and needs not in registered:
            print(f"  skipped {section}: not in this build")
            continue
        check()
        print(f"  ok {section}")
    missing = registered - exercised
    if missing:
        sys.exit(f"catalogue functions with no reference check: {sorted(missing)}")
    print("SUCCESS")


if __name__ == "__main__":
    main()
