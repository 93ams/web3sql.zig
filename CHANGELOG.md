# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/). Versions follow semver, with the rules in [CONTRIBUTING.md](CONTRIBUTING.md).

## Unreleased

### Added

- `<name>_error` twin of every DuckDB function, naming why a row is `NULL`.
- `web3_version()`.
- Anchor IDL `hashMap`, `bTreeMap`, `hashSet`, `bTreeSet` and Shank `discriminant`.
- `scripts/release.sh`, which runs every gate and then builds eight platforms with checksums.
- `make verify`, plus reference harnesses in `tools/reference/`.
- `docs/LIMITS.md`, `docs/HANDOFF.md`, `CONTRIBUTING.md`.
- MIT license.
- `web3_anchor_decode_account_raw(idl, name, data)` for accounts with no Anchor discriminator, such as Metaplex's.
- `web3_spl_decode` covers every SPL Token instruction, not 4 of them. Token-2022 extensions and Batch are still `NULL`.
- `tools/reference/live_diff.py` replays a pinned sample of mainnet data in `make verify`.

### Changed

- **Breaking:** `web3_erc_decode_json`, `web3_spl_decode_json` and `web3_btc_{script,runestone,inscription}_json` lose their `_json` suffix.
- **Breaking:** `web3_uni_amount0_delta` and `web3_uni_amount1_delta` take `round_up` as BOOLEAN.
- `web3_i256_from_bytes` takes up to 32 bytes and sign-extends.
- Each warehouse function embeds only its own code: Snowflake bodies are 40 KB at most, not 294 KB, and 77 of 82 BigQuery functions need no GCS bucket.
- `web3_anchor_decode_event` accepts `emit_cpi` instruction data.
- `web3_anchor_decode_instruction` and `web3_anchor_decode_event` ignore trailing bytes, as Anchor's handlers and client do.

- DuckDB rows whose result exceeds 64 KB retry on a heap buffer of up to 16 MB, instead of returning `NULL`.
- Non-constant schema columns cache up to 16 schemas per chunk, failures included.
- Anchor IDL type lookup is a hash map, not a linear scan per reference.
- Release artifacts are named `web3.<platform>.duckdb_extension`, because DuckDB derives the entry point from the file name. `linux_amd64_musl` and `linux_arm64_musl` are new.
- Workflow actions are pinned to commit SHAs.

## 0.1.0

First implementation of everything in `prd.md`. Never published.

## 0.0.1

Initial import.
