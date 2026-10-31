#!/usr/bin/env python3
"""Decodes what the real SDKs encode: @mysten/bcs for BCS, cosmjs for Bech32 and IBC denoms.

Also parses the generated warehouse SQL with sqlglot. Run `npm ci --ignore-scripts` in tools/reference/sdk first.
Usage: sdk_diff.py [extension] [cases] [seed]. Exits non-zero on any mismatch.
"""
import json
import os
import subprocess
import sys
import tempfile

import duckdb
import sqlglot

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
CASES = sys.argv[2] if len(sys.argv) > 2 else "20000"
SEED = sys.argv[3] if len(sys.argv) > 3 else "1"
con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")
q = lambda sql, *a: con.execute(sql, a).fetchone()[0]

with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "cases.json")
    subprocess.run(["node", "gen.mjs", path, CASES, SEED], cwd=os.path.join(HERE, "sdk"), check=True)
    with open(path) as f:
        cases = json.load(f)


def same(got, want):
    if isinstance(want, list):
        return isinstance(got, list) and len(got) == len(want) and all(same(a, b) for a, b in zip(got, want))
    if isinstance(want, dict):
        return isinstance(got, dict) and got.keys() == want.keys() and all(same(got[k], want[k]) for k in want)
    if isinstance(want, str) and isinstance(got, int) and not isinstance(got, bool):
        return str(got) == want
    return got == want


bad = 0


def report(label, *detail):
    global bad
    bad += 1
    if bad <= 10:
        print(f"MISMATCH {label}:", *[str(d)[:200] for d in detail])


for c in cases["bcs"]:
    got = q("select web3_bcs_decode(?, ?)", c["schema"], bytes.fromhex(c["hex"]))
    if got is None or not same(json.loads(got), c["want"]):
        report("bcs", c["schema"], c["hex"], got, c["want"])
typos = sum(c["typo"] != c["address"] for c in cases["bech32"])
assert sum(c["typo_valid"] for c in cases["bech32"]) == len(cases["bech32"]) - typos, "cosmjs validity is not a real answer"
for c in cases["bech32"]:
    if q("select web3_cosmos_convert_hrp(?, ?)", c["address"], c["to"]) != c["converted"]:
        report("bech32 convert", c)
    if not q("select web3_cosmos_is_valid(?)", c["address"]):
        report("bech32 valid", c)
    if q("select web3_cosmos_is_valid(?)", c["typo"]) != c["typo_valid"]:
        report("bech32 typo", c)
for c in cases["ibc"]:
    if q("select web3_ibc_denom(?)", c["trace"]) != c["denom"]:
        report("ibc", c)

for name, dialect in (("snowflake_udfs.sql", "snowflake"), ("bigquery_udfs.sql", "bigquery")):
    with open(os.path.join(REPO, "dist", name)) as f:
        statements = [s for s in sqlglot.parse(f.read().replace("__WEB3_DATASET__", "ds").replace("__WEB3_GCS_URI__", "gs://b/w.js"), dialect=dialect) if s]
    print(f"{name}: {len(statements)} statements parse as {dialect}")
    if len(statements) != 82:
        report("sql", name, len(statements))

print(f"{len(cases['bcs'])} BCS, {len(cases['bech32'])} Bech32, {len(cases['ibc'])} IBC cases: {bad} mismatches")
sys.exit(1 if bad else 0)
