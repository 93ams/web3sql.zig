#!/bin/sh
# Cross-builds the DuckDB extension for every platform into release/. Used by release.sh and CI.
set -eu

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
