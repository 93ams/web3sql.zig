const std = @import("std");
const web3sql = @import("web3sql");

var WASM_SCRATCH_BUF: [65536]u8 = undefined;

export fn get_wasm_memory_buffer() [*]u8 {
    return &WASM_SCRATCH_BUF;
}

export fn keccak256_wasm(input_len: usize) usize {
    if (input_len > 32768) return 0;
    var digest: [32]u8 = undefined;
    web3sql.core.crypto.keccak.hash(WASM_SCRATCH_BUF[0..input_len], &digest);
    @memcpy(WASM_SCRATCH_BUF[0..32], &digest);
    return 32;
}
