# Contributing

`prd.md` says what the project does, `ROADMAP.md` what is left, and `docs/ARCHITECTURE.md` how it fits together.

## Setup

Zig 0.17.0, plus Python and Node for the integration tests.

```sh
uv venv && uv pip install -r scripts/requirements-dev.txt
source .venv/bin/activate
make test     # unit, flag, requirement coverage, DuckDB and WASM
make verify   # all of that, plus every reference harness and a format check
```

`make verify` is the definition of done. It downloads reference sources into `~/.cache/web3sql-zig/reference` once.

## Rules

1. **Known answers come from an authoritative source**, cited next to the vector. For third-party behaviour, compare with its source or a run of it, never with memory.
2. **Decoders never panic.** Checked arithmetic, typed errors, and a fuzz target per decoder.
3. **No allocation in row paths.** Anything that needs an allocator belongs in `bind`. `SECURITY.md` lists the two bounded exceptions.
4. **Libraries return typed errors.** The target layer maps them to `NULL`.
5. **Feature flags stay at the edges.** Only `root.zig` files read `build_options`.
6. **Every PRD requirement ID maps to a test name.** `scripts/req_coverage.sh` enforces it.
7. **Every bug gets a regression test** that fails before the fix.
8. **Reference tools stay out of the product.** They live in `tools/reference/`. The library has no dependencies.

## Adding a function

Add one entry to the catalogue in `src/targets/`. DuckDB, WASM, the warehouse SQL and `docs/FUNCTIONS.md` all read from it, so run `zig build docs` and add a check to `scripts/test_duckdb.py`, which fails if any function has none.

## Versions and stability

The extension version is in `build.zig`. Before 1.0, any release may change a name or shape, and `CHANGELOG.md` will say so. From 1.0:

| Change | Release |
|---|---|
| New function, or a row that was `NULL` now decodes correctly | Minor |
| Bug fix that changes a wrong result | Patch, called out in the changelog |
| Rename, removal, argument order, JSON shape | Major |

`NULL`-to-value changes are not breaking, because a `NULL` never promised to stay one. Error names from the `_error` twins are for humans and may change in any release.

## Supported versions

| Component | Supported |
|---|---|
| Zig, to build | 0.17.0 |
| DuckDB | 1.5 and 2.0. The C API is pinned to v1.5.6, and each new DuckDB release needs a run of `scripts/test_duckdb.py` before it is listed |

Each DuckDB release is added once the suite passes on it, and the oldest is dropped when the pinned C API moves.
