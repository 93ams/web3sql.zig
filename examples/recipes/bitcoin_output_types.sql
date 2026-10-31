-- Output script types, with an example address for each.
SELECT web3_btc_script_type(script) AS type,
       count(*) AS outputs,
       any_value(web3_btc_address('bitcoin', script)) AS example_address
FROM btc_outputs
GROUP BY type
ORDER BY outputs DESC;
