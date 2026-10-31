-- SPL Token and Token-2022 instructions by type.
SELECT d ->> 'type' AS instruction, count(*) AS rows
FROM (SELECT web3_spl_decode(data) AS d FROM sol_instructions)
WHERE d IS NOT NULL
GROUP BY instruction
ORDER BY rows DESC;
