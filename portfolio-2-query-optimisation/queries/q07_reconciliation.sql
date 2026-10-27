-- Q7 Reconciliation: wallets whose cached balance differs from the ledger. Must return no rows.
-- Reads every ledger row by design, so an index cannot make it cheap (see analysis).
SELECT w.id, w.balance AS cached, sum(e.amount) AS ledger_sum
  FROM wallets w
  JOIN ledger_entries e ON e.wallet_id = w.id
 GROUP BY w.id, w.balance
HAVING w.balance <> sum(e.amount);
