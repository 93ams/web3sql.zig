-- Decoded Uniswap v3 swaps, with the pool price after each swap, for a USDC/WETH-style pair (6 and 18 decimals).
SELECT d ->> 'sender' AS sender,
       d ->> 'amount0' AS amount0,
       d ->> 'amount1' AS amount1,
       (d ->> 'tick')::BIGINT AS tick,
       web3_uni_sqrt_price_to_price(d ->> 'sqrtPriceX96', 6, 18, 18) AS price_token1_per_token0
FROM (SELECT web3_evm_decode_log(
                 'event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)',
                 topics, data) AS d
      FROM evm_logs)
WHERE d IS NOT NULL;
