#!/usr/bin/env python3
"""Differential test of the ABI decoder against eth_abi on generated types, values and mutations.

Usage: evm_diff.py [extension] [cases] [seed]. Exits non-zero on any value mismatch; accept/reject
disagreements on mutated bytes are reported by category, with samples.
"""
import json
import os
import random
import sys
from collections import Counter

import duckdb
from eth_abi import decode, encode
from Crypto.Hash import keccak

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
CASES = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)

con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")


def gen_type(depth=0):
    """A type is (canonical, human_readable, kind, children)."""
    roll = rng.random()
    if depth < 3 and roll < 0.18:
        inner = gen_type(depth + 1)
        n = rng.choice([None, None, 1, 2, 3])
        suffix = "[]" if n is None else f"[{n}]"
        return (inner[0] + suffix, inner[1] + suffix, "array", (inner, n))
    if depth < 3 and roll < 0.34:
        items = [gen_type(depth + 1) for _ in range(rng.randint(1, 4))]
        canon = "(" + ",".join(t[0] for t in items) + ")"
        human = "(" + ", ".join(f"{t[1]} f{i}" for i, t in enumerate(items)) + ")"
        return (canon, human, "tuple", items)
    kind = rng.choice(["uint", "int", "address", "bool", "bytesN", "bytes", "string"])
    if kind in ("uint", "int"):
        bits = 8 * rng.randint(1, 32)
        t = f"{kind}{bits}"
        return (t, t, kind, bits)
    if kind == "bytesN":
        n = rng.randint(1, 32)
        return (f"bytes{n}", f"bytes{n}", kind, n)
    return (kind, kind, kind, None)


def gen_value(t):
    kind, arg = t[2], t[3]
    if kind == "uint":
        return rng.choice([0, 1, 2**arg - 1, rng.getrandbits(arg)])
    if kind == "int":
        return rng.choice([0, -1, 2 ** (arg - 1) - 1, -(2 ** (arg - 1)), rng.getrandbits(arg - 1) - 2 ** (arg - 2) if arg > 1 else 0])
    if kind == "address":
        return "0x" + rng.randbytes(20).hex()
    if kind == "bool":
        return rng.random() < 0.5
    if kind == "bytesN":
        return rng.randbytes(arg)
    if kind == "bytes":
        return rng.randbytes(rng.choice([0, 1, 31, 32, 33, 64, 200]))
    if kind == "string":
        return "".join(rng.choice('aé"\\\n€😀z') for _ in range(rng.choice([0, 1, 5, 40])))
    if kind == "array":
        inner, n = arg
        return [gen_value(inner) for _ in range(rng.randint(0, 3) if n is None else n)]
    return tuple(gen_value(c) for c in arg)


def norm(t, v):
    """Reference value in the shape web3_evm_decode_* renders."""
    kind, arg = t[2], t[3]
    if kind in ("uint", "int"):
        return int(v)
    if kind in ("bytesN", "bytes"):
        return "0x" + bytes(v).hex()
    if kind == "array":
        return [norm(arg[0], x) for x in v]
    if kind == "tuple":
        return {f"f{i}": norm(c, x) for i, (c, x) in enumerate(zip(arg, v))}
    return v


def ours_norm(t, v):
    """Our JSON with big integers (emitted as strings) folded to int."""
    kind, arg = t[2], t[3]
    if kind in ("uint", "int"):
        return int(v)
    if kind == "array":
        return [ours_norm(arg[0], x) for x in v]
    if kind == "tuple":
        return {k: ours_norm(c, v[k]) for k, c in zip(sorted(v, key=lambda s: int(s[1:])), arg)}
    return v


def selector(canon):
    return keccak.new(digest_bits=256, data=canon.encode()).digest()[:4]


def mutate(p):
    b = bytearray(p)
    roll = rng.random()
    if not b or roll < 0.2:
        return bytes(b) + rng.randbytes(rng.choice([1, 31, 32]))
    if roll < 0.4:
        return bytes(b[: rng.randrange(len(b))])
    for _ in range(rng.choice([1, 1, 2, 8])):
        i = rng.randrange(len(b))
        b[i] = rng.choice([0, 1, 0x20, 0x40, 0x7f, 0x80, 0xff, rng.randrange(256)])
    return bytes(b)


stats = Counter()
samples = {}


def sample(key, *info):
    samples.setdefault(key, info)


for case in range(CASES):
    args = [gen_type() for _ in range(rng.randint(1, 5))]
    canon = "f(" + ",".join(t[0] for t in args) + ")"
    human = "function f(" + ", ".join(f"{t[1]} a{i}" for i, t in enumerate(args)) + ")"
    types = [t[0] for t in args]
    values = [gen_value(t) for t in args]
    payload = encode(types, values)
    sel = selector(canon)

    got_canon = con.execute("select web3_evm_canonical_signature(?)", [human]).fetchone()[0]
    got_sel = con.execute("select web3_evm_selector(?)", [human]).fetchone()[0]
    if got_canon != canon or bytes(got_sel or b"") != sel:
        stats["SIGNATURE MISMATCH"] += 1
        sample("SIGNATURE MISMATCH", human, got_canon, canon)
        continue

    want = {f"a{i}": norm(t, v) for i, (t, v) in enumerate(zip(args, decode(types, payload)))}
    raw = con.execute("select web3_evm_decode_calldata(?, ?)", [human, sel + payload]).fetchone()[0]
    if raw is None:
        stats["VALID REJECTED"] += 1
        sample("VALID REJECTED", human, payload.hex())
        continue
    got = json.loads(raw)
    got = {f"a{i}": ours_norm(t, got[f"a{i}"]) for i, t in enumerate(args)}
    if got != want:
        stats["VALUE MISMATCH"] += 1
        sample("VALUE MISMATCH", human, payload.hex(), got, want)
        continue
    stats["valid ok"] += 1

    m = mutate(payload)
    try:
        ref = {f"a{i}": norm(t, v) for i, (t, v) in enumerate(zip(args, decode(types, m)))}
    except Exception as e:
        ref = None
        ref_err = type(e).__name__
    raw = con.execute("select web3_evm_decode_calldata(?, ?)", [human, sel + m]).fetchone()[0]
    if raw is None and ref is None:
        stats["mutated: both reject"] += 1
    elif raw is None:
        stats["mutated: only we reject"] += 1
        sample("mutated: only we reject", human, m.hex())
    elif ref is None:
        # We decode as eth_abi's strict=False does, tolerating dirty or missing tail padding.
        got = json.loads(raw)
        got = {f"a{i}": ours_norm(t, got[f"a{i}"]) for i, t in enumerate(args)}
        try:
            lax = {f"a{i}": norm(t, v) for i, (t, v) in enumerate(zip(args, decode(types, m, strict=False)))}
        except Exception as e:
            lax = None
            ref_err += "+" + type(e).__name__
        if lax == got:
            stats["mutated: padding only, equal to strict=False"] += 1
        elif lax is None:
            key = f"mutated: only eth_abi rejects ({ref_err})"
            stats[key] += 1
            changed = [i for i in range(min(len(m), len(payload))) if m[i] != payload[i]]
            sample(key, human, f"len {len(payload)} -> {len(m)}, changed bytes {changed[:12]}", [m[i:i + 32].hex() for i in range(0, len(m), 32)], raw)
        else:
            stats["MUTATED VALUE MISMATCH (strict=False)"] += 1
            sample("MUTATED VALUE MISMATCH (strict=False)", human, m.hex(), got, lax)
    else:
        got = json.loads(raw)
        got = {f"a{i}": ours_norm(t, got[f"a{i}"]) for i, t in enumerate(args)}
        if got == ref:
            stats["mutated: both accept, equal"] += 1
        else:
            stats["MUTATED VALUE MISMATCH"] += 1
            sample("MUTATED VALUE MISMATCH", human, m.hex(), got, ref)

for k, v in sorted(stats.items()):
    print(f"{v:>9}  {k}")
for k, info in samples.items():
    print(f"\n--- {k}")
    for x in info:
        print("   ", str(x)[:1800])
bad = sum(v for k, v in stats.items() if k.isupper() or k.startswith(("VALID", "VALUE", "MUTATED", "SIGNATURE")))
sys.exit(1 if bad else 0)
