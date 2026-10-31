# Limits, output shapes and NULLs

## Why a row is NULL

A malformed row gives `NULL`, so one bad record cannot abort a scan. To see why, ask its `_error` twin. Every DuckDB function has one, taking the same arguments and returning `NULL` for a good row or the error name for a bad one.

```sql
SELECT web3_evm_decode_log_error(sig, topics, data) AS why, count(*)
FROM logs
WHERE web3_evm_decode_log(sig, topics, data) IS NULL
GROUP BY why;
```

A `NULL` input gives `NULL`, and its twin gives `NULL` too, because nothing failed. The twins are DuckDB only.

| Error | Usual cause |
|---|---|
| `BufferTooSmall` | The result exceeds the limit below |
| `InvalidValue` | ABI data with non-zero bytes in a field's unused high bytes, often the wrong signature for this row |
| `TopicMismatch`, `TopicCount`, `SelectorMismatch` | The row is a different event or function from the signature given |
| `UnknownDiscriminator` | An Anchor row from an item the IDL does not list. For Metaplex and other accounts with no Anchor discriminator, use `web3_anchor_decode_account_raw`. For `emit_cpi` events in instruction data, use `web3_anchor_decode_event` |
| `TrailingBytes` | `web3_borsh_decode` or `web3_bcs_decode` data longer than the schema, usually a wrong schema. `web3_anchor_decode_*` ignores trailing bytes, as Anchor does, so a program that added fields still decodes |
| `UnexpectedEndOfBuffer` | Data shorter than the schema. For Anchor, often a stale IDL: pump's IDL declares `buy` arguments that many mainnet clients omit |
| `UnknownInstruction` | A Token-2022 extension or Batch instruction, which `web3_spl_decode` does not cover |
| `UnknownAccount` | `web3_anchor_decode_account_raw` was given a name the IDL does not list |
| `ZeroSizedElement` | A Borsh vector or array of a type that occupies no bytes |
| `ResultOutOfRange`, `ArgumentOutOfRange` | A value does not fit the SQL integer type, or an argument does not fit the function's range |

A constant schema that does not parse is a **bind error**, not `NULL`: it is a mistake in the query, not in the data. A schema read from a column gives `NULL` for that row, since bind cannot see it.

## Limits

| Limit | DuckDB | WASM (BigQuery, Snowflake) |
|---|---|---|
| Result per row | 16 MB | About 60 KB, arguments and result together |
| Schema | 4 MB from a column; no limit as a constant | Fits the 60 KB above, and parses within 32 KB |
| Integer arguments | Full BIGINT | Under 2^53, as they travel as floats |
| Functions | All | Those not marked *DuckDB only* in [FUNCTIONS.md](FUNCTIONS.md) |

Results above 64 KB in DuckDB use a heap buffer, so they cost more than ordinary rows. `web3_anchor_decode_event_log` shares that buffer between decoded bytes and output, so its limit is 8 MB of decoded log. Limits that apply everywhere:

| Input | Limit |
|---|---|
| Base58 | 1280 decoded bytes, 1750 characters. A worst-case row takes about 200 microseconds |
| Bech32 | 90 characters, prefix up to 83 |
| Decimal strings | 78 digits (u256) |
| EVM ABI type nesting | 16 |
| Borsh depth | 64 |
| BCS depth | 32 |
| Anchor IDL | JSON depth 64, type depth 128 |
| Solana PDA | 16 seeds of up to 32 bytes |
| Uniswap ticks | ±887272 |
| Orca, Raydium, Cetus ticks | ±443636 |

## Known behaviour

- **A NUL byte in a constant schema** ends it: `'u8' || chr(0) || 'junk'` is read as `u8`, because DuckDB's C API returns constants as C strings. The same text from a column gives `NULL`.
- **EVM ABI strictness.** A value-changing dirty byte is rejected. Missing or non-zero tail padding, trailing bytes and overlapping offsets within the data are accepted, because real contracts emit them. This makes the decoder more tolerant than `eth_abi`, by design.
- **Zero-sized elements.** A Borsh vector or array of them is rejected, or a short row could describe billions of elements. Rust's `borsh` does the same for vectors but not fixed arrays. This decoder rejects both, or `[[u8;0];4294967295]` would spin without reading input.
- **Base58 in JSON.** Solana public keys render as Base58, which costs far more than hex on hot paths.
- **Unsupported IDL features.** Generics and `coption` do not parse. None of the public IDLs surveyed use generics.
- **Shank accounts.** Metaplex instructions decode, but its accounts start with a `key` enum, not an Anchor discriminator, so `web3_anchor_decode_account` gives `UnknownDiscriminator` on them. Decode them with `web3_borsh_decode` instead.
- **Ordinals.** Only the first envelope of a script, and only the content type tag, are surfaced.
- **Cetus.** Tick math is not verified against upstream to the last digit. See `tools/reference/math_diff.py`.

## JSON output

These rules apply to every function returning JSON.

| Value | Renders as |
|---|---|
| Integer up to 2^53 in magnitude | JSON number |
| Larger integer | Decimal string, because many JSON parsers lose precision above 2^53 |
| Bytes | `0x`-prefixed lowercase hex, `0x` when empty |
| EVM address | `0x`-prefixed lowercase hex, not EIP-55 |
| Solana public key | Base58 |
| Move address | `0x`-prefixed, 32 bytes |
| Borsh `f32`, `f64` | JSON number, `"Infinity"` and `"-Infinity"` as strings. NaN is rejected |
| Option `None` | `null` |

Function shapes:

| Function | Shape |
|---|---|
| `web3_evm_decode_log`, `web3_evm_decode_log_abi` | `{"<param>": value, ...}`. An unnamed parameter uses its position as the key |
| `web3_evm_decode_calldata`, `web3_evm_decode_calldata_abi` | The same. Tuples are objects, with the same key rule |
| `web3_borsh_decode` | The value itself. Records are objects |
| `web3_bcs_decode` | The value itself. Records are objects, tuples are arrays, an enum is `{"variant":i,"value":v}`, unit and empty records are `null` |
| `web3_anchor_decode_*` | `{"name":"<item>","data":{...}}` |
| `web3_btc_script` | `{"type":"p2pkh","address":"..."}` |
| `web3_btc_runestone` | `{"fields":[[tag,value],...],"body":[...]}` |
| `web3_btc_inscription` | `{"content_type":"text/plain","body":"0x..."}`, or JSON `null` for no inscription. `content_type` is `null` if absent or not plain ASCII |
| `web3_erc_decode` | `{"event":"erc20_transfer","from":"0x..","to":"0x..","value":"..."}` |
| `web3_spl_decode` | `{"type":"transfer_checked",...}` with the fields in the instruction data, in snake case. Public keys are Base58 and an empty `COption` is `null` |

From 1.0, changing a name or shape takes a major release, see [CONTRIBUTING.md](../CONTRIBUTING.md). Before 1.0 they may change, and `CHANGELOG.md` will say so.
