#!/usr/bin/env python3
"""Mutates the calls test_duckdb.py recorded, asks DuckDB for the answers, and writes them out in the
same format for scripts/test_wasm.mjs to replay, so native and WASM face the same hostile inputs.

Usage: wasm_diff.py [extension] [mutants per call] [out.json] [seed]
"""
import json
import os
import random
import sys

import duckdb

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
MUTANTS = int(sys.argv[2]) if len(sys.argv) > 2 else 3
OUT = sys.argv[3] if len(sys.argv) > 3 else os.path.join(REPO, "dist", "mutated_calls.json")
rng = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 1)
# Past this the two hosts legitimately differ: DuckDB retries on the heap, WASM stops near 60 KB.
MAX_ARG = 16 * 1024

con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")


def mutate_bytes(b):
    b = bytearray(b)
    roll = rng.random()
    if b and roll < 0.45:
        for _ in range(rng.randint(1, 3)):
            b[rng.randrange(len(b))] = rng.choice([0, 1, 0x7f, 0x80, 0xff, rng.randrange(256)])
    elif b and roll < 0.75:
        del b[rng.randrange(len(b)):]
    else:
        b[rng.randint(0, len(b)):rng.randint(0, len(b))] = rng.randbytes(rng.randint(1, 8))
    return bytes(b)


def mutate_text(s):
    # Still valid UTF-8, since VARCHAR cannot hold anything else.
    return mutate_bytes(s.encode()).decode("utf-8", "ignore").replace("\0", "")


def mutate_int(n):
    return rng.choice([0, 1, -1, n + 1, n - 1, -n, 2**31, 2**53 - 1, -(2**53) + 1])


def mutate(call):
    args = list(call["args"])
    i = rng.randrange(len(args))
    a, t = args[i], call["types"][i]
    if a is None:
        return None
    if t == "BLOB":
        args[i] = {"hex": mutate_bytes(bytes.fromhex(a["hex"])).hex()}
    elif t == "VARCHAR":
        args[i] = mutate_text(a)
    elif t == "BOOLEAN":
        args[i] = not a
    else:
        args[i] = mutate_int(a)
    return args


def to_sql(a):
    return bytes.fromhex(a["hex"]) if isinstance(a, dict) else a


def portable(v):
    return {"hex": bytes(v).hex()} if isinstance(v, (bytes, bytearray, memoryview)) else v


calls = json.load(open(os.path.join(REPO, "dist", "duckdb_calls.json")))
out, nulls = [], 0
for call in calls:
    if not call["args"]:
        out.append(call)
        continue
    for _ in range(MUTANTS):
        args = mutate(call)
        if args is None or sum(len(a["hex"]) // 2 if isinstance(a, dict) else len(str(a)) for a in args) > MAX_ARG:
            continue
        # unnest keeps every argument a row value: a constant bad schema is a bind error instead,
        # which WASM has no equivalent of.
        cols = ", ".join(f"unnest([?::{t}]) c{i}" for i, t in enumerate(call["types"]))
        names = ", ".join(f"c{i}" for i in range(len(args)))
        got = con.execute(f"select {call['name']}({names}) from (select {cols})", [to_sql(a) for a in args]).fetchone()[0]
        nulls += got is None
        out.append({"name": call["name"], "args": args, "types": call["types"], "ret": call["ret"], "result": portable(got)})

with open(OUT, "w") as f:
    json.dump(out, f)
print(f"{len(out)} mutated calls, {nulls} NULL ({nulls * 100 // max(len(out), 1)}%)")
