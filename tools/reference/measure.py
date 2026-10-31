#!/usr/bin/env python3
"""The numbers docs/PERF.md quotes for DuckDB: worst-case rows, schema columns, and a 10M-row Parquet scan
against Python doing the same work. Python runs as a plain loop over fetched rows, which spares it the
cost of a real UDF, so the ratio understates the difference. Run on an idle machine.

Usage: measure.py [extension] [rows]
"""
import os
import random
import sys
import tempfile
import time

import duckdb
from eth_abi import decode as abi_decode
from eth_hash.auto import keccak

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
ROWS = int(sys.argv[2]) if len(sys.argv) > 2 else 10_000_000
PY_ROWS = min(ROWS, 300_000)  # Python gets a sample: its rate is the point, and a full run takes minutes.

con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")


def timed(sql, params=()):
    t = time.perf_counter()
    rows = con.execute(sql, list(params)).fetchall()
    timed.result = rows[0][0]
    return time.perf_counter() - t


# Base58 worst row: 1280 bytes with no leading zeros, the decoder's bound.
worst = random.Random(1).randbytes(1280)
text = con.execute("select web3_base58_encode(?)", [worst]).fetchone()[0]
con.execute("create table w as select ?::BLOB b, ?::VARCHAR t from range(2000)", [worst, text])
print(f"base58 encode 1280 B: {timed('select max(length(web3_base58_encode(b))) from w') / 2000 * 1e6:.0f} us/row")
print(f"base58 decode 1280 B: {timed('select max(octet_length(web3_base58_decode(t))) from w') / 2000 * 1e6:.0f} us/row")

# Schema column: constant, then four schemas alternating row by row. Same layout, so the decode work matches.
n = 2_000_000
con.execute(f"create table s as select i, ('{{a' || (i % 4) || ':u64,b:u64}}') sch, repeat('\\x01'::BLOB, 16) raw from range({n}) t(i)")
const = "'{a:u64,b:u64}'"
print(f"schema constant:    {n / timed(f'select count(web3_borsh_decode({const}, raw)) from s') / 1e6:.2f} M rows/s")
print(f"schema alternating: {n / timed('select count(web3_borsh_decode(sch, raw)) from s') / 1e6:.2f} M rows/s")
assert timed.result == n, "rows decoded to NULL, so the timing means nothing"

# End to end: decode Uniswap v3 Swap logs out of Parquet.
SIG = "Swap(address indexed sender,address indexed recipient,int256 amount0,int256 amount1,uint160 sqrtPriceX96,uint128 liquidity,int24 tick)"
with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "logs.parquet")
    r = """(hash(i) % 1000000)::UBIGINT"""
    topic0 = con.execute(f"select web3_evm_topic0('{SIG}')").fetchone()[0]
    con.execute(f"""copy (select ?::BLOB || repeat(repeat('\\x00'::BLOB, 12) || repeat('\\x11'::BLOB, 20), 2) topics,
        repeat('\\x00'::BLOB, 24) || unhex(printf('%016x', {r})) || repeat('\\x00'::BLOB, 24) || unhex(printf('%016x', {r} + 1)) ||
        repeat('\\x00'::BLOB, 24) || unhex(printf('%016x', {r} + 2)) || repeat('\\x00'::BLOB, 24) || unhex(printf('%016x', {r} + 3)) ||
        repeat('\\x00'::BLOB, 24) || unhex(printf('%016x', {r} + 4)) data
        from range({ROWS}) t(i)) to '{path}' (format parquet)""", [topic0])
    print(f"parquet: {ROWS} rows, {os.path.getsize(path) / 1048576:.0f} MB, {duckdb.__version__}, {os.cpu_count()} threads")
    native = timed(f"select count(web3_evm_decode_log('{SIG}', topics, data)) from '{path}'")
    assert timed.result == ROWS, "rows decoded to NULL, so the timing means nothing"
    print(f"native decode:       {ROWS / native / 1e6:.1f} M rows/s, {native:.1f} s")
    con.execute("set threads = 1")
    one = timed(f"select count(web3_evm_decode_log('{SIG}', topics, data)) from '{path}'")
    print(f"native decode, 1 thread: {ROWS / one / 1e6:.1f} M rows/s")
    con.execute(f"set threads = {os.cpu_count()}")
    hashed = timed(f"select count(web3_keccak256(data)) from '{path}'")
    print(f"native keccak:       {ROWS / hashed / 1e6:.1f} M rows/s")

    types = ["int256", "int256", "uint160", "uint128", "int24"]
    rows = [r[0] for r in con.execute(f"select data from '{path}' limit {PY_ROWS}").fetchall()]
    t = time.perf_counter()
    for d in rows:
        str(abi_decode(types, d))
    py = time.perf_counter() - t
    print(f"python eth_abi loop: {PY_ROWS / py / 1e6:.3f} M rows/s on {PY_ROWS} rows")
    t = time.perf_counter()
    for d in rows:
        keccak(d)
    print(f"python keccak loop:  {PY_ROWS / (time.perf_counter() - t) / 1e6:.3f} M rows/s on {PY_ROWS} rows")
    print(f"decode advantage:    {(ROWS / one) / (PY_ROWS / py):.0f}x per thread, {(ROWS / native) / (PY_ROWS / py):.0f}x on {os.cpu_count()} threads")
