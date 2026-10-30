# SQL functions

Generated from the function catalogue by `zig build docs`. Any malformed row returns `NULL`, and so does a valid row whose result exceeds 64 KB in DuckDB, or the 60 KB shared by arguments and result in WASM.
Types are DuckDB's. Functions marked *DuckDB only* parse JSON, and are left out of the WASM bundle to fit its size budget.

| Function | Returns | Description |
|---|---|---|
| `web3_keccak256(BLOB)` | BLOB | Keccak-256 digest |
| `web3_sha256(BLOB)` | BLOB | SHA-256 digest |
| `web3_sha256d(BLOB)` | BLOB | Double SHA-256 digest |
| `web3_ripemd160(BLOB)` | BLOB | RIPEMD-160 digest |
| `web3_hash160(BLOB)` | BLOB | Bitcoin HASH160: RIPEMD160(SHA256(x)) |
| `web3_blake2b256(BLOB)` | BLOB | Blake2b-256 digest |
| `web3_blake3(BLOB)` | BLOB | Blake3 digest |
| `web3_hex_encode(BLOB)` | VARCHAR | Lowercase hex without 0x |
| `web3_hex_decode(VARCHAR)` | BLOB | Bytes from hex, optional 0x |
| `web3_base58_encode(BLOB)` | VARCHAR | Base58 |
| `web3_base58_decode(VARCHAR)` | BLOB | Bytes from Base58 |
| `web3_base58check_encode(BLOB)` | VARCHAR | Base58Check |
| `web3_base58check_decode(VARCHAR)` | BLOB | Payload from Base58Check |
| `web3_base64_encode(BLOB)` | VARCHAR | Base64 with padding |
| `web3_base64_decode(VARCHAR)` | BLOB | Bytes from padded Base64 |
| `web3_base64url_encode(BLOB)` | VARCHAR | Base64URL without padding |
| `web3_base64url_decode(VARCHAR)` | BLOB | Bytes from unpadded Base64URL |
| `web3_u256_from_bytes(BLOB)` | VARCHAR | Decimal from up to 32 big-endian bytes |
| `web3_i256_from_bytes(BLOB)` | VARCHAR | Signed decimal from 32 big-endian bytes |
| `web3_u256_to_bytes(VARCHAR)` | BLOB | 32 big-endian bytes from decimal |
| `web3_mul_div(VARCHAR, VARCHAR, VARCHAR)` | VARCHAR | floor(a*b/c) on decimal strings at 512-bit precision |
| `web3_evm_checksum_address(BLOB)` | VARCHAR | EIP-55 text of a 20-byte address |
| `web3_evm_is_checksummed(VARCHAR)` | BOOLEAN | True if text passes EIP-55 |
| `web3_evm_create_address(BLOB, BIGINT)` | BLOB | CREATE address (sender, nonce) |
| `web3_evm_create2_address(BLOB, BLOB, BLOB)` | BLOB | CREATE2 address (sender, salt, init code hash) |
| `web3_evm_topic0(VARCHAR)` | BLOB | Event topic0 of a human-readable signature |
| `web3_evm_selector(VARCHAR)` | BLOB | 4-byte selector of a human-readable signature |
| `web3_evm_canonical_signature(VARCHAR)` | VARCHAR | Canonical form of a human-readable signature |
| `web3_evm_decode_log(VARCHAR, BLOB, BLOB)` | VARCHAR | JSON from (signature, topics, data) |
| `web3_evm_decode_log_field(VARCHAR, BLOB, BLOB, VARCHAR)` | VARCHAR | One JSON value from (signature, topics, data, path) |
| `web3_evm_decode_calldata(VARCHAR, BLOB)` | VARCHAR | JSON from (signature, input) |
| `web3_evm_decode_calldata_field(VARCHAR, BLOB, VARCHAR)` | VARCHAR | One JSON value from (signature, input, path) |
| `web3_evm_decode_log_abi(VARCHAR, BLOB, BLOB)` | VARCHAR | JSON from (JSON ABI fragment, topics, data) *DuckDB only* |
| `web3_evm_decode_calldata_abi(VARCHAR, BLOB)` | VARCHAR | JSON from (JSON ABI fragment, input) *DuckDB only* |
| `web3_sol_is_on_curve(BLOB)` | BOOLEAN | True if 32 bytes are an Ed25519 point |
| `web3_sol_pda(VARCHAR, VARCHAR)` | VARCHAR | Program derived address from Base58 program id and comma-separated hex seeds |
| `web3_sol_pda_bump(VARCHAR, VARCHAR)` | BIGINT | Bump seed of web3_sol_pda |
| `web3_anchor_instruction_discriminator(VARCHAR)` | BLOB | Anchor global:<name> discriminator |
| `web3_anchor_account_discriminator(VARCHAR)` | BLOB | Anchor account:<Name> discriminator |
| `web3_anchor_event_discriminator(VARCHAR)` | BLOB | Anchor event:<Name> discriminator |
| `web3_borsh_decode(VARCHAR, BLOB)` | VARCHAR | JSON from Borsh bytes and a text schema |
| `web3_anchor_decode_instruction(VARCHAR, BLOB)` | VARCHAR | JSON from an IDL and instruction data *DuckDB only* |
| `web3_anchor_decode_event(VARCHAR, BLOB)` | VARCHAR | JSON from an IDL and event data *DuckDB only* |
| `web3_anchor_decode_account(VARCHAR, BLOB)` | VARCHAR | JSON from an IDL and account data *DuckDB only* |
| `web3_anchor_decode_event_log(VARCHAR, VARCHAR)` | VARCHAR | JSON from an IDL and a 'Program data:' log line *DuckDB only* |
| `web3_move_address(VARCHAR)` | VARCHAR | Canonical 32-byte 0x address |
| `web3_move_address_short(VARCHAR)` | VARCHAR | Aptos display form of an address |
| `web3_move_type_tag(VARCHAR)` | VARCHAR | Canonical Move TypeTag string |
| `web3_bcs_decode(VARCHAR, BLOB)` | VARCHAR | JSON from BCS bytes and a text schema; strict |
| `web3_btc_script_type(BLOB)` | VARCHAR | scriptPubKey class, e.g. p2wpkh |
| `web3_btc_address(VARCHAR, BLOB)` | VARCHAR | Address of a scriptPubKey on a named network |
| `web3_btc_script_json(VARCHAR, BLOB)` | VARCHAR | Classification and address as JSON |
| `web3_btc_op_return(BLOB)` | BLOB | OP_RETURN payload bytes |
| `web3_btc_runestone_json(BLOB)` | VARCHAR | Runestone tag/value pairs as JSON |
| `web3_btc_inscription_json(BLOB)` | VARCHAR | Ordinals inscription in a witness script as JSON |
| `web3_cosmos_convert_hrp(VARCHAR, VARCHAR)` | VARCHAR | Re-encode a Bech32 address under a new prefix |
| `web3_cosmos_is_valid(VARCHAR)` | BOOLEAN | True for a valid Bech32 address |
| `web3_ibc_denom(VARCHAR)` | VARCHAR | ibc/<SHA256> hash of a denom trace |
| `web3_ibc_base_denom(VARCHAR)` | VARCHAR | Base denom of a denom trace |
| `web3_uni_sqrt_ratio_at_tick(BIGINT)` | VARCHAR | Uniswap TickMath.getSqrtRatioAtTick |
| `web3_uni_tick_at_sqrt_ratio(VARCHAR)` | BIGINT | Uniswap TickMath.getTickAtSqrtRatio |
| `web3_uni_sqrt_price_to_price(VARCHAR, BIGINT, BIGINT, BIGINT)` | VARCHAR | Price from sqrtPriceX96 (sqrt, decimals0, decimals1, scale) |
| `web3_uni_tick_to_price(BIGINT, BIGINT, BIGINT, BIGINT)` | VARCHAR | Price from a tick (tick, decimals0, decimals1, scale) |
| `web3_uni_amount0_delta(VARCHAR, VARCHAR, VARCHAR, BIGINT)` | VARCHAR | SqrtPriceMath.getAmount0Delta (sqrtA, sqrtB, liquidity, round_up) |
| `web3_uni_amount1_delta(VARCHAR, VARCHAR, VARCHAR, BIGINT)` | VARCHAR | SqrtPriceMath.getAmount1Delta (sqrtA, sqrtB, liquidity, round_up) |
| `web3_orca_sqrt_price_from_tick(BIGINT)` | VARCHAR | Orca Q64.64 sqrt price of a tick |
| `web3_raydium_sqrt_price_from_tick(BIGINT)` | VARCHAR | Raydium Q64.64 sqrt price of a tick |
| `web3_cetus_sqrt_price_from_tick(BIGINT)` | VARCHAR | Cetus Q64.64 sqrt price of a tick |
| `web3_orca_tick_from_sqrt_price(VARCHAR)` | BIGINT | Orca tick of a Q64.64 sqrt price |
| `web3_raydium_tick_from_sqrt_price(VARCHAR)` | BIGINT | Raydium tick of a Q64.64 sqrt price |
| `web3_cetus_tick_from_sqrt_price(VARCHAR)` | BIGINT | Cetus tick of a Q64.64 sqrt price |
| `web3_x64_sqrt_price_to_price(VARCHAR, BIGINT, BIGINT, BIGINT)` | VARCHAR | Price from a Q64.64 sqrt price (sqrt, decimalsA, decimalsB, scale) |
| `web3_erc_decode_json(BLOB, BLOB)` | VARCHAR | ERC-20/721/1155 Transfer or Approval as JSON (concatenated topics, data) |
| `web3_spl_decode_json(BLOB)` | VARCHAR | SPL Token instruction as JSON |
| `web3_wad_mul(VARCHAR, VARCHAR)` | VARCHAR | Aave wadMul, half up |
| `web3_wad_div(VARCHAR, VARCHAR)` | VARCHAR | Aave wadDiv, half up |
| `web3_ray_mul(VARCHAR, VARCHAR)` | VARCHAR | Aave rayMul, half up |
| `web3_ray_div(VARCHAR, VARCHAR)` | VARCHAR | Aave rayDiv, half up |
| `web3_ray_pow(VARCHAR, VARCHAR)` | VARCHAR | Ray exponentiation by squaring |
| `web3_aave_linear_interest(VARCHAR, BIGINT, BIGINT)` | VARCHAR | Aave MathUtils.calculateLinearInterest (rate, last_update, now) |
| `web3_aave_compounded_interest(VARCHAR, BIGINT, BIGINT)` | VARCHAR | Compounded interest, Aave v3.4+ (rate, last_update, now) |
| `web3_aave_compounded_interest_legacy(VARCHAR, BIGINT, BIGINT)` | VARCHAR | Compounded interest, Aave v3.0 to v3.3 (rate, last_update, now) |
| `web3_aave_normalized_income(VARCHAR, VARCHAR, BIGINT, BIGINT)` | VARCHAR | Reserve normalized income (rate, index, last_update, now) |
| `web3_aave_normalized_debt(VARCHAR, VARCHAR, BIGINT, BIGINT)` | VARCHAR | Reserve normalized debt, v3.4+ (rate, index, last_update, now) |
| `web3_aave_normalized_debt_legacy(VARCHAR, VARCHAR, BIGINT, BIGINT)` | VARCHAR | Reserve normalized debt, v3.0 to v3.3 (rate, index, last_update, now) |
| `web3_aave_health_factor(VARCHAR, BIGINT, VARCHAR)` | VARCHAR | Health factor (collateral, liquidation threshold in bps, debt) |
| `web3_compound_exchange_rate(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR)` | VARCHAR | cToken exchange rate (cash, borrows, reserves, supply, initial_rate) |
