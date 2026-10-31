-- Why a decoder returned NULL: the first thing to run on a new dataset.
SELECT coalesce(why, 'decoded') AS outcome, count(*) AS logs
FROM (SELECT web3_evm_decode_log_error('event Transfer(address indexed from, address indexed to, uint256 value)', topics, data) AS why
      FROM evm_logs
      WHERE topics[1:32] = web3_evm_topic0('Transfer(address,address,uint256)'))
GROUP BY outcome
ORDER BY logs DESC;
