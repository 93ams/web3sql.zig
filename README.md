# web3sql.zig

Blockchain decoding and high-precision DeFi math as SQL functions, with no dependencies: a native DuckDB extension, and a WebAssembly bundle for BigQuery and Snowflake.

```sql
LOAD 'web3.duckdb_extension';

SELECT web3_hex_encode(web3_keccak256('Transfer(address,address,uint256)'::BLOB));
SELECT web3_btc_address('bitcoin', web3_hex_decode(vout_script_pub_key)) FROM 'test_data/bitcoin_txs.parquet';
SELECT web3_uni_tick_to_price(201000, 6, 18, 8);
```

A malformed row gives `NULL`, so a bad record never aborts a scan. Every function is listed in [docs/FUNCTIONS.md](docs/FUNCTIONS.md).

## Build

Requires Zig 0.17.0.

| Command | Output |
|---|---|
| `zig build test` | Unit tests |
| `zig build duckdb` | `zig-out/bin/web3.duckdb_extension` |
| `zig build wasm` | `web3_sql.wasm`, plus `dist/` deployment scripts |
| `zig build wasm-size` | Fails at 250 KB or more |
| `zig build docs` | Regenerates `docs/FUNCTIONS.md` |
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

DuckDB 1.5 and 2.0 are tested. Extensions built here are unsigned, so start DuckDB with `-unsigned` or the `allow_unsigned_extensions` setting.

## Deploying to warehouses

`zig build wasm` writes these files to `dist/`:

| File | Use |
|---|---|
| `bigquery_web3.js` | Upload to GCS |
| `bigquery_udfs.sql` | Replace `__WEB3_DATASET__` and `__WEB3_GCS_URI__`, then run |
| `snowflake_udfs.sql` | Run one `CREATE` and a test `SELECT` first |

> [!WARNING]
> Neither warehouse has been tested live. The generated JavaScript is only exercised in Node.
> - **BigQuery** limits inline code to 32 KB, so the bundle has to live in a GCS bucket.
> - **Snowflake** recommends UDF bodies under 100 KB and does not document WebAssembly support. Each generated UDF embeds the whole bundle, so check that it works on your account first.

Warehouse UDFs handle up to about 60 KB per row, covering arguments and output together. Anything larger returns `NULL`. BIGINT arguments are carried as floats, so they must stay under 2^53.

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). `src/core` holds math, encodings and crypto; `src/chains` and `src/protocols` are the opt-in layers; `src/targets` holds the function catalogue that DuckDB, WASM and the docs all read.

## Tests

```sh
uv venv && uv pip install -r scripts/requirements-dev.txt
source .venv/bin/activate
make test
```

`scripts/test_duckdb.py` runs every catalogue function and compares it with an independent reference library. It fails if any registered function has no check. See [SECURITY.md](SECURITY.md) for how decoders are hardened.
