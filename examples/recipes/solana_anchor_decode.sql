-- Anchor instructions, events and accounts, decoded with the program's IDL.
SELECT a.program,
       a.kind,
       coalesce(web3_anchor_decode_instruction(i.idl, a.data), web3_anchor_decode_event(i.idl, a.data)) ->> 'name' AS decoded,
       count(*) AS rows
FROM sol_anchor a
JOIN idls i USING (program)
WHERE a.kind <> 'account'
GROUP BY ALL
HAVING decoded IS NOT NULL
ORDER BY rows DESC;
