#!/usr/bin/env python3
"""Replays the pinned mainnet sample in tools/reference/live/ against answers we did not compute.

Where the answer comes from: eth_abi and eth_utils for EVM decoding, the contracts' own view functions
for Aave, Compound and Uniswap, each chain's own node for parsed SPL instructions, addresses, script
types, IBC hashes, BCS resources and Move objects, solders for PDAs, and ord_port.py for envelopes.
Items with no independent answer report a decode rate, and every NULL reason is printed.

Set LIVE_DIR to replay a bulk capture instead. Usage: live_diff.py [extension]. Exits non-zero on any mismatch.
"""
import base64
import glob
import gzip
import json
import os
import sys
from collections import Counter

import base58
import duckdb
from eth_abi import decode as abi_decode
from eth_utils import to_checksum_address
from solders.pubkey import Pubkey

from ord_port import ord_inscription, ord_runestone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
IDLS = os.environ.get("REFERENCE", os.path.expanduser("~/.cache/web3sql-zig/reference")) + "/idls"
con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")

mismatches = 0
notes = []


def q(fn, *args):
    # A subquery keeps every argument a row value, so bind-time constant folding cannot hide a path.
    cols = ", ".join(f"a{i}" for i in range(len(args)))
    sel = ", ".join(f"? a{i}" for i in range(len(args)))
    return con.execute(f"select web3_{fn}({cols}) from (select {sel})", list(args)).fetchone()[0]


def why(fn, *args):
    return q(fn + "_error", *args)


class Tally:
    def __init__(self, name):
        self.name, self.c, self.bad = name, Counter(), []

    def eq(self, got, want, context=""):
        ok = got == want
        self.c["agree" if ok else "MISMATCH"] += 1
        if not ok and len(self.bad) < 5:
            self.bad.append((context, got, want))
        return ok

    def note(self, key):
        self.c[key] += 1

    def done(self):
        global mismatches
        mismatches += self.c["MISMATCH"]
        print(f"{self.name}: " + ", ".join(f"{v} {k}" for k, v in self.c.most_common()))
        for b in self.bad:
            print("   ", *[str(x)[:300] for x in b], sep="\n      ")


LIVE = os.environ.get("LIVE_DIR", os.path.join(HERE, "live"))


def load(name):
    path = os.path.join(LIVE, f"{name}.json.gz")
    if not os.path.exists(path):
        return {}
    with gzip.open(path) as f:
        return json.load(f)


def by(x):
    return bytes.fromhex(x[2:] if x.startswith("0x") else x)


def split_params(text):
    out, cur, d = [], "", 0
    for c in text:
        d += c == "("
        d -= c == ")"
        if c == "," and d == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += c
    if cur.strip():
        out.append(cur.strip())
    return out


def parse_params(sig):
    """-> [(abi type, name, indexed, subparams)]"""
    out = []
    for p in split_params(sig[sig.index("(") + 1 : sig.rindex(")")]):
        if p.startswith("("):
            end = p.rindex(")")
            sub = parse_params(p[: end + 1])
            words = p[end + 1 :].split()
            array = words.pop(0) if words and words[0].startswith("[") else ""
            out.append(("(" + ",".join(s[0] for s in sub) + ")" + array, words[-1] if words else "", False, sub))
        else:
            w = p.split()
            out.append((w[0], w[-1] if len(w) > 1 else "", "indexed" in w, None))
    return out


def render(t, sub, v):
    if t.endswith("[]"):
        return [render(t[:-2], sub, x) for x in v]
    if sub:
        return {(s[1] or str(i)): render(s[0], s[3], x) for i, (s, x) in enumerate(zip(sub, v))}
    if t == "address":
        return v.lower()
    if t.startswith("bytes"):
        return "0x" + v.hex()
    if t.startswith(("uint", "int")):
        return v if abs(v) <= 2**53 else str(v)
    return v


def normal(v):
    """Integers may come back as numbers or strings depending on size."""
    if isinstance(v, dict):
        return {k: normal(x) for k, x in v.items()}
    if isinstance(v, list):
        return [normal(x) for x in v]
    return str(v)


def word(data, i):
    return int.from_bytes(by(data)[32 * i : 32 * i + 32], "big")


def signed(v, bits):
    return v - (1 << bits) if v >> (bits - 1) else v


def evm_rows():
    docs = [load(os.path.basename(p)[: -len(".json.gz")]) for p in sorted(glob.glob(os.path.join(LIVE, "evm*.json.gz")))]
    return [log for d in docs for log in d["logs"]], [c for d in docs for c in d["calls"]]


def evm():
    d = load("evm")
    all_logs, all_calls = evm_rows()
    t = Tally("evm logs vs eth_abi")
    ticks = Tally("uniswap Swap tick vs sqrtPriceX96")
    erc = Tally("web3_erc_decode vs eth_abi")
    addr = Tally("checksum vs eth_utils")
    for log in all_logs:
        params = parse_params(log["sig"])
        topics, data = [by(x) for x in log["topics"]], by(log["data"])
        indexed = [p for p in params if p[2]]
        plain = [p for p in params if not p[2]]
        joined = b"".join(topics)
        got = q("evm_decode_log", log["sig"], joined, data)
        try:
            if len(topics) != 1 + len(indexed):
                raise ValueError("topic count")
            vals = {p[1]: render(p[0], None, abi_decode([p[0]], tv)[0]) for p, tv in zip(indexed, topics[1:])}
            vals.update({p[1]: render(p[0], p[3], v) for p, v in zip(plain, abi_decode([p[0] for p in plain], data))})
        except Exception:
            t.eq(got, None, f"eth_abi rejects {log}")
            t.note(f"NULL: {why('evm_decode_log', log['sig'], joined, data)}")
            continue
        if got is None:
            t.eq(why("evm_decode_log", log["sig"], joined, data), "eth_abi decoded this", log)
            continue
        if not t.eq(normal(json.loads(got)) if got else None, normal(vals), log["sig"]):
            continue
        if "int24 tick" in log["sig"]:
            sqrt, tick = vals["sqrtPriceX96"], vals["tick"]
            mine = q("uni_tick_at_sqrt_ratio", str(sqrt))
            # A swap ending exactly on an initialized tick while moving down reports tick - 1.
            if mine == tick + 1 and q("uni_sqrt_ratio_at_tick", tick + 1) == str(sqrt):
                ticks.note("on a tick boundary")
            else:
                ticks.eq(mine, tick, log["data"])
        if log["sig"].startswith(("event Transfer(", "event Approval(")):
            got = q("erc_decode", joined, data)
            kind = "erc20_" + log["sig"].split()[1].split("(")[0].lower()
            g = json.loads(got)
            if g["event"].startswith("erc721") or not g["event"].startswith("erc20"):
                erc.note(g["event"])
            else:
                keys = [k for k in g if k != "event"]
                erc.eq((g["event"], [str(g[k]) for k in keys]), (kind, [str(v) for v in vals.values()]), log)
        for v in vals.values():
            if isinstance(v, str) and len(v) == 42 and v.startswith("0x"):
                addr.eq(q("evm_checksum_address", by(v)), to_checksum_address(v), v)
    for x in (t, ticks, erc, addr):
        x.done()

    t = Tally("evm calldata vs eth_abi")
    for c in all_calls:
        params = parse_params(c["sig"])
        data = by(c["input"])
        got = q("evm_decode_calldata", c["sig"], data)
        try:
            vals = abi_decode([p[0] for p in params], data[4:])
            want = {(p[1] or str(i)): render(p[0], p[3], v) for i, (p, v) in enumerate(zip(params, vals))}
        except Exception:
            t.eq(got, None, f"eth_abi rejects {c}")
            continue
        if got is None:
            # Our policy rejects dirty padding and eth_abi's non-strict mode is not used here.
            t.eq(None, want, f"{why('evm_decode_calldata', c['sig'], data)} {c['sig']} {c['input'][:300]}")
        else:
            t.eq(normal(json.loads(got)), normal(want), c["sig"])
    t.done()

    if not d:
        return
    t = Tally("CREATE address vs receipts")
    for c in d["creates"]:
        t.eq("0x" + q("evm_create_address", by(c["from"]), c["nonce"]).hex(), c["address"], c)
    t.done()

    now = d["timestamp"]
    t = Tally("Aave v3 vs getReserveNormalized* on chain")
    for a in d["aave"]:
        r = a["reserve"]
        income_idx, income_rate, debt_idx, debt_rate, last = word(r, 1), word(r, 2), word(r, 3), word(r, 4), word(r, 6)
        t.eq(q("aave_normalized_income", str(income_rate), str(income_idx), last, now), str(word(a["income"], 0)), a["asset"])
        t.eq(q("aave_normalized_debt", str(debt_rate), str(debt_idx), last, now), str(word(a["debt"], 0)), a["asset"])
    t.done()

    t = Tally("Uniswap slot0 tick vs sqrtPriceX96")
    for u in d["uni"]:
        sqrt, tick = word(u["slot0"], 0), signed(word(u["slot0"], 1), 256)
        t.eq(q("uni_tick_at_sqrt_ratio", str(sqrt)), tick, u["pool"])
    t.done()

    t = Tally("Compound exchangeRateStored")
    c = {k: word(v, 0) for k, v in d["compound"].items()}
    t.eq(q("compound_exchange_rate", str(c["getCash"]), str(c["totalBorrows"]), str(c["totalReserves"]), str(c["totalSupply"]), "200000000000000"), str(c["exchangeRateStored"]))
    t.done()


TOKEN_NAMES = {"close_authority": "newAuthority", "fee": "feeAmount"}


def compare_token(t, row, got):
    """Every field we output that the node also reports must match it."""
    p = row["parsed"]
    if got is None:
        t.note(f"NULL {p['type']}: {why('spl_decode', base58.b58decode(row['data']))}")
        return
    g = json.loads(got)
    info = p["info"]
    t.eq(g["type"].replace("_", ""), p["type"].lower(), row)
    for key, value in g.items():
        if key in ("type", "authority_type", "extension_types", "m"):
            continue
        name = TOKEN_NAMES.get(key, key.split("_")[0] + "".join(w.title() for w in key.split("_")[1:]))
        want = info.get(name, info.get("tokenAmount") if key in ("amount", "decimals") else None)
        if isinstance(want, dict):
            want = want.get("decimals" if key == "decimals" else "amount")
        if name in info or isinstance(info.get("tokenAmount"), dict) and key in ("amount", "decimals"):
            t.eq(str(value), str(want), (key, row))


WHIRLPOOL = "whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc"
METAPLEX = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"
EMIT_CPI = bytes.fromhex("e445a52e51cb9a1d")
PROGRAMS = {
    "dRiftyHA39MWEi3m9aunc5MzRF1JYuBsbn6VPcn33UH": "drift",
    "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P": "pump",
    "LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo": "meteora_dlmm",
    "KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD": "kamino",
    "SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf": "squads",
    "4MangoMjqJ2firMokCjjGgoK8d4MXcrgL7XJaL3w6fVg": "mango",
    "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s": "token_metadata",
    "whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc": "whirlpool",
}


def svm():
    d = load("svm")
    if not d:
        return
    t = Tally("SPL instructions vs node jsonParsed")
    for s in d["spl"]:
        data = base58.b58decode(s["data"])
        got = q("spl_decode", data)
        compare_token(t, s, got)
    t.done()

    t = Tally("Token-2022 instructions vs node jsonParsed")
    for s in load("token2022")["rows"]:
        compare_token(t, s, q("spl_decode", base58.b58decode(s["data"])))
    t.done()

    t = Tally("metadata PDA vs solders")
    meta = Pubkey.from_string("metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s")
    for m in d["mints"]:
        key = bytes(Pubkey.from_string(m))
        seeds = [b"metadata", bytes(meta), key]
        want, bump = Pubkey.find_program_address(seeds, meta)
        text = ",".join(x.hex() for x in seeds)
        t.eq(q("sol_pda", str(meta), text), str(want), m)
        t.eq(q("sol_pda_bump", str(meta), text), bump, m)
    t.done()

    idls = {os.path.basename(p)[:-5]: open(p).read() for p in glob.glob(IDLS + "/*.json")}
    if not idls:
        notes.append("Solana IDL replay skipped: run scripts/fetch_reference.sh")
        return
    names = dict(PROGRAMS)
    t = Tally("Anchor instructions vs IDL (no independent answer)")
    for name, rows in d["instructions"].items():
        if name not in idls:
            t.note(f"no IDL held for {name}: {len(rows)} rows")
            continue
        for row in rows:
            data = base58.b58decode(row)
            if data.startswith(EMIT_CPI):
                decoded = q("anchor_decode_event", idls[name], data) is not None
                t.note(f"{'decoded' if decoded else 'NULL'} {name} emit_cpi event" + ("" if decoded else f": {why('anchor_decode_event', idls[name], data)}"))
            elif q("anchor_decode_instruction", idls[name], data) is None:
                t.note(f"NULL {name}: {why('anchor_decode_instruction', idls[name], data)}")
            else:
                t.note(f"decoded {name}")
    t.done()

    t = Tally("Anchor accounts vs IDL (no independent answer)")
    ticks = Tally("Raydium pool tick vs sqrt_price_x64")
    orca = Tally("Whirlpool tick vs sqrt_price")
    meta = Tally("Metaplex Metadata mint re-derives its account address")
    for a in d["accounts"]:
        data = base64.b64decode(a["data"])
        if a["owner"] == "CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK":
            if len(data) == 1544:
                sqrt = int.from_bytes(data[253:269], "little")
                tick = int.from_bytes(data[269:273], "little", signed=True)
                ticks.eq(q("raydium_tick_from_sqrt_price", str(sqrt)), tick, a["key"])
            continue
        if a["owner"] == WHIRLPOOL:
            got = q("anchor_decode_account", idls["whirlpool"], data)
            t.note("decoded whirlpool" if got else f"NULL whirlpool: {why('anchor_decode_account', idls['whirlpool'], data)}")
            if len(data) == 653:
                sqrt = int.from_bytes(data[65:81], "little")
                tick = int.from_bytes(data[81:85], "little", signed=True)
                mine = q("orca_tick_from_sqrt_price", str(sqrt))
                if mine == tick + 1 and q("orca_sqrt_price_from_tick", mine) == str(sqrt):
                    orca.note("on a tick boundary, exact")
                else:
                    orca.eq(mine, tick, a["key"])
                if got:
                    w = json.loads(got)["data"]
                    orca.eq((str(w["sqrt_price"]), w["tick_current_index"]), (str(sqrt), tick), a["key"])
            continue
        if a["owner"] == METAPLEX:
            kind = {4: "Metadata", 6: "MasterEditionV2", 11: "TokenRecord"}.get(data[0])
            got = q("anchor_decode_account_raw", idls["token_metadata"], kind, data) if kind else None
            if got is None:
                meta.note(f"NULL key {data[0]}: {why('anchor_decode_account_raw', idls['token_metadata'], kind or '', data)}")
            elif kind == "Metadata":
                # Our decoded mint must derive the address this account actually lives at.
                mint = Pubkey.from_string(json.loads(got)["data"]["mint"])
                program = Pubkey.from_string(METAPLEX)
                want, _ = Pubkey.find_program_address([b"metadata", bytes(program), bytes(mint)], program)
                meta.eq(str(want), a["key"], got)
            else:
                meta.note(f"decoded {kind}")
            continue
        name = names.get(a["owner"])
        if name is None:
            t.note(f"no IDL held for {a['owner']}")
            continue
        if q("anchor_decode_account", idls[name], data) is None:
            t.note(f"NULL {name}: {why('anchor_decode_account', idls[name], data)}")
        else:
            t.note(f"decoded {name}")
    t.done()
    ticks.done()
    orca.done()
    meta.done()

    t = Tally("Anchor event logs vs IDLs (no independent answer)")
    for line in d["events"]:
        hits = [n for n, idl in idls.items() if q("anchor_decode_event_log", idl, "Program data: " + line) is not None]
        t.note("decoded by " + (hits[0] if hits else "no IDL we hold"))
    t.done()


BTC_TYPES = {"v0_p2wpkh": "p2wpkh", "v0_p2wsh": "p2wsh", "v1_p2tr": "p2tr", "p2pkh": "p2pkh", "p2sh": "p2sh", "op_return": "op_return", "p2pk": "p2pk", "multisig": "multisig"}


def plain(b):
    return all(0x20 <= c <= 0x7e and c not in (0x22, 0x5c) for c in b)


def bitcoin():
    d = load("bitcoin")
    if not d:
        return
    t = Tally("bitcoin scripts vs mempool.space")
    for o in d["outputs"]:
        s = by(o["script"])
        kind = q("btc_script_type", s)
        if o["type"] in BTC_TYPES:
            t.eq(kind, BTC_TYPES[o["type"]], o)
        else:
            t.note(f"{o['type']} is {kind}")
        t.eq(q("btc_address", "bitcoin", s), o["address"], o)
    t.done()

    t = Tally("runestones vs ord port")
    for x in d["op_returns"]:
        s = by(x)
        got = q("btc_runestone", s)
        want = ord_runestone(s)
        if want is None or want == "flaw":
            t.eq(got, None, x)
            continue
        if not got:
            t.eq(None, want, x)
            continue
        g = json.loads(got)
        flat = [int(v) for pair in g["fields"] for v in pair]
        body = [int(v) for v in g["body"]]
        i = next((k for k in range(0, len(want), 2) if want[k] == 0), None)
        t.eq((flat, body), (want, []) if i is None else (want[:i], want[i + 1 :]), x)
    t.done()

    t = Tally("inscriptions vs ord port")
    for x in d["tapscripts"]:
        s = by(x)
        got = q("btc_inscription", s)
        want = ord_inscription(s)
        if want is None:
            t.eq(got in (None, "null"), True, x)
            continue
        g = json.loads(got)
        ct = want[0].decode() if want[0] is not None and plain(want[0]) else None
        t.eq((g["content_type"], g["body"]), (ct, "0x" + want[1].hex()), x)
    t.done()


def aptos():
    t = Tally("Aptos BCS resources vs node JSON")

    def shape(v):
        if isinstance(v, dict):
            if set(v) == {"vec"}:  # the node renders an option as a vector of up to one
                return shape(v["vec"][0]) if v["vec"] else None
            return {k: shape(x) for k, x in v.items()}
        if isinstance(v, bool):
            return v
        return None if v is None else str(v)

    def address(v):
        if isinstance(v, dict):
            return {k: address(x) for k, x in v.items()}
        if isinstance(v, str) and v.startswith("0x"):
            return "0x" + v[2:].rjust(64, "0")
        return v

    for r in load("aptos").get("resources", []):
        got = q("bcs_decode", r["schema"], by(r["bcs"]))
        if got is None:
            t.eq(why("bcs_decode", r["schema"], by(r["bcs"])), "decoded", r["tag"])
            continue
        t.eq(address(shape(json.loads(got))), address(shape(r["json"])), r["tag"])
    t.done()


def sui():
    d = load("sui")
    if not d:
        return
    t = Tally("Sui coin BCS vs node JSON")
    for c in d["coins"]:
        got = q("bcs_decode", "{id:address,balance:u64}", base64.b64decode(c["bcs"]))
        t.eq(json.loads(got) if got else None, {"id": c["json"]["id"], "balance": int(c["json"]["balance"])}, c)
    t.done()
    t = Tally("Cetus pool tick vs current_sqrt_price")
    for p in d["cetus_pools"]:
        tick = signed(p["tick"]["bits"], 32)
        mine = q("cetus_tick_from_sqrt_price", p["sqrt_price"])
        # A swap ending exactly on a tick while moving down reports tick - 1, as in Uniswap.
        if mine == tick + 1 and q("cetus_sqrt_price_from_tick", mine) == p["sqrt_price"]:
            t.note("on a tick boundary, exact")
        else:
            t.eq(mine, tick, p)
    t.done()


def cosmos():
    d = load("cosmos")
    if not d:
        return
    t = Tally("IBC denom vs node hash")
    for x in d["denoms"]:
        t.eq(q("ibc_denom", x["trace"]), "ibc/" + x["hash"], x["trace"])
    t.done()
    t = Tally("bech32 validator addresses")
    for v in d["valopers"]:
        t.eq(q("cosmos_is_valid", v), True, v)
        t.eq(q("cosmos_convert_hrp", q("cosmos_convert_hrp", v, "cosmos"), "cosmosvaloper"), v, v)
    t.done()


for section in (evm, svm, bitcoin, aptos, sui, cosmos):
    section()
for n in notes:
    print(n)
sys.exit(1 if mismatches else 0)
