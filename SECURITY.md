# Security

`web3sql.zig` decodes untrusted on-chain bytes inside SQL engines, so a decoder that crashes takes a whole query or database process down with it.

## Guarantees

- Decoders never panic on malformed input: every length is checked, recursion is depth-limited, and work is bounded by input length.
- At the SQL layer, any decoding error becomes `NULL` for that row. A malformed *constant* schema is a bind error, because it is a mistake in the query and not in the data.
- Row paths do not allocate. Schemas are parsed at bind time into a dedicated arena. The exception is a non-constant schema column in DuckDB, parsed into an arena when its value changes within a chunk.
- No third-party dependencies. The only vendored files are DuckDB's C headers, under `src/targets/duckdb_ext/vendor/`.

## Verification

- Each decoder has a `std.testing.fuzz` target and a mutation stress test in `zig build test`.
- `.github/workflows/nightly-fuzz.yml` fuzzes each lane for an hour under ReleaseSafe.
- `scripts/test_duckdb.py` compares results with independent reference libraries.

## Reporting

Please report vulnerabilities privately through GitHub security advisories on this repository, not in a public issue. Include the function, the input bytes, and the DuckDB or runtime version.
