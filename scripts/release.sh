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

rm -rf release
mkdir release
for t in x86_64-linux-gnu:linux_amd64 aarch64-linux-gnu:linux_arm64 \
    x86_64-linux-musl:linux_amd64_musl aarch64-linux-musl:linux_arm64_musl \
    x86_64-macos:osx_amd64 aarch64-macos:osx_arm64 \
    x86_64-windows-gnu:windows_amd64 aarch64-windows-gnu:windows_arm64; do
  target=${t%%:*}
  platform=${t##*:}
  zig build duckdb "-Dtarget=$target" -Doptimize=fast -p "release/out/$platform"
  # DuckDB finds the entry point from the name before the first dot, so this still loads.
  cp "release/out/$platform/bin/web3.duckdb_extension" "release/web3.$platform.duckdb_extension"
done
rm -rf release/out
cp zig-out/bin/web3_sql.wasm dist/bigquery_web3.js dist/bigquery_udfs.sql dist/snowflake_udfs.sql release/
(cd release && sha256sum -- * > SHA256SUMS)
