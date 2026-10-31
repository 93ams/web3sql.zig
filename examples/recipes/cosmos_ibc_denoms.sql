-- The on-chain ibc/... denom for each transfer trace, and the token it came from.
SELECT trace, web3_ibc_denom(trace) AS denom, web3_ibc_base_denom(trace) AS base
FROM ibc_traces
LIMIT 10;
