#!/usr/bin/env python3
"""Differential test of Bitcoin script payloads against a port of ord's published rules.

See ord_port.py for what was ported, and why this is weaker than running ord itself.

Usage: utxo_diff.py [extension] [cases] [seed]. Exits non-zero on any mismatch.
"""
import json
import os
import random
import sys
from collections import Counter

import duckdb
import pyarrow as pa
from ord_port import OP_0, OP_13, OP_ENDIF, OP_IF, OP_RETURN, ord_inscription, ord_runestone, varint

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
CASES = int(sys.argv[2]) if len(sys.argv) > 2 else 100000
rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)

con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")



def push(b):
    n = len(b)
    if n == 0 and rng.random() < 0.8:
        return b"\x00"
    roll = rng.random()
    if n <= 0x4b and roll < 0.8:
        return bytes([n]) + b
    if n <= 0xff and roll < 0.9:
        return bytes([0x4c, n]) + b
    if n <= 0xffff and roll < 0.97:
        return bytes([0x4d]) + n.to_bytes(2, "little") + b
    return bytes([0x4e]) + n.to_bytes(4, "little") + b


def gen_envelope():
    s = bytearray()
    if rng.random() < 0.3:
        s += push(rng.randbytes(32)) + b"\xac"
    for _ in range(rng.choice([1, 1, 1, 2, 3])):
        s += push(b"") + bytes([OP_IF]) + push(rng.choice([b"ord", b"ord", b"ord", b"ore"]))
        for _ in range(rng.randint(0, 3)):
            s += rng.choice([push(b"\x01"), b"\x51", push(rng.randbytes(1)), push(b"\x05")])
            if rng.random() < 0.9:
                s += push(rng.choice([b"text/plain", b"image/png", b"", b'a"b', rng.randbytes(4)]))
        if rng.random() < 0.8:
            s += push(b"")
            for _ in range(rng.randint(0, 3)):
                s += rng.choice([push(rng.randbytes(rng.randint(0, 40))), b"\x51", b"\x4f"])
        if rng.random() < 0.1:
            s += bytes([rng.choice([0x76, 0x50, 0x62, 0xac])])
        if rng.random() < 0.92:
            s += bytes([OP_ENDIF])
    return bytes(s)


def enc_varint(v, pad=False):
    out = bytearray()
    while v >> 7:
        out.append((v & 0x7f) | 0x80)
        v >>= 7
    out.append(v)
    if pad:
        out[-1] |= 0x80
        out.append(0)
    return bytes(out)


def gen_runestone():
    ints = []
    for _ in range(rng.randint(0, 5)):
        ints += [rng.choice([1, 2, 4, 5, 6, 8, 10, 22, rng.getrandbits(16) | 1]), rng.choice([0, 1, 127, 128, 2**64, 2**128 - 1, rng.getrandbits(40)])]
    if rng.random() < 0.6:
        ints += [0] + [rng.choice([0, 1, 300, rng.getrandbits(100)]) for _ in range(rng.randint(0, 8))]
    if rng.random() < 0.1:
        ints.append(rng.getrandbits(20))
    data = b"".join(enc_varint(i, rng.random() < 0.05) for i in ints)
    s, i = bytearray([OP_RETURN, OP_13]), 0
    while i < len(data):
        n = rng.randint(1, 40)
        s += push(data[i:i + n])
        i += n
    return bytes(s)


def mutate(s):
    b = bytearray(s)
    if not b:
        return b"\x00"
    roll = rng.random()
    if roll < 0.2:
        return bytes(b[: rng.randrange(len(b))])
    if roll < 0.3:
        return bytes(b) + rng.randbytes(rng.randint(1, 8))
    for _ in range(rng.choice([1, 1, 2, 4])):
        b[rng.randrange(len(b))] = rng.choice([0, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x60, 0x63, 0x68, 0x6a, 0x76, rng.randrange(256)])
    return bytes(b)


def run(name, sql, gen, compare):
    scripts = [gen() if i % 2 else mutate(gen()) for i in range(CASES)]
    table = pa.table({"id": list(range(len(scripts))), "b": pa.array(scripts, pa.binary())})
    con.register("t", table)
    rows = con.execute(f"select {sql}(b) from t order by id").fetchall()
    stats = Counter()
    samples = []
    for s, (got,) in zip(scripts, rows):
        verdict = compare(s, got)
        stats[verdict] += 1
        if verdict.startswith("MISMATCH") and len(samples) < 5:
            samples.append((verdict, s.hex()[:300], str(got)[:300]))
    print(f"== {name}")
    for k, v in sorted(stats.items()):
        print(f"{v:>9}  {k}")
    for x in samples:
        print("   ", *x, sep="\n      ")
    return sum(v for k, v in stats.items() if k.startswith("MISMATCH"))


def plain(b):
    return all(0x20 <= c <= 0x7e and c not in (0x22, 0x5c) for c in b)


def cmp_inscription(s, got):
    want = ord_inscription(s)
    if want is None:
        return "agree: none" if got in (None, "null") else "MISMATCH only we found one"
    if got in (None, "null"):
        return "MISMATCH only ord found one"
    g = json.loads(got)
    ct = want[0].decode() if want[0] is not None and plain(want[0]) else None
    if g["content_type"] != ct or g["body"] != "0x" + want[1].hex():
        return "MISMATCH values"
    return "agree: inscription"


def cmp_runestone(s, got):
    want = ord_runestone(s)
    if want is None or want == "flaw":
        return "agree: none or flawed" if got is None else "MISMATCH only we decoded"
    if got is None:
        return "MISMATCH only ord decoded"
    g = json.loads(got)
    flat = [int(x) for pair in g["fields"] for x in pair]
    body = [int(x) for x in g["body"]]
    i = next((k for k in range(0, len(want), 2) if want[k] == 0), None)
    head, tail = (want, []) if i is None else (want[:i], want[i + 1:])
    return "agree: runestone" if (flat, body) == (head, tail) else "MISMATCH values"


bad = run("inscriptions", "web3_btc_inscription", gen_envelope, cmp_inscription)
bad += run("runestones", "web3_btc_runestone", gen_runestone, cmp_runestone)
sys.exit(1 if bad else 0)
