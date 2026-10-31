#!/usr/bin/env python3
"""Coverage of real Anchor IDLs: does each parse, and how many of its items can we decode?

Usage: idl_corpus.py <directory of IDL .json files> [extension]. Exits non-zero if any IDL fails to
parse, or an item's discriminator does not match.
"""
import glob
import hashlib
import json
import os
import re
import sys
from collections import Counter

import duckdb

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO, "zig-out", "bin", "web3.duckdb_extension")
con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")


def snake(name):
    return re.sub(r"(?<=[a-z0-9_])([A-Z])", lambda m: "_" + m[1], name).lower() if "_" not in name else name.lower()


def disc(item, prefix, name):
    if "discriminator" in item:
        return bytes(item["discriminator"])
    if "discriminant" in item:  # Shank
        return bytes([item["discriminant"]["value"]])
    return hashlib.sha256(f"{prefix}:{name}".encode()).digest()[:8]


def why(fn, text, data):
    return con.execute(f"select web3_{fn}_error(s, ?) from (select ? s union all select null) where s is not null", [data, text]).fetchone()[0]


failed = 0
wrong_disc = Counter()
kinds = (("instructions", "anchor_decode_instruction", "global", snake), ("accounts", "anchor_decode_account", "account", str), ("events", "anchor_decode_event", "event", str))
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    with open(path) as f:
        text = f.read()
    idl = json.loads(text) if text.lstrip().startswith("{") else None
    if idl is None:
        continue
    name = os.path.basename(path)
    # All ones, since Shank discriminants are small and eight zero bytes can be a real instruction.
    probe = why("anchor_decode_instruction", text, b"\xff" * 8)
    if probe != "UnknownDiscriminator":
        print(f"{name:22} {len(text):>8}  IDL DOES NOT PARSE: {probe}")
        failed += 1
        continue
    parts = []
    reasons = Counter()
    for key, fn, prefix, norm in kinds:
        items = idl.get(key) or []
        ok = 0
        for item in items:
            # Long zeros: enough for any item, so errors are about the schema, not short input.
            reason = why(fn, text, disc(item, prefix, norm(item["name"])) + b"\0" * 20000)
            if reason == "UnknownDiscriminator":
                wrong_disc[name] += 1
                reasons["(no discriminator match) " + item["name"]] += 1
            elif reason == "UnsupportedType":
                reasons[item["name"]] += 1
            else:
                ok += 1
        parts.append(f"{key} {ok}/{len(items)}")
    print(f"{name:22} {len(text):>8}  " + ", ".join(parts))
    if reasons:
        print(f"{'':32} unsupported: {', '.join(list(reasons)[:8])}")
sys.exit(1 if failed or wrong_disc else 0)
