# Architecture

```text
targets   duckdb_main.zig   wasm_main.zig   tools/sql_gen.zig
              \                 |                /
               src/targets: the function catalogue
                    |                   |
             src/chains            src/protocols
             evm svm move          clmm tokens lending
             utxo cosmos                |
                    \                   /
                         src/core
                 math, encodings, crypto, reader
```

Lower layers never import upward. Protocols do not import chains, so any protocol builds with chains disabled. Only `root.zig` files read `build_options`.

## The catalogue

`src/targets/catalog.zig` defines one `Function` per SQL function, and `src/targets/functions_*.zig` list them per layer. A comptime adapter turns a plain Zig function into the uniform call shape, so an entry is one line. DuckDB registration, WASM exports, the warehouse SQL and `docs/FUNCTIONS.md` are all derived from that table.

Errors stop at this boundary: libraries return typed errors, and every target maps them to `NULL`.

## Schemas

Functions that take an ABI, IDL or Borsh or BCS schema split into two phases, `prepare` and `call`.

| Host | Constant schema | Varying schema |
|---|---|---|
| DuckDB | Parsed once at bind, into an arena held by refcounted bind data | Parsed per chunk, reused while the value repeats |
| WASM | Parsed on first use, kept in a 32 KB arena | Reparsed when the value changes |

A bad constant schema is a bind error. A bad per-row schema is `NULL`.

## Memory

`Function.call` takes no allocator, so row paths cannot reach the heap. Output goes into a caller buffer: 64 KB on the stack in DuckDB, and what remains of the 60 KB row scratch in WASM. An oversized result is an error, never a truncation. DuckDB retries it on a heap buffer of up to 16 MB, off the normal path; WASM returns `NULL`. A non-constant schema column has no bind phase to use, so DuckDB parses it during `execute` into a per-chunk arena that caches 16 schemas, failures included.

## DuckDB

The extension uses the stable C struct API pinned to `v1.5.6`. `get_api` returns memory that only lives during init, so the struct is copied by value. `tools/duckdb_package.zig` appends the metadata footer that `LOAD` validates.

## WASM

Each function exports `(argv, argc, out, cap) -> length or -1`, where `argv` is an array of pointer and length pairs. Hosts call `web3_free`, then `web3_alloc` for each buffer. This shape differs from the roadmap's `(in_ptr, in_len, out_ptr, out_cap)` because many functions take several arguments.

Functions that need `std.json` are marked `native_only`, so they stay out of the bundle.
