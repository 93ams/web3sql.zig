#!/bin/sh
# Builds every release artifact into release/, after the tests pass. Run locally or from release.yml.
# Set PYTHON to an interpreter with scripts/requirements-dev.txt installed.
set -eu
PYTHON=${PYTHON:-python}

zig fmt --check src bench tools build.zig
zig build test
zig build test -Dchains=none -Dprotocols=none
sh scripts/req_coverage.sh
zig build duckdb
"$PYTHON" scripts/test_duckdb.py
zig build wasm
zig build wasm-size
node scripts/test_wasm.mjs
node scripts/test_snowflake.mjs

sh scripts/build_artifacts.sh
cp zig-out/bin/web3_sql.wasm dist/bigquery_web3.js dist/bigquery_udfs.sql dist/snowflake_udfs.sql release/
(cd release && sha256sum -- * > SHA256SUMS)
