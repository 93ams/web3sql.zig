#!/usr/bin/env python3
"""Runs every query in examples/recipes against the mainnet sample in tools/reference/live.

Usage: test_recipes.py [extension]. Exits non-zero if a recipe fails or returns no rows.
"""
import base64
import glob
import gzip
import json
import os
import sys

import base58
import duckdb
import pyarrow as pa

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
LIVE = os.path.join(REPO, "tools", "reference", "live")
IDLS = os.path.expanduser(os.environ.get("REFERENCE", "~/.cache/web3sql-zig/reference")) + "/idls"
con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")


def load(name):
    with gzip.open(os.path.join(LIVE, f"{name}.json.gz")) as f:
        return json.load(f)


def by(x):
    return bytes.fromhex(x[2:] if x.startswith("0x") else x)


def table(name, **columns):
    con.register(name, pa.table({k: pa.array(v) for k, v in columns.items()}))


word = lambda text, i: int.from_bytes(by(text)[32 * i : 32 * i + 32], "big")
chains = {os.path.basename(p)[:-8]: load(os.path.basename(p)[:-8]) for p in glob.glob(os.path.join(LIVE, "evm*.json.gz"))}
logs = [(c, log) for c, d in chains.items() for log in d["logs"]]
table("evm_logs", chain=[c for c, _ in logs], topics=[b"".join(by(t) for t in log["topics"]) for _, log in logs], data=[by(log["data"]) for _, log in logs])
calls = [(c, x) for c, d in chains.items() for x in d["calls"]]
table("evm_transactions", chain=[c for c, _ in calls], input=[by(x["input"]) for _, x in calls])

evm, svm, bitcoin = load("evm"), load("svm"), load("bitcoin")
table("aave_reserves", asset=[a["asset"] for a in evm["aave"]], liquidity_rate=[str(word(a["reserve"], 2)) for a in evm["aave"]],
      liquidity_index=[str(word(a["reserve"], 1)) for a in evm["aave"]], last_update=[word(a["reserve"], 6) for a in evm["aave"]],
      block_time=[evm["timestamp"]] * len(evm["aave"]))
table("sol_instructions", data=[base58.b58decode(r["data"]) for r in svm["spl"] + load("token2022")["rows"]])
anchor = [(p, base58.b58decode(row)) for p, rows in svm["instructions"].items() for row in rows]
table("sol_anchor", program=[p for p, _ in anchor], kind=["instruction"] * len(anchor), data=[d for _, d in anchor])
paths = sorted(glob.glob(IDLS + "/*.json"))
table("idls", program=[os.path.basename(p)[:-5] for p in paths], idl=[open(p).read() for p in paths])
table("btc_outputs", script=[by(o["script"]) for o in bitcoin["outputs"]])
table("btc_tapscripts", script=[by(s) for s in bitcoin["tapscripts"]])
table("sui_coins", bcs=[base64.b64decode(c["bcs"]) for c in load("sui")["coins"]])
table("ibc_traces", trace=[d["trace"] for d in load("cosmos")["denoms"]])

failed = 0
recipes = sorted(glob.glob(os.path.join(REPO, "examples", "recipes", "*.sql")))
assert recipes
for path in recipes:
    name = os.path.basename(path)
    if not paths and "anchor" in name:
        print(f"skip {name}: run scripts/fetch_reference.sh")
        continue
    with open(path) as f:
        rows = con.execute(f.read()).fetchall()
    print(f"{len(rows):5} rows  {name}  e.g. {str(rows[0])[:90] if rows else ''}")
    failed += not rows
sys.exit(1 if failed else 0)
