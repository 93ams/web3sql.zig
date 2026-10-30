# ROADMAP: web3sql.zig

Executable plan for one agent or a team of agents. `prd.md` says **what**; this file says **in what order, by whom, and how to know it is done**.

Toolchain: Zig 0.17.0 (`build.zig.zon` `minimum_zig_version`). Verify every claim with `zig build test`; never mark a task done on "it compiles".

---

## 0. Baseline audit (state of the repo)

The tree matches the PRD's layout, but most modules are scaffolds with smoke tests. Gaps against the PRD, ranked by risk:

| # | Finding | Severity | Where |
|---|---------|----------|-------|
| A1 | `deriveCreateAddress` ignores `nonce`, hashes the sender only. Returns **wrong addresses**. No `CREATE2`. | correctness | `chains/evm/address.zig` |
| A2 | `computeDiscriminator` falls back to hashing the bare name if the 128-byte buffer overflows. Silent wrong output. | correctness | `chains/svm/anchor.zig` |
| A3 | OP_RETURN: `PUSHDATA2/4` missing; unknown push returns "rest of script" as payload. | correctness | `chains/utxo/op_return.zig` |
| A4 | BCS/Borsh: `cursor + len` can overflow `usize` (wasm32) and `@intCast(u64 → usize)` can panic on hostile length. Violates the fuzz requirement. | security | `move/bcs.zig`, `svm/borsh.zig` |
| A5 | Base58: fixed 512-byte stack buffer, O(n²), no decode, no Base58Check. Bech32: only `polymod`, no encode/decode. Base64, varint minimal. | feature gap | `core/encodings/` |
| A6 | No ABI signature parser, no head/tail decoder (only `readWord`). No JSON ABI. | feature gap (REQ-EVM-02/03) | `chains/evm/` |
| A7 | No Ed25519 on-curve check / PDA (REQ-SVM-01). No Borsh Vec/Option/array, no Anchor IDL. | feature gap | `chains/svm/` |
| A8 | No `TypeTag` parser (only enum), no BCS ints/Option/struct. | feature gap | `chains/move/` |
| A9 | No tick math (`getSqrtRatioAtTick`), no Q64.64 price→decimal, no compounding (`rayPow`, interest index), no SPL decoder tests, no Approval decoder. | feature gap | `protocols/` |
| A10 | `duckdb_main.zig` returns `true` and registers **zero functions**. No `duckdb_extension.h` bindings. `package_duckdb.py` appends a footer by hand. | feature gap (REQ-DUCK-*) | `targets/duckdb_ext/` |
| A11 | WASM exports one function, uses a global 64 KB buffer, no ABI for variable-width returns, no size check, no SQL generator. | feature gap (REQ-WASM-*) | `targets/wasm_udf/`, `wasm_main.zig` |
| A12 | No fuzz tests, no benchmarks, no CI, no golden-vector corpus, no README. `unknown chain` flag only warns. | quality | repo-wide |
| A13 | `build.zig`: `-Dchains=bogus` silently builds with nothing; `src/root.zig` repeats the "any chain enabled" expression 3×; three near-identical entry modules. | organization | `build.zig`, `src/root.zig` |
| A14 | `.gitignore` ignores `*.wasm`, `*.dll`, so release artifacts are untracked (intended), but there is no `dist/` and no repo `git init`. | hygiene | repo root |

---

## 1. Working rules (apply to every task)

1. **Test-first with known-answer vectors.** Every primitive gets vectors from an authoritative source (RFC, BIP, EIP, Uniswap/Aave reference code). Cite the source in a comment next to the vector.
2. **Decoders never panic.** Every `[]const u8` reader uses checked arithmetic (`std.math.add`, `std.math.cast`) and returns an error. Add a fuzz test (`std.testing.fuzz`) per decoder.
3. **No allocation in row paths.** Row-path functions take caller-provided buffers or a `FixedBufferAllocator`. Anything that needs an allocator goes in `bind` time.
4. **One error set per module, mapped to NULL at the target layer.** Targets turn any error into SQL `NULL` (REQ-DUCK-04); libraries return typed errors.
5. **Feature flags stay at the edges.** Only `root.zig` files read `build_options`. Leaf modules import siblings by relative path.
6. **Every PRD requirement ID maps to at least one test name** containing the ID, e.g. `test "REQ-EVM-01 create2 ..."`. `scripts/req_coverage.sh` greps for this (task M0.6).
7. **Done = merged to the working tree, `zig build test` green for default flags AND `-Dchains=none -Dprotocols=none`**, and the module's section in `docs/` or doc comments updated.

---

## 2. Milestones

Dependencies: `M0 → M1 → {M2, M3, M4, M5} → M6 → M7 → M8`. Items inside M2–M5 are independent and can be parallel agent lanes.

### M0: Foundation, hygiene, correctness (blocks everything)
- [x] M0.1 Fix A1: `CREATE` via minimal RLP of `[sender, nonce]`; add `CREATE2`. Vectors: EIP-1014 examples; known deployer/nonce pairs.
- [x] M0.2 Fix A2: make `computeDiscriminator` take an output-checked name length (reject >64 bytes) instead of silent fallback; vectors for `global:initialize`.
- [x] M0.3 Fix A3: full push-opcode handling (direct, `PUSHDATA1/2/4`), reject truncated/unknown, multi-push support.
- [x] M0.4 Fix A4: add a shared `core/reader.zig` (`Reader` with checked `take(n)`, `readInt`, `readUleb128`) and rebuild `BorshReader`/`BcsReader` on top. One audited cursor, no duplicated bounds logic.
- [x] M0.5 `build.zig`: unknown chain/protocol → hard error (`b.fatal`); compute `any_chain` / `any_protocol` once and export in `build_options`; helper to define the 3 target modules without repetition.
- [x] M0.6 `scripts/req_coverage.sh`: lists PRD `REQ-*` ids with no matching test name.
- [x] M0.7 CI (`.github/workflows/ci.yml`): Linux/macOS/Windows `zig build test`, flag matrix (`all`, `none`, each single chain), `zig fmt --check`.
- [ ] M0.8 `git init`, tag `v0.0.1`, add `README.md` (build flags, targets, function catalogue generated from M7).

**Acceptance:** A1–A4, A13 closed; CI matrix green.

### M1: Core layer (REQ-CORE-01..03)
- [x] M1.1 **Math:** `I256` signed ops (`checkedAdd/Sub/Mul`, `divTrunc`, `divFloor`), `mulDivRoundingUp`, `isqrt`, decimal parse/format for u256/i256 (hot path for SQL `VARCHAR`/`DECIMAL(38)` bridging), `u256 ⇄ [32]u8` big/little endian. Property tests vs `std.math.big.int` oracle.
- [x] M1.2 **Hex:** SIMD (`@Vector(16,u8)`) encode + decode with scalar tail; throughput bench ≥ 1.5 GB/s.
- [x] M1.3 **Base58:** O(n·limbs) encode with base-58^10 limbs, decode, Base58Check (double-SHA256 4-byte checksum), size-bounded inputs (≤ 128 B documented), no hidden 512-byte stack buffer. Vectors: Bitcoin Core `base58_encode_decode.json`.
- [x] M1.4 **Bech32/Bech32m:** full encode/decode/convert-bits (BIP-173/350 vectors incl. invalid cases), HRP validation, Segwit address helpers.
- [x] M1.5 **Base64/Base64URL:** padded/unpadded, strict mode; RFC 4648 vectors.
- [x] M1.6 **ULEB128/varint:** u64 + u128 + u256, canonical-encoding check (BCS requires minimal), overlong rejection.
- [x] M1.7 **Crypto:** thin wrappers already delegate to `std.crypto`; add `hash160`, `sha256d`, `keccak256` streaming + batch API; RIPEMD160 vs official vectors; verify Blake3 against official test vectors; confirm SIMD hash throughput in `bench/`.
- [x] M1.8 **Ed25519 point validity** (`core/crypto/ed25519.zig`): `isOnCurve(32 bytes)` using `std.crypto.ecc.Edwards25519.fromBytes` (needed by M3 PDA).
- [x] M1.9 `bench/` harness (`zig build bench`) emitting MB/s and ops/s; baseline numbers committed in `docs/PERF.md`.

**Acceptance:** all REQ-CORE ids covered; bench meets §6 targets or the gap is written down in `docs/PERF.md`.

### M2: EVM (REQ-EVM-01..03): lane A
- [ ] M2.1 Address: EIP-55 validate (not only format), parse, `CREATE`/`CREATE2` (from M0.1).
- [ ] M2.2 **Type grammar & signature parser:** `uintN/intN/address/bool/bytesN/bytes/string/T[]/T[N]/(tuple)`, `indexed`, named params, human-readable (`event Swap(...)`, `function ...`) → comptime-free runtime `Type` tree stored in a caller arena at bind time. Canonical signature rendering → `topic0`/selector.
- [ ] M2.3 **JSON ABI fragments:** `std.json` parse of event/function fragments → same `Type` tree. Reject unknown types with errors, not panics.
- [ ] M2.4 **Head/tail decoder:** static and dynamic types, nested tuples/arrays, offset/length bounds checks, cycle/overlap-safe (offset must stay within data; total work capped by `data.len`). Output as a flat "value cursor" API (no allocation) plus `decodeField(path)` for SQL extraction of one field.
- [ ] M2.5 **Log decoding:** `topics[1..]` for indexed params, `data` for the rest; dynamic indexed params surface as their hash.
- [ ] M2.6 Calldata decoding: selector match + args.
- [ ] M2.7 Fuzz: ABI decoder, signature parser. Known-answer: Uniswap v3 `Swap`, ERC-20 `Transfer`, Seaport `OrderFulfilled`.

**Acceptance:** ≥ 500k decoded Swap logs/s/core on bench; fuzz 10M iterations clean.

### M3: SVM (REQ-SVM-01..02): lane B
- [ ] M3.1 Pubkey: Base58 parse/format (uses M1.3), `isOnCurve` (M1.8), `findProgramAddress`/`createProgramAddress` with bump search 255→0 and seed limits (≤16 seeds, ≤32 B each).
- [ ] M3.2 Borsh: complete reader (all ints, f32/f64, bool, string, fixed array, `Vec<T>`, `Option<T>`, enums, structs) driven by a runtime schema; guard `Vec` length against remaining bytes before iterating.
- [ ] M3.3 Anchor: discriminators (M0.2), event CPI log parsing (`Program data: <base64>`), IDL JSON → schema (types, accounts, events, instructions).
- [ ] M3.4 Fuzz Borsh/IDL decode. Vectors from Anchor's own test suite; Raydium/Orca swap instruction samples from `test_data/svm_instructions.parquet`.

### M4: Move (REQ-MOVE-01..02): lane C
- [ ] M4.1 Address: short-form normalisation (exists), Aptos/Sui display rules, validation.
- [ ] M4.2 **TypeTag parser:** recursive descent, `vector<T>`, `0xaddr::module::Name<T1, T2>`, depth limit (32), returns zero-alloc view slices.
- [ ] M4.3 BCS: ints to u256, bool, ULEB128 lengths (canonical-only), option, vector, string, struct via runtime schema; reject non-canonical ULEB and trailing bytes (strict mode).
- [ ] M4.4 Fuzz BCS/TypeTag; Aptos/Sui published vectors.

### M5: UTXO + Cosmos (REQ-UTXO-01..02, REQ-COSMOS-01): lane D
- [ ] M5.1 Script classifier: add bare multisig, P2PK, P2WSH validation, witness v1+ unknown; **address derivation** per network (mainnet/testnet/Litecoin HRP + version bytes) via Base58Check and Bech32/Bech32m (M1).
- [ ] M5.2 Script iterator (push-data decode) with bounds checks; OP_RETURN (M0.3), Runes (`OP_13` + pushes, LEB128 payload) and Ordinals envelope detection.
- [ ] M5.3 Cosmos: HRP conversion (decode → re-encode with new HRP, checksum valid), address validation, IBC denom trace hash (exists) + trace parsing (`transfer/channel-0/uatom`).
- [ ] M5.4 Fuzz script classifier/iterator. Vectors from Bitcoin Core `script_tests.json` (classification subset), BIP-173/350/86.

### M6: Protocols (REQ-PROT-01..03): lane E (needs M1 math only)
- [ ] M6.1 CLMM Q64.96: `getSqrtRatioAtTick` / `getTickAtSqrtRatio` (exact Uniswap `TickMath` port, tick range ±887272), `sqrtPriceX96 → price` as scaled decimal with decimals adjustment, `getAmount0/1Delta`, `mulDivRoundingUp`. Differential test vs published `TickMath` test vectors.
- [ ] M6.2 CLMM Q64.64: Orca `sqrt_price_from_tick_index`, Raydium CLMM tick math, Cetus I32 tick; price decimals.
- [ ] M6.3 Tokens: ERC-20 `Transfer`/`Approval`, ERC-721 variant (4 topics), ERC-1155 `TransferSingle`; SPL `Transfer`/`TransferChecked`/`Approve` instruction decoders (u8 discriminant + u64 LE).
- [ ] M6.4 Lending: `rayDiv`, `wadDiv`, `rayPow` (exponentiation by squaring), linear + compounded interest (Aave `MathUtils`), normalised income/debt, health factor (exists; add fuzz that HF is monotone in collateral), Compound exchange-rate math.

### M7: Targets (REQ-DUCK-*, REQ-WASM-*): sequential after lanes A–E have a stable API
- [ ] M7.1 **Function catalogue** `src/targets/catalog.zig`: one declarative table (name, arg types, return type, impl fn) that **both** targets and the SQL generators consume. Single source of truth so DuckDB/WASM/SQL files can never drift.
- [ ] M7.2 DuckDB bindings: vendor `duckdb_extension.h` (pinned C-API version, `unstable` excluded), translate the function-pointer struct with `@cImport` or a hand-written minimal extern struct; implement `web3_init_c_api` (`DUCKDB_EXTENSION_ENTRYPOINT`), register scalar functions from the catalogue.
- [ ] M7.3 Vectorized scalar executor: loop 2048-row chunks, validity-mask in/out, BLOB/VARCHAR (`duckdb_string_t` inline vs pointer) in/out, any error → `NULL` (REQ-DUCK-04).
- [ ] M7.4 Bind-time caching (REQ-DUCK-03): parse ABI/IDL on bind for constant args, store in `bind_data`, free in destroy callback; non-constant argument falls back to per-row parse with a small per-chunk cache keyed by pointer+len.
- [ ] M7.5 Replace `scripts/package_duckdb.py` footer logic with a `zig build` step (`-Dduckdb_platform=`) so packaging is one command; keep python only for the integration test. Remove the committed `zig-out/`.
- [ ] M7.6 WASM ABI: exported `alloc/free` over a bump arena (<64 KB scratch), per-function exports `(in_ptr,in_len,out_ptr,out_cap) -> i32 out_len | -1`; SIMD128 enabled in target query (`.cpu_features_add = wasm.featureSet(&.{.simd128})`); `wasm-opt`/`strip`-equivalent via `-fstrip`.
- [ ] M7.7 Size gate (REQ-WASM-02): `zig build wasm-size` fails if `web3_sql.wasm` ≥ 250 KB; flag matrix builds (evm-only etc.) report sizes in CI.
- [ ] M7.8 SQL generators (REQ-WASM-03): `zig build wasm` emits `dist/snowflake_udfs.sql` (JS-wrapper UDF embedding base64 wasm) and `dist/bigquery_udfs.sql` (JS UDF with inline wasm bytes) from the catalogue. Golden-file tests of the generated SQL.
- [ ] M7.9 Integration tests: `scripts/test_duckdb.py` executes every catalogue function against `test_data/*.parquet` and compares to expected values from an independent reference (Python `eth_abi`/`web3`, `solders`, `bech32` in a dev-only venv).

**Acceptance:** `SELECT` of every catalogue function works in DuckDB and in a Node/wasmtime harness for WASM; gate on size passes.

### M8: Performance, security, release
- [ ] M8.1 Profile hot paths (`perf`/`samply`); target numbers in §6. Candidates: Keccak AVX2/NEON path via std vector ops, batch Keccak API for `topic0` columns, branch-free hex.
- [ ] M8.2 Memory audit: prove "no global heap allocations in row processing" with a failing allocator in tests (`std.testing.FailingAllocator` set to 0 in row-path tests).
- [ ] M8.3 Security pass: run all decoders under `-OReleaseSafe` fuzz for 1h each in CI nightly; add `SECURITY.md`; supply-chain: zero deps (keep it).
- [ ] M8.4 Docs: `docs/FUNCTIONS.md` generated from the catalogue; `docs/ARCHITECTURE.md`; dbt-duckdb example project under `examples/`.
- [ ] M8.5 Release: version bump, tagged artifacts for linux/macos/windows/wasm, DuckDB community-extensions descriptor.

---

## 3. Parallelisation guide for agent teams

| Lane | Owner scope (files it may edit) | Depends on |
|------|--------------------------------|------------|
| Foundation | `build.zig`, `core/**`, CI, scripts | none |
| A: EVM | `src/chains/evm/**` | M0, M1 |
| B: SVM | `src/chains/svm/**` | M0, M1 |
| C: Move | `src/chains/move/**` | M0, M1 |
| D: UTXO/Cosmos | `src/chains/{utxo,cosmos}/**` | M0, M1 |
| E: Protocols | `src/protocols/**` | M1.1 |
| Targets | `src/targets/**`, `src/*_main.zig`, `scripts/` | stable lane APIs |

Rules: a lane never edits another lane's directory; if it needs a core change, open it as a Foundation task. Merge order: Foundation → lanes (any order) → Targets. Each task ends with `zig build test` in the default and `-Dchains=none -Dprotocols=none` configurations.

## 4. Risks

- **Zig 0.17 std churn:** API names (`std.process.Init`, `std.testing.fuzz`, `std.Io`) may shift; pin the toolchain in CI and `.zigversion`.
- **DuckDB C-API stability:** pin the API version in the extension footer; test against the two latest DuckDB releases.
- **WASM size:** `u512` division and `std.json` can blow the 250 KB budget; keep JSON ABI parsing out of the WASM build unless the size gate allows it.
- **Warehouse limits:** BigQuery/Snowflake UDF payload and memory limits are not constants: re-verify before M7.8.
- **Throughput claims:** the §6 targets are unproven on this hardware; M8.1 may adjust them rather than the code.
