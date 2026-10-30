# Performance

`zig build bench` (ReleaseFast, one core, WSL2 on x86_64, Zig 0.17.0). Numbers are a baseline, not a guarantee.

| Benchmark | Throughput | PRD §6 target | Status |
|---|---:|---:|---|
| Uniswap Swap log to JSON | 2.1 M logs/s | 500 k events/s | met |
| hex encode | 8.7 GB/s | 1.5 GB/s | met |
| hex decode | 3.7 GB/s | 1.5 GB/s | met |
| keccak256 4 KiB | 335 MB/s | 1.5 GB/s | **gap** |
| keccak256 32 B | 2.5 M ops/s | | |
| base58 encode 32 B | 8.3 M ops/s (264 MB/s) | 1.5 GB/s | **gap** |
| base58 decode 32 B | 13.5 M ops/s (432 MB/s) | 1.5 GB/s | **gap** |
| sha256 4 KiB | 1.0 GB/s | | |
| blake3 4 KiB | 1.2 GB/s | | |
| blake2b-256 4 KiB | 712 MB/s | | |
| ripemd160 4 KiB | 319 MB/s | | |
| base64 decode | 2.5 GB/s | | |
| mulDiv u256 | 9.8 M ops/s | | |
| decimal format u256 | 4.8 M ops/s | | |

The host is shared, so runs vary by about 25%. In DuckDB, Borsh decoding of a short schema runs at 2 to 4 M rows/s; most of that time is DuckDB's own.

## Gaps

- **Keccak-256.** A single-buffer Keccak on one core costs about 6 to 10 cycles per byte, so 1.5 GB/s is out of reach for one message. It is only plausible as multi-buffer SIMD over many short inputs, which has not been built. `hashBatch` is the API it would sit behind.
- **Base58.** Base conversion is multiplication by a constant per limb; 1.5 GB/s in byte terms is not physically meaningful for it. The useful figure is ops/s on 32-byte pubkeys: 8 to 13 M/s means a 2048-row chunk costs under 0.3 ms.
