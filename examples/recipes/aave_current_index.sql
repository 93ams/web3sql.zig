-- Aave v3 liquidity index brought forward to a block time, which gives the same answer as getReserveNormalizedIncome.
SELECT asset,
       liquidity_index AS stored_index,
       web3_aave_normalized_income(liquidity_rate, liquidity_index, last_update, block_time) AS current_index
FROM aave_reserves;
