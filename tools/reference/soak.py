#!/usr/bin/env python3
"""Soak test: repeated multi-threaded scans over every allocating path, with RSS sampled.

Usage: soak.py [extension] [seconds]. Fails if RSS keeps growing after warm-up.
"""
import os
import sys
import threading
import time

import duckdb

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 1800
WARMUP = min(120, SECONDS // 4)

with open(os.path.join(REPO, "src", "chains", "svm", "testdata", "external.json")) as f:
    IDL = f.read().replace("'", "''")

con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")
con.execute("SET threads = 8")
con.execute(f"create table idls as select i, '{IDL}' || repeat(' ', i) s from range(32) t(i)")
con.execute("create table rows as select i, printf('%016d', i)::blob b, i % 32 k from range(2000000) t(i)")

QUERIES = [
    # Interleaved non-constant schemas, past the cache size, and failures.
    "select count(web3_anchor_decode_instruction(s, b)) from rows join idls on rows.k = idls.i",
    "select count(web3_borsh_decode(case when i % 3 = 0 then 'nope' else '{a:u64,b:u64}' end, b)) from rows",
    "select count(web3_borsh_decode('{a:u64,b:u64}', b)) from rows",
    # Constant schema through bind, rebound by every query.
    "select count(web3_evm_decode_log('event T(uint256 a)', b, b)) from rows",
    # The heap retry, including rows too large for it.
    "select count(web3_hex_encode(repeat(b, 8000))) from rows where i % 2000 = 0",
    "select count(web3_hex_encode(repeat(b, 1000000))) from rows where i % 200000 = 0",
    # Error twins and plain functions.
    "select count(web3_hex_decode_error(b::varchar)) from rows",
    "select count(web3_keccak256(b)) from rows",
]


def rss():
    with open("/proc/self/statm") as f:
        return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") // 2**20


samples = []
stop = time.time() + SECONDS
errors = []
scans = [0]


def worker():
    c = con.cursor()
    while time.time() < stop:
        for q in QUERIES:
            try:
                c.execute(q).fetchall()
                scans[0] += 1
            except Exception as e:
                errors.append((q, e))
                return


threads = [threading.Thread(target=worker) for _ in range(4)]
start = time.time()
for t in threads:
    t.start()
while any(t.is_alive() for t in threads):
    time.sleep(10)
    samples.append((time.time() - start, rss()))
    print(f"{samples[-1][0]:7.0f}s  rss {samples[-1][1]:6d} MB  scans {scans[0]}", flush=True)
for t in threads:
    t.join()

if errors:
    sys.exit(f"query failed: {errors[0]}")
settled = [m for t, m in samples if t > WARMUP]
half = len(settled) // 2
first, last = max(settled[:half]), max(settled[half:])
print(f"peak after warm-up {first} MB, peak in the second half {last} MB, {scans[0]} scans")
if last > first * 1.25 + 256:
    sys.exit("RSS kept growing after warm-up")
