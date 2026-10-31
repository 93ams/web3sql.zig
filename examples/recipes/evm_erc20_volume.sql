-- ERC-20 transfers per chain, with no ABI to supply. ERC-721 logs share the topic and are told apart.
SELECT chain,
       count(*) AS transfers,
       count(DISTINCT d ->> 'to') AS recipients,
       sum((d ->> 'value')::DOUBLE) AS raw_value
FROM (SELECT chain, web3_erc_decode(topics, data) AS d FROM evm_logs)
WHERE d ->> 'event' = 'erc20_transfer'
GROUP BY chain
ORDER BY transfers DESC;
