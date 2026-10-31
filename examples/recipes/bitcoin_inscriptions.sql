-- Ordinals inscriptions by content type. NULL is an envelope with no content of its own, such as a delegate.
-- The function returns JSON null for a script with no envelope.
SELECT d ->> 'content_type' AS content_type,
       count(*) AS inscriptions,
       sum((length(d ->> 'body') - 2) / 2) AS body_bytes
FROM (SELECT web3_btc_inscription(script) AS d FROM btc_tapscripts)
WHERE d <> 'null'
GROUP BY content_type
ORDER BY inscriptions DESC;
