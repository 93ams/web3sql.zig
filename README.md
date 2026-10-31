# web3sql.zig

Blockchain decoding and high-precision DeFi math as SQL functions, with no dependencies: a native DuckDB extension, and a WebAssembly bundle for BigQuery and Snowflake.

```sql
LOAD 'web3.duckdb_extension';

SELECT web3_hex_encode(web3_keccak256('Transfer(address,address,uint256)'::BLOB));
SELECT web3_btc_address('bitcoin', web3_hex_decode(vout_script_pub_key)) FROM 'test_data/bitcoin_txs.parquet';
SELECT web3_uni_tick_to_price(201000, 6, 18, 8);
```

A malformed row gives `NULL`, so a bad record never aborts a scan, and `<name>_error` says why. Every function is listed in [docs/FUNCTIONS.md](docs/FUNCTIONS.md). Limits, JSON shapes and troubleshooting are in [docs/LIMITS.md](docs/LIMITS.md).

> [!WARNING]
> Pre-release. Everything here is tested on generated data and against reference implementations, not on real chain data, and neither warehouse has been tried live. [docs/HANDOFF.md](docs/HANDOFF.md) lists what is left.

## Build

Requires Zig 0.17.0.

| Command | Output |
|---|---|
| `zig build test` | Unit tests |
| `zig build duckdb` | `zig-out/bin/web3.duckdb_extension` |
| `zig build wasm` | `web3_sql.wasm`, plus `dist/` deployment scripts |
| `zig build wasm-size` | Fails at 250 KB or more |
| `zig build docs` | Regenerates `docs/FUNCTIONS.md` |
| `sh scripts/release.sh` | Runs every gate, then writes all platforms and checksums to `release/` |
| `zig build bench` | Throughput numbers, see [docs/PERF.md](docs/PERF.md) |

Pick features at compile time:

```sh
zig build wasm -Dchains=evm,svm -Dprotocols=clmm,tokens
```

`-Dchains` takes `evm,svm,move,utxo,cosmos`, and `-Dprotocols` takes `clmm,tokens,lending`. Both also accept `all` (the default) or `none`. An unknown name is a build error.

> [!NOTE]
> On WSL with the repository under `/mnt/c`, set `ZIG_LOCAL_CACHE_DIR` to a Linux path such as `~/.cache/web3sql-zig/main`. The default in-tree cache hangs there. The Makefile does this for you.

For a portable extension, name the target: `-Dtarget=x86_64-linux-gnu`. The default build uses your CPU's features, and the result may not run elsewhere.

## Using the extension

DuckDB 1.5 and 2.0 are tested. Extensions built here are unsigned, so start DuckDB with `-unsigned` or the `allow_unsigned_extensions` setting. `SELECT web3_version()` reports the build.

| Platform | Status |
|---|---|
| `linux_amd64`, `linux_arm64`, `windows_amd64` | Full suite passes on the release artifact (`linux_arm64` under emulation) |
| `linux_amd64_musl`, `linux_arm64_musl`, `windows_arm64`, `osx_amd64`, `osx_arm64` | Builds, never loaded |

Keep the file name starting with `web3`, because DuckDB derives the entry point from it. `release/web3.linux_amd64.duckdb_extension` loads, and `linux_amd64.duckdb_extension` does not.

[examples/recipes/](examples/recipes/) has queries for each chain, each tested against real mainnet data.

## Deploying to warehouses

`zig build wasm` writes these files to `dist/`:

| File | Use |
|---|---|
| `bigquery_udfs.sql` | Replace `__WEB3_DATASET__` and `__WEB3_GCS_URI__`, then run |
| `bigquery_web3.js` | Upload to GCS for the 5 largest functions. The other 77 need no bucket |
| `snowflake_udfs.sql` | Run one `CREATE` and a test `SELECT` first |

> [!WARNING]
> Neither warehouse has been tested live. The generated JavaScript is only exercised in Node.
> - **BigQuery** limits inline code to 32 KB. Five functions exceed it: `web3_borsh_decode` and the `web3_evm_decode_log` and `web3_evm_decode_calldata` families.
> - **Snowflake** does not document WebAssembly in JavaScript UDFs, so check that it works on your account first. Each function embeds only its own code, 40 KB at most.

Warehouse UDFs handle up to about 60 KB per row, covering arguments and output together. Anything larger returns `NULL`. BIGINT arguments are carried as floats, so they must stay under 2^53.

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). `src/core` holds math, encodings and crypto; `src/chains` and `src/protocols` are the opt-in layers; `src/targets` holds the function catalogue that DuckDB, WASM and the docs all read.

## Tests

```sh
uv venv && uv pip install -r scripts/requirements-dev.txt
source .venv/bin/activate
make test     # unit, flag, DuckDB and WASM
make verify   # also every reference harness; downloads reference sources once
```

`scripts/test_duckdb.py` runs every catalogue function and compares it with an independent reference library. It fails if any registered function has no check. See [SECURITY.md](SECURITY.md) for how decoders are hardened.

## License

MIT, see [LICENSE](LICENSE). The DuckDB headers in `src/targets/duckdb_ext/vendor/` are also MIT, copyright Stichting DuckDB Foundation.
