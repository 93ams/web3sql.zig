# Security

`web3sql.zig` decodes untrusted on-chain bytes inside SQL engines, so a decoder that crashes takes a whole query or database process down with it.

## Threat model

**Attacker:** anyone who can put bytes on a chain. Transaction data, logs, account data and scripts all reach these decoders unchanged, and an attacker can craft them for free or for a small fee.

**Trusted:** the query author and everything they write, including constant schemas, signatures and IDLs. A schema read from a column is treated as untrusted, because a pipeline may take it from a decoded row.

**In scope:** a crash, hang, memory error or wrong result in the host process, or memory growing without bound, from any input bytes or column-supplied schema.

**Out of scope:** malicious constant schemas, the security of the host database, and compromised build tools. Extensions are unsigned, so anyone who can replace the file can run code in the database.

A native crash takes down the whole DuckDB process, so this boundary matters more than it would for a Python UDF. The WASM bundle runs in the warehouse's sandbox, where a trap fails one query.

## Guarantees

- Decoders never panic on malformed input: every length is checked, recursion is depth-limited, and work is bounded by input length.
- At the SQL layer, any decoding error becomes `NULL` for that row. A malformed *constant* schema is a bind error, because it is a mistake in the query and not in the data.
- Row paths do not allocate. Schemas are parsed at bind time into a dedicated arena. There are two exceptions in DuckDB, both bounded: a non-constant schema column, parsed into a per-chunk arena and capped at 4 MB of text, and a row whose result exceeds 64 KB, retried on a heap buffer of up to 16 MB.
- No third-party dependencies. The only vendored files are DuckDB's C headers, under `src/targets/duckdb_ext/vendor/`.

## Verification

- Each decoder has a `std.testing.fuzz` target and a mutation stress test in `zig build test`.
- `.github/workflows/nightly-fuzz.yml` fuzzes each lane for an hour under ReleaseSafe.
- `scripts/test_duckdb.py` compares results with independent reference libraries.
- `tools/reference/` compares generated and mutated data with `eth_abi`, a port of `ord`, upstream tick and lending math, and encoders written from the Borsh and BCS specifications. Mutated calls also run through native and WASM, which must agree.
- `tools/reference/soak.py` watches memory through a long multi-threaded scan.

None of this has had an outside review, or run on real chain data. `docs/HANDOFF.md` lists both.

## Supported versions

Before 1.0, only the latest release gets fixes. See the tables in `CONTRIBUTING.md`.

## Reporting

Please report vulnerabilities privately, not in a public issue: through [GitHub security advisories](https://github.com/93ams/web3sql.zig/security/advisories/new). Include the function, the input bytes, and the DuckDB or runtime version.
