#!/usr/bin/env python3
"""Exact differential test of CLMM and lending math against the upstream sources, read as text.

Constants are parsed out of the published files, so nothing is retyped: Uniswap TickMath.sol,
Orca and Raydium tick_math.rs. Aave and Compound are integer ports of MathUtils.sol, WadRayMath.sol
and CToken.sol, where None means the contract would revert. Cetus has no source here yet and only
gets a cross-check against Raydium.

Usage: math_diff.py <directory of sources> [extension] [random cases]. Exits non-zero on any mismatch.
"""
import os
import random
import re
import sys

import duckdb
import pyarrow as pa

SRC = sys.argv[1]
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
CASES = int(sys.argv[3]) if len(sys.argv) > 3 else 200000

con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")
U256 = 2**256
failures = 0


def text(name):
    with open(os.path.join(SRC, name)) as f:
        return f.read()


def report(label, n, bad, first=None):
    global failures
    failures += bad
    print(f"{'FAIL' if bad else 'ok':>4}  {label}: {n - bad}/{n} match" + (f", first mismatch {first}" if bad else ""))


def column(sql):
    return [r[0] for r in con.execute(sql).fetchall()]


def table(name, **cols):
    con.register(name, pa.table(cols))


# Uniswap v3 TickMath.sol
uni = text("TickMath.sol")
first = re.search(r"absTick & 0x1 != 0 \? (0x[0-9a-f]+) : (0x[0-9a-f]+)", uni)
uni_steps = [(int(m, 16), int(k, 16)) for m, k in re.findall(r"if \(absTick & (0x[0-9a-f]+) != 0\) ratio = \(ratio \* (0x[0-9a-f]+)\) >> 128;", uni)]
assert len(uni_steps) == 19, len(uni_steps)


def uni_sqrt(tick):
    a = abs(tick)
    ratio = int(first[1], 16) if a & 1 else int(first[2], 16)
    for mask, k in uni_steps:
        if a & mask:
            ratio = (ratio * k) >> 128
    if tick > 0:
        ratio = (U256 - 1) // ratio
    return (ratio >> 32) + (1 if ratio % (1 << 32) else 0)


# Orca tick_math.rs
orca = text("orca_tick_math.rs")
pos = orca[orca.index("fn get_sqrt_price_positive_tick"):orca.index("fn get_sqrt_price_negative_tick")]
neg = orca[orca.index("fn get_sqrt_price_negative_tick"):orca.index("mod fuzz_tests")]
pos_init = [int(x) for x in re.findall(r"^\s+(\d{20,})$", pos, re.M)]
neg_init = [int(x) for x in re.findall(r"^\s+(\d{20,})$", neg, re.M)]
pos_steps = [(int(m), int(k)) for m, k in re.findall(r"if tick & (\d+) != 0 \{\s+ratio = mul_shift_96\(ratio, (\d+)\);", pos)]
neg_steps = [(int(m), int(k)) for m, k in re.findall(r"if abs_tick & (\d+) != 0 \{\s+ratio = \(ratio \* (\d+)\) >> 64", neg)]
assert len(pos_steps) == 18 and len(neg_steps) == 18 and len(pos_init) == 2 and len(neg_init) == 2


def orca_sqrt(tick):
    if tick >= 0:
        ratio = pos_init[0] if tick & 1 else pos_init[1]
        for mask, k in pos_steps:
            if tick & mask:
                ratio = (ratio * k) >> 96
        return ratio >> 32
    a = -tick
    ratio = neg_init[0] if a & 1 else neg_init[1]
    for mask, k in neg_steps:
        if a & mask:
            ratio = (ratio * k) >> 64
    return ratio


# Raydium tick_math.rs
ray = text("raydium_tick_math.rs")
body = ray[ray.index("pub fn get_sqrt_price_at_tick"):]
ray_first = int(re.search(r"U128\(\[(0x[0-9a-f]+), 0\]\)\s+\} else", body)[1], 16)
ray_steps = [(int(m, 16), int(k, 16)) for m, k in re.findall(r"if abs_tick & (0x[0-9a-f]+) != 0 \{\s+ratio = \(ratio \* U128\(\[(0x[0-9a-f]+), 0\]\)\) >> NUM_64", body)]
assert len(ray_steps) == 18, len(ray_steps)


def ray_sqrt(tick):
    a = abs(tick)
    ratio = ray_first if a & 1 else 1 << 64
    for mask, k in ray_steps:
        if a & mask:
            ratio = (ratio * k) >> 64
    if tick > 0:
        ratio = (2**128 - 1) // ratio
    return ratio


def sweep(label, fn, inverse, reference, bound, exclusive_top):
    ticks = list(range(-bound, bound + 1))
    got = column(f"select {fn}(i) from range({-bound}, {bound + 1}) t(i) order by i")
    want = [reference(t) for t in ticks]
    bad = [t for t, g, w in zip(ticks, got, want) if g is None or int(g) != w]
    report(f"{label} forward, every tick", len(ticks), len(bad), bad[:1])
    # The inverse must land on the tick, and one below its boundary on the tick before.
    top = -1 if exclusive_top else None
    table("sq", id=list(range(len(want[:top]))), s=[str(w) for w in want[:top]], below=[str(w - 1) for w in want[:top]])
    rows = con.execute(f"select {inverse}(s), {inverse}(below) from sq order by id").fetchall()
    bad = [t for t, (a, b) in zip(ticks, rows) if a != t or (t != -bound and b != t - 1)]
    report(f"{label} inverse, every boundary", len(rows), len(bad), bad[:1])


sweep("Uniswap", "web3_uni_sqrt_ratio_at_tick", "web3_uni_tick_at_sqrt_ratio", uni_sqrt, 887272, True)
sweep("Orca", "web3_orca_sqrt_price_from_tick", "web3_orca_tick_from_sqrt_price", orca_sqrt, 443636, False)
sweep("Raydium", "web3_raydium_sqrt_price_from_tick", "web3_raydium_tick_from_sqrt_price", ray_sqrt, 443636, True)

# Aave. rayMul, wadDiv and friends revert on overflow in WadRayMath.sol.
RAY, WAD, YEAR = 10**27, 10**18, 365 * 24 * 3600


def ray_mul(a, b):
    if a and a * b + RAY // 2 >= U256:
        return None
    return (a * b + RAY // 2) // RAY


def checked(x):
    return x if x is not None and x < U256 else None


def compounded_legacy(rate, dt):
    """aave-v3-core MathUtils.sol, v3.0 to v3.3."""
    if dt == 0:
        return RAY
    m1, m2 = dt - 1, dt - 2 if dt > 2 else 0
    two = ray_mul(rate, rate)
    if two is None:
        return None
    two //= YEAR * YEAR
    three = ray_mul(two, rate)
    if three is None:
        return None
    three //= YEAR
    a, b = dt * m1 * two, dt * m1 * m2 * three
    if a >= U256 or b >= U256:
        return None
    return checked(RAY + rate * dt // YEAR + a // 2 + b // 6)


def compounded(rate, dt):
    """aave-v3-origin MathUtils.sol, v3.4+. The final sum is unchecked; rayMul is not."""
    if dt == 0:
        return RAY
    x = rate * dt // YEAR
    inner = ray_mul(x, x // 6)
    if inner is None:
        return None
    outer = ray_mul(x, x // 2 + inner)
    if outer is None:
        return None
    return (RAY + x + outer) % U256


rng = random.Random(11)


def rand_rate():
    return rng.choice([0, 1, RAY // 100, 5 * RAY // 100, RAY, 1000 * RAY, rng.getrandbits(100), rng.randint(0, 10 * RAY), rng.getrandbits(128)])


def rand_dt():
    return rng.choice([0, 1, 2, 3, 12, 86400, YEAR, 10 * YEAR, rng.randint(0, 100 * YEAR), rng.getrandbits(40)])


rates = [rand_rate() for _ in range(CASES)]
dts = [rand_dt() for _ in range(CASES)]
table("ai", id=list(range(CASES)), r=[str(x) for x in rates], dt=dts)
for fn, ref in (("web3_aave_compounded_interest", compounded), ("web3_aave_compounded_interest_legacy", compounded_legacy)):
    got = column(f"select {fn}(r, 0, dt) from ai order by id")
    bad = [(r, d, g, ref(r, d)) for r, d, g in zip(rates, dts, got) if (None if g is None else int(g)) != ref(r, d)]
    report(fn, CASES, len(bad), bad[:1])

xs = [rng.getrandbits(rng.choice([64, 128, 200, 256])) for _ in range(CASES)]
ys = [rng.getrandbits(rng.choice([64, 128, 200])) + 1 for _ in range(CASES)]
table("bin", id=list(range(CASES)), a=[str(x) for x in xs], b=[str(y) for y in ys])
for fn, ref in (
    ("web3_ray_mul", ray_mul),
    ("web3_wad_mul", lambda a, b: None if a * b + WAD // 2 >= U256 else (a * b + WAD // 2) // WAD),
    ("web3_ray_div", lambda a, b: None if a * RAY + b // 2 >= U256 else (a * RAY + b // 2) // b),
    ("web3_wad_div", lambda a, b: None if a * WAD + b // 2 >= U256 else (a * WAD + b // 2) // b),
):
    got = column(f"select {fn}(a, b) from bin order by id")
    bad = [(a, b, g, ref(a, b)) for a, b, g in zip(xs, ys, got) if (None if g is None else int(g)) != ref(a, b)]
    report(fn, CASES, len(bad), bad[:1])


# Compound CToken.sol exchangeRateStoredInternal
def exchange(cash, borrows, reserves, supply, initial):
    if supply == 0:
        return initial
    total = cash + borrows - reserves
    if total < 0 or total >= U256 or total * 10**18 >= U256:
        return None
    return total * 10**18 // supply


rows = [(rng.getrandbits(100), rng.getrandbits(100), rng.getrandbits(90), rng.choice([0, 1, rng.getrandbits(90)]), 2 * 10**26) for _ in range(CASES)]
table("ct", id=list(range(CASES)), **{n: [str(r[i]) for r in rows] for i, n in enumerate("cbrsi")})
got = column("select web3_compound_exchange_rate(c, b, r, s, i) from ct order by id")
bad = [(r, g) for r, g in zip(rows, got) if (None if g is None else int(g)) != exchange(*r)]
report("web3_compound_exchange_rate", CASES, len(bad), bad[:1])

sys.exit(1 if failures else 0)
