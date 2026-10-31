-- Which ERC-20 functions a set of transactions called, by matching the 4-byte selector.
SELECT 'transfer' AS function, count(*) AS calls
FROM evm_transactions
WHERE input[1:4] = web3_evm_selector('transfer(address,uint256)')
UNION ALL
SELECT 'approve', count(*)
FROM evm_transactions
WHERE input[1:4] = web3_evm_selector('approve(address,uint256)')
ORDER BY calls DESC;
