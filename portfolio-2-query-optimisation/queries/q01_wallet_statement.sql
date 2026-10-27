-- Q1 Wallet statement: latest 50 movements of one wallet with the balance after each.
-- Typical "statement" screen. Parameters: :wallet_id
-- Design: take the page of 50 first, then derive each balance from the cached wallet
-- balance minus the newer movements on the page. This avoids a running total over the
-- whole history of the wallet (the cache is proven correct by wallet_reconciliation).
WITH page AS (
    SELECT id, txn_id, amount, created_at
      FROM ledger_entries
     WHERE wallet_id = :wallet_id
     ORDER BY created_at DESC, id DESC
     LIMIT 50
)
SELECT p.created_at,
       t.txn_type,
       t.reference,
       p.amount,
       (SELECT balance FROM wallets WHERE id = :wallet_id)
         - COALESCE(sum(p.amount) OVER (ORDER BY p.created_at DESC, p.id DESC
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS balance_after
  FROM page p
  JOIN ledger_transactions t ON t.id = p.txn_id
 ORDER BY p.created_at DESC, p.id DESC;
