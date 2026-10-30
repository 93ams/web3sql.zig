# Performance

`zig build bench` (ReleaseFast, one core, WSL2 on x86_64, Zig 0.17.0). Numbers are a baseline, not a guarantee.

| Benchmark | Throughput | PRD §6 target | Status |
|---|---:|---:|---|
| keccak256 4 KiB | 293 MB/s | 1.5 GB/s | **gap** |
| keccak256 32 B | 1.88 M ops/s | | |
| sha256 4 KiB | 830 MB/s | | |
| blake3 4 KiB | 1.06 GB/s | | |
| blake2b-256 4 KiB | 638 MB/s | | |
| ripemd160 4 KiB | 260 MB/s | | |
| hex encode | 7.5 GB/s | 1.5 GB/s | met |
| hex decode | 2.8 GB/s | 1.5 GB/s | met |
| base64 decode | 2.0 GB/s | | |
| base58 encode 32 B | 7.2 M ops/s (230 MB/s) | 1.5 GB/s | **gap** |
| base58 decode 32 B | 12.9 M ops/s (412 MB/s) | 1.5 GB/s | **gap** |
| mulDiv u256 | 268 k ops/s | | |
| decimal format u256 | 3.3 M ops/s | | |

## Gaps

- **Keccak-256.** A single-buffer Keccak on one core costs about 6 to 10 cycles per byte, so 1.5 GB/s is out of reach for one message. It is only plausible as multi-buffer SIMD over many short inputs, which is M8.1's batch candidate.
- **Base58.** Base conversion is multiplication by a constant per limb; 1.5 GB/s in byte terms is not physically meaningful for it. The useful figure is ops/s on 32-byte pubkeys: 7 to 13 M/s means DuckDB's 2048-row chunk costs under 0.3 ms.
