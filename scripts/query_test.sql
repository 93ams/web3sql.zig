-- =============================================================================
-- BigQuery web3sql Validation Query (Free-Tier Safe)
-- Dataset: your-gcp-project-id.web3sql_test_sandbox
-- Maximum Billed Bytes Safeguard: 10 MB (Free tier allows 1,000,000 MB / 1 TB per month)
-- =============================================================================

-- In bq CLI: pass `--maximum_bytes_billed=10485760` or set job_config.maximum_bytes_billed

-- UDF 1: Pure JS Keccak-256 / Hash Demonstration
CREATE TEMP FUNCTION keccak256_hex(input_hex STRING)
RETURNS STRING
LANGUAGE js AS r"""
  if (!input_hex) return null;
  var raw = input_hex.startsWith('0x') ? input_hex.slice(2) : input_hex;
  // Fallback demo or embedded WASM call
  return '0x' + raw.slice(0, 64);
""";

-- UDF 2: EVM Event Topic & Signature Inspector
CREATE TEMP FUNCTION classify_evm_event(topics ARRAY<STRING>)
RETURNS STRING
LANGUAGE js AS r"""
  if (!topics || topics.length === 0) return 'UNKNOWN';
  var t0 = topics[0].toLowerCase();
  if (t0 === '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef') {
    return 'ERC20_TRANSFER';
  }
  if (t0 === '0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925') {
    return 'ERC20_APPROVAL';
  }
  if (t0 === '0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67') {
    return 'UNISWAP_V3_SWAP';
  }
  return 'CUSTOM_EVENT';
""";

-- UDF 3: Solana Base58 Instruction Length Parser
CREATE TEMP FUNCTION get_solana_ix_length(ix_b58 STRING)
RETURNS INT64
LANGUAGE js AS r"""
  if (!ix_b58) return 0;
  return ix_b58.length;
""";

-- -----------------------------------------------------------------------------
-- Query 1: EVM Logs Verification
-- -----------------------------------------------------------------------------
SELECT
  block_number,
  block_timestamp,
  transaction_hash,
  ARRAY_LENGTH(topics) AS topic_count,
  classify_evm_event(topics) AS event_type,
  SUBSTR(data, 1, 66) AS data_preview
FROM `your-gcp-project-id.web3sql_test_sandbox.evm_logs_sample`
LIMIT 20;

-- -----------------------------------------------------------------------------
-- Query 2: Solana / SVM Instructions Verification
-- -----------------------------------------------------------------------------
SELECT
  slot,
  signature,
  get_solana_ix_length(instruction_data) AS raw_b58_len,
  SUBSTR(instruction_data, 1, 32) AS ix_data_preview
FROM `your-gcp-project-id.web3sql_test_sandbox.svm_instructions_sample`
LIMIT 20;
