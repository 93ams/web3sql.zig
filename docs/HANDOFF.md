# Handoff

Everything one machine could prove is proven by `make verify`. This is the rest: each item needs an account, hardware, real data, or a person. They are ordered so that a failure early on saves the work after it.

**First, on any Linux or WSL host with Zig 0.17.0, Python and Node:**

```sh
uv venv && uv pip install -r scripts/requirements-dev.txt
source .venv/bin/activate
make verify               # about 7 minutes once sources are downloaded
sh scripts/release.sh     # builds release/ with SHA256SUMS
```

## What already has evidence

| Claim | Evidence | How to repeat |
|---|---|---|
| EVM decoding | 100,000 generated cases identical to `eth_abi`. On 100,000 mutated cases no dirty value accepted | `tools/reference/evm_diff.py` |
| Borsh, BCS | 20,000 generated schemas each, encoded from the specifications | `tools/reference/schema_diff.py` |
| Bitcoin envelopes, runestones | 200,000 generated and mutated scripts, no disagreement with a Python port of `ord` | `tools/reference/utxo_diff.py` |
| Tick math | Every tick matches Uniswap, Orca and Raydium source, forward and inverse | `tools/reference/math_diff.py` |
| Lending math | 200,000 cases each against constants parsed from Aave and Compound source | `tools/reference/math_diff.py` |
| Anchor IDLs | Every instruction and event in 8 public IDLs resolves against zero-filled data, and instruction discriminators match | `tools/reference/idl_corpus.py` |
| Real SDKs | 40,000 BCS values encoded by `@mysten/bcs`, 40,000 Bech32 addresses and typos from `cosmjs` and 4,000 IBC denoms, with no mismatch. All 164 generated warehouse statements parse under `sqlglot` | `tools/reference/sdk_diff.py` |
| Mainnet sample | Pinned real data from 11 chains and blocks back to 2018, compared with `eth_abi`, on-chain contract views and each chain's own node. See the table below | `tools/reference/live_diff.py`, part of `make verify` |
| Native and WASM agree | 99,626 mutated calls, 46% of them `NULL`, against the bundle and each per-function module. `make verify` runs 3 mutants per call; this figure used 25 | `tools/reference/wasm_diff.py` |
| Warehouse JavaScript | Every Snowflake body and inline BigQuery body runs alone in a stripped V8 context and matches DuckDB | `scripts/test_wasm.mjs`, `scripts/test_snowflake.mjs` |
| Stability | One hour per fuzz lane, about 1.3 billion runs, no crash. Decoders changed since then got 30 more minutes each, clean: 237 million runs on SVM, then 343 million on protocols with Token-2022 on the final tree. The 30-minute soak on the Token-2022 build ran 448 scans with RSS flat at about 176 to 194 MB, two samples near 208 MB, and one 274 MB sample as the last scans ended | `.github/workflows/nightly-fuzz.yml`, `make soak` |
| Hosts | Full suite on the final `linux_amd64` (Debian bullseye), `linux_arm64` (emulated) and `windows_amd64` release artifacts, and on DuckDB 1.5.6 and 2.0.0. Unit tests on musl, and Alpine's loader resolves both musl artifacts | `scripts/test_duckdb.py` |
| CI readiness | `actionlint` clean, every pinned action SHA exists upstream, and the Linux jobs pass from a clean copy of what git tracks. GitHub ran all 31 `ci.yml` jobs and all five one-hour fuzz lanes green | `make verify` |

Mainnet sample, captured by `tools/reference/live_capture.py` into `tools/reference/live/`:

| Data | Compared with | Result |
|---|---|---|
| 10,817 logs and 2,682 calls from Ethereum, Arbitrum, Base, Optimism, Polygon and BSC, plus Ethereum in 2018, 2021 and 2023. Includes ERC-1155, ERC-4337 `handleOps`, Safe and `aggregate3` | `eth_abi` | All agree. 261 logs are `TopicCount`: same event hash, different `indexed` fields, such as ERC-721 against the ERC-20 signature |
| 14 contract creations | Addresses in receipts | All agree |
| Aave v3 income and debt, 6 reserves | `getReserveNormalizedIncome` and `getReserveNormalizedVariableDebt` at the same block | All 12 exact |
| Compound cUSDC | `exchangeRateStored` | Exact |
| Uniswap, Orca, Raydium and Cetus ticks | Each pool's own stored tick and sqrt price | All agree, or sit exactly on a boundary while moving down, where the pool stores `tick - 1` |
| 1,844 comparisons on SPL instructions, 1,539 on Token-2022 including transfer fees, pointers and token metadata | The Solana node's `jsonParsed` | All agree |
| Metaplex `Metadata` accounts | The decoded mint re-derives the account's address | All agree |
| 3,868 Bitcoin script checks | mempool.space type and address | All agree. One `anchor` output is `witness_unknown` here |
| 202 OP_RETURN, 162 tapscripts | Python port of `ord` | All agree |
| Aptos resources, Sui coins | The node's own JSON for the same object | All agree |
| 120 IBC denoms | Hashes computed by an Osmosis node | All agree |

Anchor rows from 7 programs decode, with no independent answer to check values against. Nine pump `buy` rows stay `NULL` because the chain's clients send fewer arguments than the IDL declares.

This found four real gaps that generated data never showed: 23 of 27 SPL instructions were unsupported, `emit_cpi` events did not decode, trailing bytes made stale IDLs `NULL`, and Metaplex accounts had no route at all. A wider run kept out of the repository compared 67,336 logs, 21,419 calls, 23,328 Bitcoin script checks, 1,061 runestones and 580 inscriptions with no mismatch: `LIVE_SCALE=15 LIVE_DIR=<dir> python tools/reference/live_capture.py`, then `LIVE_DIR=<dir>` on `live_diff.py`. That is still not millions, and those rows passed without showing a new bug, so H6 stays necessary.

Every query in `examples/recipes/` runs against this sample in `make verify` and CI.

## H1: GitHub

```sh
git push -u origin main
```

Do not push a tag until you mean to release: `release.yml` publishes a public GitHub release for any `v*` tag. Tag the commit you mean to release, and only after this job is green.

`ci.yml` passes on GitHub on Linux, macOS and Windows, and all five `nightly-fuzz.yml` lanes finished an hour each. What is left is the private reporting that `SECURITY.md` promises:

```sh
gh api -X PUT repos/93ams/web3sql.zig/private-vulnerability-reporting
```

**Done when:** `gh api repos/93ams/web3sql.zig/private-vulnerability-reporting` says `enabled: true`.

## H2: macOS

`ci.yml`'s `artifact-test` job cross-builds the release files on Linux, then runs `scripts/test_duckdb.py` on each one's own system, including `macos-15-intel`. This also tests C++ exceptions crossing Zig frames, confirmed so far only on Linux and Windows.

**Done when:** the `osx_arm64` and `osx_amd64` rows are green. Those are GitHub's machines, so a test on a real Mac remains worthwhile before 1.0.

## H3: Other artifacts that have never been loaded

- `linux_amd64_musl`, `linux_arm64_musl`: `ci.yml`'s `artifact-test-musl` job loads each release file with DuckDB's musl CLI in Alpine and checks one Keccak digest. That shows it loads and runs, not the full suite.
- `windows_arm64`: `solders` and `pyarrow` have no Windows on Arm wheels, so `scripts/test_duckdb.py` cannot run there. `ci.yml`'s `community` job builds with the release flags on `windows-11-arm` and runs `test/sql/web3.test` instead. The shipped file itself is not the one loaded.
- The newest DuckDB pre-release: the `duckdb-prerelease` job in `nightly-fuzz.yml` runs `scripts/test_duckdb.py` on it.

**Done when:** each job is green, or the README marks that platform unsupported.

## H4: BigQuery

Needs a GCP project (ROADMAP D3). Each function now carries only its own code, so 77 of the 82 are inline and need no bucket. Five exceed the 32 KB inline limit and need one: `web3_borsh_decode` and the four `web3_evm_decode_log` and `web3_evm_decode_calldata` functions.

```sh
gsutil cp dist/bigquery_web3.js gs://<bucket>/web3/bigquery_web3.js
sed -e 's/__WEB3_DATASET__/<dataset>/g' -e 's#__WEB3_GCS_URI__#gs://<bucket>/web3/bigquery_web3.js#g' \
    dist/bigquery_udfs.sql | bq query --use_legacy_sql=false
```

Then:

1. Run `dist/duckdb_calls.json` through it, comparing each result, and skip functions not exported.
2. Run a million-row query with malformed rows mixed in. No query may fail.
3. Record cold start, per-row latency and slot usage. V8 here gives about 1 ms cold start and 2 to 4 microseconds per warm row for an inline function.

**Done when:** every replayed call matches and the million-row query finishes.

## H5: Snowflake

Needs an account. Size is no longer the question: the largest of the 82 bodies is 40 KB against a recommended 100 KB, and the script is 1 MB. The open question is whether Snowflake's JavaScript sandbox exposes `WebAssembly` at all, which its documentation does not say. Ask it first, with nothing of ours involved:

```sql
CREATE OR REPLACE FUNCTION web3_probe() RETURNS VARCHAR LANGUAGE JAVASCRIPT AS $$ return typeof WebAssembly; $$;
SELECT web3_probe();  -- must be 'object'
-- Then the web3_version and web3_keccak256 CREATEs from dist/snowflake_udfs.sql, and:
SELECT web3_version(), web3_keccak256(TO_BINARY('', 'HEX'));
```

If the probe says `undefined`, JavaScript UDFs cannot work, and generated bodies fail with `web3sql: this sandbox has no WebAssembly`. The next thing to try is a Java UDF that runs `web3_sql.wasm` on Chicory, a pure-Java WebAssembly runtime, imported from a stage. That design is untested. Snowflake's Python channel listed no WebAssembly runtime in the part of its index read so far.

**Done when:** same as H4.

## H6: Real data

The most important item, because non-standard encodings are what generated data cannot cover. For each chain, take millions of real rows, decode them here and with an independent decoder, and report match rate and `NULL` rate. Then group every `NULL` by its cause:

```sql
SELECT web3_evm_decode_log_error(sig, topics, data) AS why, count(*) FROM logs
WHERE web3_evm_decode_log(sig, topics, data) IS NULL GROUP BY why ORDER BY 2 DESC;
```

| Chain | Compare with | Look for |
|---|---|---|
| EVM | `eth_abi`, or a decoded dataset such as Dune | Proxy events with wrong signatures, non-standard padding, ERC-721 logs that look like ERC-20 |
| Solana | Program-specific decoders, Anchor's TS client | IDL versions against program versions, truncated log lines, real Raydium and Orca swaps, generic or `coption` IDLs, Token-2022 extension payloads returned raw |
| Bitcoin | A real `ord` index | Inscriptions and runestones at scale, cenotaphs |
| Sui, Aptos | SDK decoders on real transactions | Type tags, enums |
| Cosmos | `cosmjs`, chain explorers | IBC traces |
| Lending | On-chain `getReserveNormalizedIncome` calls | Which Aave version each market ran, since v3.4 changed the compounded formula |

The pinned sample in the evidence table is a head start, and `tools/reference/live_capture.py` shows how to fetch from each chain. Also worth doing: replace the Python ports with the real thing. `utxo_diff.py` uses a port of `ord`, so a Rust harness over the `ordinals` crate is stronger. `@uniswap/v3-sdk` and `@aave/math-utils` would likewise add to checks written against sources.

**Done when:** match rate is reported per chain, and every `NULL` class is explained or fixed. Each bug found gets a regression test.

## H7: Signed distribution

Extensions are unsigned, which many deployments forbid. Community CI installs no Zig, but the listed `maxmind` extension shows the route: it runs `make configure_ci`, `make release` and `make test_release` from the extension's own Makefile. This repository follows that contract, `scripts/install_zig.py` installs a hash-pinned Zig, and `ci.yml`'s `community` job runs the same targets.

Once that job is green, submit `.github/duckdb-community/description.yml` as `extensions/web3/description.yml` with `repo.ref` set. Only the job's targets are tested here: their Linux Docker images and the signing step run only on their side.

## H8: Security review

Scope: `src/duckdb_main.zig`, `src/wasm_main.zig`, and the decoders under `src/chains/`. The threat model is in `SECURITY.md`. A crash takes down the host database. An automated read of those boundaries found no memory bug, crash or data race, which does not replace this: it never ran the code, and it was not independent of the tooling that wrote it.

## H9: Dedicated-hardware benchmarks

```sh
zig build bench
python tools/reference/measure.py release/web3.linux_amd64.duckdb_extension
```

The WSL2 host used so far varies by about 25% and exposes no instruction counters, so there is no automated regression check. Add one here.

## H10: Outside users, then 1.0

Run real pipelines with people who did not write this. Before freezing names, review the candidates in `ROADMAP.md`.

## Skipped locally

Tools that were not installed here, because they run third-party code. Each is a small, optional step on a machine where that is fine.

| Step | Needs | Command |
|---|---|---|
| `ord` reference | Rust crates `ordinals`, `bitcoin` | See H6 |
