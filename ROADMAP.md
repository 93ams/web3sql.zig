# ROADMAP: web3sql.zig to production

Everything in `prd.md` has a tested first implementation, tagged `v0.1.0` locally. This file lists what remains before a release people can depend on. `prd.md` says **what**; this file says **in what order, and how to know it is done**.

For now there is no bulk real data, no GitHub repository and no warehouse account. So the plan has two parts: §4 is everything this machine can prove, and §5 is the handoff to professionals. Done means `make verify` passes and the handoff list is the only thing left.

Toolchain: Zig 0.17.0. On WSL under `/mnt/c`, builds need `ZIG_LOCAL_CACHE_DIR` outside the repository; the Makefile sets it.

---

## 1. Open questions for the handoff

None of these block local work.

| # | Question | Affects |
|---|---|---|
| D2 | Where does the repo live? CI, nightly fuzz and releases have never run. | H1 |
| D3 | Who provides a Snowflake account and a GCP project with a bucket, and with what cost cap? | H4, H5 |
| D4 | Are Spark/Databricks and Polars in scope? The PRD names them and no target exists. DuckDB-WASM is named too, and is untested. | `prd.md` |
| D5 | Is a GCS bucket acceptable for the 5 BigQuery functions over the 32 KB inline limit? The other 77 need none. | H4 |
| D6 | Keccak-256 and Base58 at 1.5 GB/s: build multi-buffer Keccak, or restate the targets? See `docs/PERF.md`. | `prd.md` |

---

## 2. Working rules

1. **Known answers from an authoritative source.** Cite it next to the vector. For third-party behaviour (`ord`, `eth_abi`, Aave), compare with its source or a run of it, never with memory.
2. **Decoders never panic.** Checked arithmetic, typed errors, and a fuzz target per decoder.
3. **No allocation in row paths**, except a non-constant schema column in DuckDB (see §3). Anything else that needs an allocator belongs in `bind`.
4. **One error set per module, mapped to NULL at the target layer.** Libraries return typed errors.
5. **Feature flags stay at the edges.** Only `root.zig` files read `build_options`.
6. **Every PRD requirement ID maps to a test name.** `scripts/req_coverage.sh` enforces it.
7. **Every bug found gets a regression test that fails first.**
8. **Done means `make verify` passes.**
9. **Keep reference tools out of the product.** They live under `tools/reference/` with lockfiles. The library itself stays zero-dependency.

---

## 3. Decisions already in force

Reversing any of these is a change to the design, not a cleanup.

- **Base58** uses 58^5 limbs and a 1280-byte bound, because real Solana instruction data exceeds 128 bytes.
- **DuckDB** bindings come from `b.addTranslateC` over the vendored headers, pinned to C API v1.5.6.
- **WASM exports** are `(argv, argc, out, cap)`, since most functions take several arguments.
- **Warehouse functions carry only their own code.** `sql_gen` links one object once per function, so a body is 40 KB at most. Snowflake is always inline. BigQuery is inline up to 32,000 bytes, and uses the GCS bundle above that.
- **A non-constant schema column** allocates from a per-chunk arena when its value changes. Bind cannot see those schemas, and a fixed buffer returned `NULL` for ordinary IDLs. Constant schemas and all decoding stay allocation-free.
- **A row whose result exceeds 64 KB** retries on a heap buffer of up to 16 MB in DuckDB. Valid rows must not look malformed, and ordinary rows never take this path.
- **`std.json`-based functions are native-only**, so they stay out of the WASM size budget.

---

## 4. Local work

Proven on this machine. All done. Items that cannot be done here say so and moved to §5.

### L1: Run it on every host we can reach

- [x] L1.1 Native Windows: the release artifact passes `scripts/test_duckdb.py` in Windows Python (3,986 calls), including C++ exceptions crossing Zig frames.
- [x] L1.2 `linux_arm64` release artifact passes the same script under Docker emulation.
- [x] L1.3 `linux_amd64_musl`, `linux_arm64_musl` and `windows_arm64` build and ship. Unit tests pass on musl, and Alpine's loader resolves both musl artifacts. Running inside DuckDB moved to H3.
- [x] L1.4 Loaded in a clean Debian bullseye container (glibc 2.31). The extension needs only `GLIBC_2.2.5` symbols.
- [x] L1.5 Version policy in `CONTRIBUTING.md`. The pre-release run moved to H3.

### L2: Long runs

- [x] L2.1 One hour per lane under ReleaseSafe, mirroring `nightly-fuzz.yml`: about 1.3 billion runs, no crash or hang. The decoders changed since then got 30 minutes each on the final tree, clean: 237 million runs on SVM, 412 million on protocols. The others are unchanged.
- [x] L2.2 Differential: `tools/reference/wasm_diff.py` mutates every recorded call, and native, the WASM bundle and each per-function module must agree: 99,626 mutated calls across 82 functions, 46% of them `NULL`.
- [x] L2.3 Soak: 30 minutes of multi-threaded scans, 328 in all. RSS peaked at 208 MB after warm-up and 213 MB in the second half, so no leak.

### L3: Generated data against reference implementations

Stands in for real data and cannot replace it: generators produce what their authors expected, so H6 stays necessary.

- [x] L3.1 **EVM:** 100,000 valid cases identical to `eth_abi`. Of 100,000 mutated, all differences sampled are padding or in-range overlapping offsets, which `docs/LIMITS.md` documents as policy. No dirty value is accepted.
- [x] L3.2 **Bitcoin:** 200,000 scripts with no disagreement against a Python port of `ord`. The real `ord` moved to H6.
- [x] L3.3 **CLMM:** every tick against Uniswap, Orca and Raydium source, forward and inverse. Cetus is not verified to the last digit.
- [x] L3.4 **Lending:** 200,000 cases each against constants and formulas from Aave and Compound source. Separate functions cover Aave's v3.4+ and legacy formulas.
- [x] L3.5 **Solana:** every item in 7 public IDLs resolves on zero-filled data, after adding `hashMap`, sets and Shank discriminants. Real Metaplex accounts carry no Anchor discriminator, see `docs/LIMITS.md`. No IDL surveyed uses generics, so those stay unsupported. Generated Borsh against a spec encoder.
- [x] L3.6 **Move:** generated BCS against a spec encoder. SDK comparison moved to H6.
- [x] L3.7 **Cosmos:** moved to H6, needs `cosmjs`. Known answers remain in `scripts/test_duckdb.py`.
- [x] L3.8 **Mainnet sample:** pinned real data from 6 chains, replayed by `make verify` against `eth_abi`, contract views and node output. Exact on Aave, Compound and every tick, including Cetus. Found four real gaps, now fixed: SPL coverage, `emit_cpi` events, trailing bytes and Metaplex accounts. See `docs/HANDOFF.md`.

### L4: Hardening

- [x] L4.1 Valid rows over 64 KB retry on a heap buffer of up to 16 MB.
- [x] L4.2 `<name>_error` twins say why a row is `NULL`.
- [x] L4.3 Schema column cache bounded at 16 entries and 4 MB per schema, and measured.
- [x] L4.4 `Resolver` uses a hash map, tested on a chain of 20,000 types.
- [x] L4.5 Base58 worst row measured: about 200 microseconds at 1280 bytes.
- [x] L4.6 NUL in a constant schema documented in `docs/LIMITS.md`. It is a query author's mistake, so not worth widening the C API use.
- [x] L4.7 REQ-DUCK-03 proven by a zero-row bind test.
- [x] L4.8 Threat model and support policy in `SECURITY.md`.

### L5: Release, without GitHub

- [x] L5.1 `scripts/release.sh` runs every gate, then builds eight platforms, the full WASM bundle and checksums. `release.yml` is a thin wrapper.
- [x] L5.2 Run here, and each artifact we can run was installed on a clean host. See L1.
- [x] L5.3 Workflow actions pinned to commit SHAs, each confirmed to exist upstream. `actionlint` runs in `make verify`.
- [x] L5.4 The Linux steps of `ci.yml` pass from a clean copy of only what git tracks, with empty build caches.

### L6: Warehouse dress rehearsal

- [x] L6.1 BigQuery and Snowflake JavaScript run in a stripped context with no `TextEncoder` or `atob`, fresh per call for Snowflake (`scripts/test_snowflake.mjs`). Offline SQL parsing moved to H3's skipped list.
- [x] L6.2 In V8: about 1 ms cold start and 2 to 4 microseconds per warm row. Bodies are 40 KB at most and 1 MB in total, down from 294 KB each and 24 MB. `test_snowflake.mjs` fails above 100 KB.
- [x] L6.3 77 of 82 BigQuery functions are inline, and each runs alone against every recorded call.

### L7: The 1.0 surface

- [x] L7.1 JSON outputs specified in `docs/LIMITS.md`, each checked against the build. API candidates are below.
- [x] L7.2 `web3_version()`.
- [x] L7.3 Stability policy, supported versions, `CHANGELOG.md`, `CONTRIBUTING.md`.
- [x] L7.4 Limits page and `NULL` troubleshooting. Examples per function remain the catalogue's docs and `scripts/test_duckdb.py`.
- [x] L7.5 `examples/dbt-duckdb`: moved to H3's skipped list, needs `dbt-duckdb`.
- [x] L7.6 10M synthetic Parquet rows: 30x Python per thread, 200x on 20 threads, see `docs/PERF.md`. A regression check waits for H9, since this host varies too much.
- [x] L7.7 `make verify` runs everything in one command, in about 7 minutes once reference sources are cached.

### API decisions

Settled while renames were free, and listed in `CHANGELOG.md`:

- `web3_uni_amount0_delta` and `web3_uni_amount1_delta` take `round_up` as BOOLEAN.
- No function has a `_json` suffix. Decoders return JSON.
- `web3_i256_from_bytes` takes up to 32 bytes and sign-extends.
- `web3_sol_pda` keeps comma-separated hex seeds: WASM has no list type, and one signature across hosts is worth more than a nicer DuckDB call.

---

## 5. Handoff

Needs people, accounts or hardware this project does not have. [`docs/HANDOFF.md`](docs/HANDOFF.md) has the exact commands and completion test for each.

- [ ] H1 **GitHub:** push, and get `ci.yml` and `nightly-fuzz.yml` green.
- [ ] H2 **macOS:** load and test both builds.
- [ ] H3 **Other artifacts:** musl and `windows_arm64` runtime, newest DuckDB pre-release, and the steps skipped locally.
- [ ] H4 **BigQuery:** deploy, replay, a million-row query with malformed rows.
- [ ] H5 **Snowflake:** test one `CREATE` first.
- [ ] H6 **Real data:** millions of real rows per chain against independent decoders, with every `NULL` class explained.
- [ ] H7 **Signed distribution** through `duckdb/community-extensions`.
- [ ] H8 **Independent security review.**
- [ ] H9 **Dedicated-hardware benchmarks.**
- [ ] H10 **Outside users** on real pipelines, then 1.0.

---

## 6. Risks

- **Warehouse rejection:** Snowflake's sandbox may not expose `WebAssembly`, which no local test can show. H5 starts with a one-line probe, and names the next design to try.
- **Community extensions:** if their CI cannot build Zig, signed distribution needs another route.
- **Zig 0.17 churn:** stay pinned in CI and `.zigversion`, and upgrade deliberately.
- **Small samples flatter us:** generated data shares its authors' assumptions, and the mainnet sample is thousands of rows from a handful of blocks. It found four gaps, so expect H6 to find more.
