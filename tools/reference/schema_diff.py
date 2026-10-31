#!/usr/bin/env python3
"""Random Borsh and BCS schemas, encoded by a small encoder written from each format's specification.

Checks that valid values decode exactly, and that a truncated row, a row with a trailing byte, and
a non-canonical BCS length all give NULL.

Usage: schema_diff.py [extension] [cases] [seed]. Exits non-zero on any mismatch.
"""
import json
import os
import random
import struct
import sys
from collections import Counter

import base58
import duckdb

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
CASES = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")

TEXT = ["", "a", "héllo", 'q"uo\\te', "new\nline", "😀" * 3]


def rand_int(bits, signed):
    v = rng.choice([0, 1, 255, 2**53, 2**53 + 1, rng.getrandbits(bits), 2**bits - 1])
    v &= 2**bits - 1
    if signed and v >= 2 ** (bits - 1):
        v -= 2**bits
    return v


def int_bytes(v, bits):
    return (v & (2**bits - 1)).to_bytes(bits // 8, "little")


def uleb(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7f) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def size(gen, n=4):
    return [gen() for _ in range(rng.randint(0, n))]


def borsh(depth=0):
    """Returns (schema text, encoded bytes, expected JSON value) generators as a single sample."""
    roll = rng.random()
    if depth < 3 and roll < 0.3:
        fields = [(f"f{i}", borsh_type(depth + 1)) for i in range(rng.randint(1, 4))]
        return "{" + ",".join(f"{n}:{t[0]}" for n, t in fields) + "}", ("record", fields)
    return borsh_type(depth)


def borsh_type(depth):
    roll = rng.random()
    if depth < 3 and roll < 0.2:
        t = borsh_type(depth + 1)
        return f"vec<{t[0]}>", ("vec", t)
    if depth < 3 and roll < 0.35:
        t = borsh_type(depth + 1)
        return f"option<{t[0]}>", ("option", t)
    if depth < 3 and roll < 0.5:
        t = borsh_type(depth + 1)
        n = 0 if zero_sized(t) else rng.randint(0, 3)
        return f"[{t[0]};{n}]", ("array", t, n)
    if depth < 3 and roll < 0.62:
        fields = [(f"f{i}", borsh_type(depth + 1)) for i in range(rng.randint(1, 3))]
        return "{" + ",".join(f"{n}:{t[0]}" for n, t in fields) + "}", ("record", fields)
    p = rng.choice(["bool", "string", "pubkey", "f32", "f64"] + [f"{s}{b}" for s in "ui" for b in (8, 16, 32, 64, 128, 256)])
    return p, ("prim", p)


def sample_borsh(t):
    kind = t[1][0]
    if kind == "prim":
        p = t[1][1]
        if p == "bool":
            v = rng.random() < 0.5
            return bytes([v]), v
        if p == "string":
            s = rng.choice(TEXT)
            return struct.pack("<I", len(s.encode())) + s.encode(), s
        if p == "pubkey":
            k = rng.randbytes(32)
            return k, base58.b58encode(k).decode()
        if p in ("f32", "f64"):
            v = rng.choice([0.0, -0.25, 1.5, 1e10, rng.random()])
            fmt = "<f" if p == "f32" else "<d"
            raw = struct.pack(fmt, v)
            return raw, ("float", fmt, raw)
        bits, signed = int(p[1:]), p[0] == "i"
        v = rand_int(bits, signed)
        return int_bytes(v, bits), v
    if kind == "vec":
        # Zero-sized elements are rejected as a denial-of-service guard: Rust borsh does so for
        # vectors, we also do for arrays, or `[[u8;0];4294967295]` would spin without reading input.
        items = [] if zero_sized(t[1][1]) else [sample_borsh(t[1][1]) for _ in range(rng.randint(0, 3))]
        raw = struct.pack("<I", len(items)) + b"".join(i[0] for i in items)
        return raw, wrap_bytes(t[1][1], items)
    if kind == "array":
        items = [sample_borsh(t[1][1]) for _ in range(t[1][2])]
        return b"".join(i[0] for i in items), wrap_bytes(t[1][1], items)
    if kind == "option":
        if rng.random() < 0.5:
            return b"\0", None
        raw, v = sample_borsh(t[1][1])
        return b"\1" + raw, v
    parts = [(n, sample_borsh(c)) for n, c in t[1][1]]
    return b"".join(p[1][0] for p in parts), {n: p[1] for n, p in parts}


def zero_sized(t):
    kind = t[1][0]
    if kind == "array":
        return t[1][2] == 0 or zero_sized(t[1][1])
    return kind == "record" and all(zero_sized(c) for _, c in t[1][1])


def wrap_bytes(elem, items):
    if elem[1] == ("prim", "u8"):
        return "0x" + b"".join(i[0] for i in items).hex()
    return [i[1] for i in items]


def bcs_type(depth=0):
    roll = rng.random()
    if depth < 3 and roll < 0.18:
        t = bcs_type(depth + 1)
        return f"vector<{t[0]}>", ("vec", t)
    if depth < 3 and roll < 0.3:
        t = bcs_type(depth + 1)
        return f"option<{t[0]}>", ("option", t)
    if depth < 3 and roll < 0.42:
        ts = [bcs_type(depth + 1) for _ in range(rng.randint(1, 3))]
        return "enum<" + "|".join(t[0] for t in ts) + ">", ("enum", ts)
    if depth < 3 and roll < 0.52:
        ts = [bcs_type(depth + 1) for _ in range(rng.randint(1, 3))]
        return "(" + ",".join(t[0] for t in ts) + ")", ("tuple", ts)
    if depth < 3 and roll < 0.64:
        fields = [(f"f{i}", bcs_type(depth + 1)) for i in range(rng.randint(1, 3))]
        return "{" + ",".join(f"{n}:{t[0]}" for n, t in fields) + "}", ("record", fields)
    p = rng.choice(["bool", "address", "string", "u8", "u16", "u32", "u64", "u128", "u256"])
    return p, ("prim", p)


def sample_bcs(t):
    kind = t[1][0]
    if kind == "prim":
        p = t[1][1]
        if p == "bool":
            v = rng.random() < 0.5
            return bytes([v]), v
        if p == "string":
            s = rng.choice(TEXT)
            return uleb(len(s.encode())) + s.encode(), s
        if p == "address":
            a = rng.randbytes(32)
            return a, "0x" + a.hex()
        bits = int(p[1:])
        v = rand_int(bits, False)
        return int_bytes(v, bits), v
    if kind == "vec":
        items = [sample_bcs(t[1][1]) for _ in range(rng.randint(0, 3))]
        return uleb(len(items)) + b"".join(i[0] for i in items), wrap_bytes(t[1][1], items)
    if kind == "option":
        if rng.random() < 0.5:
            return b"\0", None
        raw, v = sample_bcs(t[1][1])
        return b"\1" + raw, v
    if kind == "enum":
        i = rng.randrange(len(t[1][1]))
        raw, v = sample_bcs(t[1][1][i])
        return uleb(i) + raw, {"variant": i, "value": v}
    if kind == "tuple":
        items = [sample_bcs(c) for c in t[1][1]]
        return b"".join(i[0] for i in items), [i[1] for i in items]
    parts = [(n, sample_bcs(c)) for n, c in t[1][1]]
    return b"".join(p[1][0] for p in parts), {n: p[1] for n, p in parts}


def same(got, want):
    if isinstance(want, tuple):
        return struct.pack(want[1], float(got)) == want[2]
    if isinstance(want, bool) or want is None:
        return got is want or got == want
    if isinstance(want, int):
        return int(got) == want
    if isinstance(want, list):
        return len(got) == len(want) and all(same(a, b) for a, b in zip(got, want))
    if isinstance(want, dict):
        return got.keys() == want.keys() and all(same(got[k], want[k]) for k in want)
    return got == want


def decode(fn, schema, raw):
    return con.execute(f"select {fn}(?, ?)", [schema, raw]).fetchone()[0]


stats = Counter()
samples = {}


def check(label, ok, *info):
    stats[("ok " if ok else "MISMATCH ") + label] += 1
    if not ok:
        samples.setdefault(label, info)


for _ in range(CASES):
    for name, fn, gen, sample in (("borsh", "web3_borsh_decode", borsh, sample_borsh), ("bcs", "web3_bcs_decode", bcs_type, sample_bcs)):
        t = gen()
        raw, want = sample(t)
        got = decode(fn, t[0], raw)
        if got is None:
            why = con.execute(f"select {fn}_error(?, ?)", [t[0], raw]).fetchone()[0]
            check(f"{name} valid", False, t[0], raw.hex(), why)
            continue
        check(f"{name} valid", same(json.loads(got), want), t[0], raw.hex(), got, want)
        check(f"{name} trailing byte", decode(fn, t[0], raw + b"\0") is None, t[0], raw.hex())
        if raw:
            check(f"{name} truncated", decode(fn, t[0], raw[:-1]) is None, t[0], raw.hex())
    # BCS lengths must be canonical: pad the top-level length of a vector with a continuation byte.
    n = rng.randint(1, 3)
    check("bcs canonical uleb", decode("web3_bcs_decode", "vector<u8>", bytes([0x80 | n, 0]) + b"x" * n) is None, n)

for k, v in sorted(stats.items()):
    print(f"{v:>9}  {k}")
for k, info in samples.items():
    print(f"--- {k}")
    for x in info:
        print("   ", str(x)[:300])
sys.exit(1 if any(k.startswith("MISMATCH") for k in stats) else 0)
