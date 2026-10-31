# SQL recipes

Each file is one query you can adapt. `scripts/test_recipes.py` runs them all against the mainnet sample in `tools/reference/live/`, so they stay correct. Its tables use these columns; rename them to match yours.

| Table | Columns |
|---|---|
| `evm_logs` | `chain`, `topics` (all topics concatenated, 32 bytes each), `data` |
| `evm_transactions` | `chain`, `input` |
| `sol_instructions` | `data` (SPL Token and Token-2022 instruction data) |
| `sol_anchor` | `program`, `kind` (`instruction`, `event` or `account`), `data` |
| `btc_outputs` | `script` (the scriptPubKey) |
| `btc_tapscripts` | `script` |
| `aave_reserves` | `asset`, `liquidity_rate`, `liquidity_index`, `last_update`, `block_time` |
| `sui_coins` | `bcs` |
| `ibc_traces` | `trace` |
| `idls` | `program`, `idl` (the Anchor IDL as JSON text) |

If `topics` is stored as separate columns, join them first: `coalesce(topic0, ''::BLOB) || coalesce(topic1, ''::BLOB) || ...`. From hex text, use `web3_hex_decode`.

Numbers above 2^53 come out of JSON as strings, so cast them with `::HUGEINT` or keep them as text. `->>` always gives text.

Decoders return `NULL` for a row that does not match, so filter with `IS NOT NULL` as these recipes do. To see why rows fail, see `evm_null_audit.sql`.
