# Product & Technical Requirements Document (PRD): `web3sql.zig`

**Project Name:** `web3sql.zig`

**Target Ecosystems:** Dune Datashare (S3 Parquet/Iceberg), DuckDB (local), Snowflake, Google BigQuery

**Implementation Language:** Zig

---

## 1. Executive Summary & Vision

Data engineers, quantitative researchers, and analytics teams consuming raw blockchain datasets (via **Dune Datashare**, Paradigm's Cryo, AWS Public Blockchain Data, or BigQuery Public Datasets) face severe compute and usability bottlenecks when decoding binary payloads, converting chain-specific encodings, and executing high-precision financial math across heterogeneous blockchains.

`web3sql.zig` is a **modular, chain-agnostic, zero-dependency systems library** written in Zig. It provides a unified SQL and binary interface tailored for high-throughput data pipelines through two primary integration targets:
1. **A Native DuckDB C-API Vectorized Extension** (`web3.duckdb_extension`) for local analytics, CI/CD pipelines, and S3 Iceberg/Parquet processing.
2. **A Standalone WebAssembly (WASM) UDF Bundle** (`web3_sql.wasm`) for cloud data warehouses (Snowflake, BigQuery) and browser-based data tooling.

The library strictly segregates its architecture into **Core Primitives**, **Chains (L1/VM Execution Layers)**, and **Protocols (Application/DeFi Layers)**, allowing developers to compile custom, lightweight binaries via compile-time feature flags.

---

## 2. Target User Personas

1. **Dune Datashare Enterprise Engineers:** Teams ingesting raw/decoded S3 Iceberg & Parquet tables into Snowflake or BigQuery who need to eliminate expensive Python/JS UDF warehouse credit consumption.
2. **Cross-Chain DeFi Quants & Researchers:** Analysts comparing DEX volume, liquidity, and MEV across Solana (Raydium, Orca), EVM (Uniswap v3/v4), and Move chains (Cetus, Thala) using local Parquet/DuckDB workflows.
3. **Analytics Engineers (dbt Users):** Developers running local `dbt-duckdb` test suites against sampled Datashare Parquet snapshots before deploying production cloud transformations.

---

## 3. Modular Architecture & Compile-Time Flags

To ensure minimal binary footprint and lightning-fast execution, the project is structured into strict hierarchical layers controlled by Zig build options (`build.zig`).

### 3.1 Module Hierarchy
```text
web3sql.zig/
├── build.zig                      # Parses compile-time feature flags (-Dchains=..., -Dprotocols=...)
├── src/
│   ├── root.zig                   # Conditionally exports enabled modules via @import("build_options")
│   ├── core/                      # ALWAYS INCLUDED: Zero-dependency crypto, math, & encodings
│   ├── chains/                    # LAYER 1: Chain-specific execution layers (evm, svm, move, utxo, cosmos)
│   ├── protocols/                 # LAYER 2: Application layers (clmm, tokens, lending)
│   └── targets/                   # LAYER 3: Host integration bindings (duckdb_ext, wasm_udf)
```

### 3.2 Build Option Flags (`build.zig`)
* `-Dchains=evm,svm,move,utxo,cosmos` (Default: all or comma-delimited subset)
* `-Dprotocols=clmm,tokens,lending` (Default: all)
* `-Doptimize=ReleaseFast` (Enables vectorization and aggressive LLVM loop unrolling)

---

## 4. Functional Requirements by Layer

### 4.1 Core Layer (`src/core/` — Always Included)
* **REQ-CORE-01 (Arbitrary-Width Math):** Native freestanding implementations of `u128`, `u256`, `i256`, and intermediate `u512` safe arithmetic (`mul_div`, overflow-checked addition/subtraction) to prevent precision loss in SQL warehouses where numeric types cap out at 38 digits.
* **REQ-CORE-02 (Vectorized Encodings):** SIMD-accelerated encode/decode routines for Hex (`0x...`), Base58/Base58Check, Bech32/Bech32m, Base64/Base64URL, and ULEB128 varints.
* **REQ-CORE-03 (Cryptographic Primitives):** Zero-allocation scalar functions for `Keccak-256`, `SHA-256`, `Double SHA-256`, `RIPEMD160` (Bitcoin `HASH160`), `Blake2b-256`, and `Blake3`.

### 4.2 Chains Layer (`src/chains/` — Opt-In via Compile Flags)

#### EVM Module (`src/chains/evm/` — `-Dchains=evm`)
* **REQ-EVM-01 (Addresses & Hashing):** EIP-55 checksum validation, event `topic0` computation, 4-byte function selectors, and `CREATE` / `CREATE2` address derivation.
* **REQ-EVM-02 (Human-Readable & JSON ABI Parsing):** Support for `ethers.js`/`alloy`-style human-readable event/function signatures (e.g., `'Swap(address indexed sender, int256 amount0, uint160 sqrtPriceX96)'`) and standard JSON ABI fragments.
* **REQ-EVM-03 (Dynamic Tuple & Array Decoding):** Zero-allocation parsing of EVM 32-byte word head/tail layout for logs (`data`, `topics`) and transaction calldata (`input`).

#### Solana / SVM Module (`src/chains/svm/` — `-Dchains=svm`)
* **REQ-SVM-01 (Pubkeys & PDAs):** Ed25519 curve validation and Program Derived Address (PDA) generation with bump seed discovery.
* **REQ-SVM-02 (Borsh & Anchor IDL):** 
  * Full Binary Object Representation Serializer (`Borsh`) decoder for primitives, fixed arrays, dynamic vectors (`Vec<T>`), and `Option<T>`.
  * Anchor 8-byte discriminator computation ($\text{SHA256}(\text{"global:<name>"})[:8]$) for instructions and CPI event logs.

#### Move Module — Sui & Aptos (`src/chains/move/` — `-Dchains=move`)
* **REQ-MOVE-01 (Address & Type Tags):** Canonical 32-byte address normalization and recursive Move `TypeTag` parser (extracting package, module, struct, and nested generic type parameters).
* **REQ-MOVE-02 (BCS Decoding):** Binary Canonical Serialization (BCS) decoder for ULEB128-prefixed sequences, little-endian integers, and structs.

#### UTXO Module — Bitcoin & Litecoin (`src/chains/utxo/` — `-Dchains=utxo`)
* **REQ-UTXO-01 (Script Classification):** `scriptPubKey` classifier for P2PKH, P2SH, P2WPKH, P2WSH, and P2TR (Taproot) address derivation.
* **REQ-UTXO-02 (Payload Extraction):** Extraction of `OP_RETURN` binary payloads for Runes, Ordinals, and cross-chain bridge metadata.

#### Cosmos & IBC Module (`src/chains/cosmos/` — `-Dchains=cosmos`)
* **REQ-COSMOS-01 (Bech32 & IBC Hashing):** Cross-chain Bech32 human-readable prefix (HRP) conversion and IBC denom trace hash derivation (`ibc/` + $\text{SHA256}$).

### 4.3 Protocols Layer (`src/protocols/` — Opt-In via Compile Flags)
* **REQ-PROT-01 (Concentrated Liquidity Math / CLMM):** 
  * EVM Uniswap v3/v4 Q64.96 fixed-point math (`sqrtPriceX96` to human-readable price, tick-to-price conversions).
  * SVM / Move Q64.64 fixed-point math for Orca Whirlpools, Raydium CLMM, and Cetus.
* **REQ-PROT-02 (Fast-Path Token Decoders):** Optimized zero-overhead decoders for standard ERC-20 / SPL Token `Transfer` and `Approval` logs without general ABI parsing overhead.
* **REQ-PROT-03 (DeFi Lending Index Math):** Ray (`1e27`) and Wad (`1e18`) interest compounding and health factor calculations for Aave/Compound models.

---

## 5. Target Integration Requirements (`src/targets/`)

### 5.1 Target 1: DuckDB C-API Vectorized Extension (`web3.duckdb_extension`)
* **REQ-DUCK-01 (C-API Compliance):** Must use DuckDB's official C Extension API (`duckdb_extension.h`) to guarantee binary stability across minor releases.
* **REQ-DUCK-02 (Vectorized Execution):** Scalar functions MUST loop over contiguous `duckdb_vector` chunks (2,048 rows) using validity masks to process batch queries at native CPU speeds.
* **REQ-DUCK-03 (Schema Caching):** Constant expressions (e.g., ABI signatures or Borsh schemas supplied as constant query arguments) MUST be parsed **once per vector chunk/query bind** via `bind_data` rather than re-parsed per row.
* **REQ-DUCK-04 (Safe Error Handling):** Decoding functions must provide safe wrappers returning `NULL` on malformed binary rows rather than aborting multi-million-row Datashare Parquet scans.

### 5.2 Target 2: WebAssembly Cloud Warehouse UDFs (`web3_sql.wasm`)
* **REQ-WASM-01 (Freestanding Build):** Compile to `wasm32-freestanding` with `-O ReleaseSmall` and SIMD128 enabled.
* **REQ-WASM-02 (Size Constraint):** Stripped binaries MUST remain **$< 250\text{ KB}$** when compiled with selective feature flags, enabling inline embedding in BigQuery and Snowflake permanent UDF definitions without external GCS/S3 staging buckets.
* **REQ-WASM-03 (SQL Generator):** The build system MUST auto-emit deployment scripts (`dist/snowflake_udfs.sql`, `dist/bigquery_udfs.sql`).

---

## 6. Non-Functional & Performance Requirements

| Metric | Requirement |
| :--- | :--- |
| **Throughput (Hashing & Encoding)** | Per core: $\ge 1.5\text{ GB/s}$ for Hex, $\ge 300\text{ MB/s}$ for `Keccak-256`, and $\ge 8\text{ M ops/s}$ for Base58 on 32-byte keys. |
| **Throughput (ABI / Borsh Decoding)** | $\ge 500,000\text{ events/sec}$ per core for structured DEX log decoding. |
| **Memory Overhead** | Zero global heap allocations during row processing; $< 64\text{ KB}$ arena scratch buffer per worker thread. |
| **Cross-Compilation** | Single `zig build` target supporting Linux, macOS, Windows, and WebAssembly (`wasm32`). |
| **Fuzz Testing** | All binary decoders (ABI, Borsh, BCS, Bitcoin Script) must pass rigorous fuzz testing on malformed byte inputs without panicking or triggering out-of-bounds reads. |

---

## 7. Phased Implementation Roadmap

* **Phase 1: Core Primitives & Build System (Weeks 1–2):** Establish `build.zig` compile-time flag architecture, `core/` arbitrary-width math (`u256`/`u512`), SIMD encodings, hashes, and CLMM math.
* **Phase 2: DuckDB C-API Extension & EVM/SVM Chains (Weeks 3–5):** Build the DuckDB C-API vector extension wrapper, EVM signature parser / dynamic log decoder, and Solana Borsh / Anchor IDL decoder.
* **Phase 3: Move, UTXO, Cosmos & WASM Cloud Target (Weeks 6–8):** Add Move BCS, Bitcoin script classifiers, Cosmos Bech32/IBC tools, and the WASM export bundle with Snowflake/BigQuery SQL script generators.