# Performance

`zig build bench` (ReleaseFast, one core, WSL2 on x86_64, Zig 0.17.0). Numbers are a baseline, not a guarantee.

| Benchmark | Throughput | PRD §6 target | Status |
|---|---:|---:|---|
| Uniswap Swap log to JSON | 2.1 M logs/s | 500 k events/s | met |
| hex encode | 8.7 GB/s | 1.5 GB/s | met |
| hex decode | 3.7 GB/s | 1.5 GB/s | met |
| keccak256 4 KiB | 335 MB/s | 300 MB/s | met |
| keccak256 32 B | 2.5 M ops/s | | |
| base58 encode 32 B | 8.3 M ops/s (264 MB/s) | 8 M ops/s | met |
| base58 decode 32 B | 13.5 M ops/s (432 MB/s) | 8 M ops/s | met |
| sha256 4 KiB | 1.0 GB/s | | |
| blake3 4 KiB | 1.2 GB/s | | |
| blake2b-256 4 KiB | 712 MB/s | | |
| ripemd160 4 KiB | 319 MB/s | | |
| base64 decode | 2.5 GB/s | | |
| mulDiv u256 | 9.8 M ops/s | | |
| decimal format u256 | 4.8 M ops/s | | |

The host is shared, so runs vary by about 25%. In DuckDB, Borsh decoding of a short schema runs at 2 to 4 M rows/s; most of that time is DuckDB's own.

## End to end

`tools/reference/measure.py` on 10 M synthetic Uniswap Swap logs in a 307 MB Parquet file: DuckDB 2.0.0, 20 threads, on a host running other work, so treat these as lower bounds. Every row is asserted to decode.

| Work | Native | Python, one thread |
|---|---:|---:|
| Decode a log to JSON, 20 threads | 7 to 8 M rows/s | |
| Decode a log to JSON, 1 thread | 1.0 M rows/s | 35 k rows/s (`eth_abi`) |
| Keccak-256 of the 160-byte data | 6 to 7 M rows/s | 80 to 100 k rows/s |

So decoding is about 30x faster per thread and about 200x on 20 threads, reading Parquet included. The Python figure is a plain loop over fetched rows, which spares it a real UDF's marshalling and flatters it. It is measured on 300,000 rows.

Other DuckDB measurements:

| Case | Result |
|---|---:|
| Base58 worst row, 1280 bytes | 134 us to encode, 84 us to decode |
| Short Borsh schema, constant | 24 M rows/s |
| Same, four schemas alternating row by row in a column | 11 M rows/s |

In V8, the generated Snowflake bodies take about 1 ms for a cold start and 2 to 4 us for a warm row. Bodies now carry one function each, so the largest functions take longer than this `web3_keccak256` figure.

There is no automated benchmark regression check, because this host varies too much for one to mean anything. See H9 in `docs/HANDOFF.md`.

## Why the Keccak and Base58 targets are what they are

- **Keccak-256.** A single-buffer Keccak on one core costs about 6 to 10 cycles per byte, so the original 1.5 GB/s was out of reach for one message and the target is now 300 MB/s. It is only plausible as multi-buffer SIMD over many short inputs, which has not been built. `hashBatch` is the API it would sit behind.
- **Base58.** Base conversion is multiplication by a constant per limb; 1.5 GB/s in byte terms is not physically meaningful for it. The useful figure is ops/s on 32-byte pubkeys: 8 to 13 M/s means a 2048-row chunk costs under 0.3 ms.
