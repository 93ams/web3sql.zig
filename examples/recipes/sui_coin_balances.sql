-- Move objects from raw BCS. The schema spells out the struct: here 0x2::coin::Coin.
SELECT d ->> 'id' AS coin, (d ->> 'balance')::UBIGINT AS balance
FROM (SELECT web3_bcs_decode('{id:address,balance:u64}', bcs) AS d FROM sui_coins)
ORDER BY balance DESC
LIMIT 10;
