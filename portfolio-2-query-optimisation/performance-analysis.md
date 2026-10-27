# Portfolio 2: performance analysis

This document explains **why** each change was made and what to look for in the plans. The numbers come from your own runs: after running `run_plans.ps1` twice and `python summarise_plans.py`, paste the table from `performance-summary.md` into section 2 and write down what you actually observed in the "Observed" lines. Do not copy figures from anywhere else.

Environment to record: PostgreSQL version (`SELECT version();`), machine (CPU, RAM, disk), data size (row counts from the seed output), warm cache runs.

## 1. Method

1. Baseline: only primary keys, unique constraints and `ledger_entries(txn_id)` exist (Portfolio 1 schema).
2. `ANALYZE`, then `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` for each query, run twice, second run saved to `plans/before_*.txt`.
3. Apply `indexes.sql`, `VACUUM (ANALYZE)`, capture again to `plans/after_*.txt`.
4. Compare execution time, buffers touched and plan node types.

Buffers are as important as time. Time varies with whatever else the laptop is doing; "shared buffers touched" is the amount of data the plan had to read and is stable between runs.

## 2. Results table

Paste `performance-summary.md` here.

## 3. Query by query

| Query | Technique | Why it works | What to look for | Observed |
|---|---|---|---|---|
| Q1 wallet statement | Query rewrite plus composite covering B-tree `(wallet_id, created_at DESC, id DESC) INCLUDE (txn_id, amount)` | `wallet_id` is the equality column and `created_at` the sort column, so entries come out of the index already ordered and `LIMIT 50` stops early. `INCLUDE` lets the scan skip the table. The rewrite takes the page of 50 first and derives balances from the cached wallet balance, instead of a running total over the wallet's whole history. | Before: `Seq Scan on ledger_entries` then a sort. After: `Index Only Scan Backward` and far fewer buffers. | |
| Q2 marketplace | Partial index `(created_at DESC) WHERE status = 'OPEN'` | Only open requests are listed, a few percent of the table, so the index is tiny and always relevant. | The index only wins clearly when the table is large. With about 6,000 requests the whole table is a few dozen pages, so the planner may reasonably choose a seq scan. State which you saw and why. | |
| Q3 lender portfolio | B-tree with `INCLUDE` on `loan_fundings(lender_id)` | Finds one lender's rows without scanning all fundings. | `Seq Scan on loan_fundings` becomes `Index Only Scan`. | |
| Q4 overdue report | Partial index on unpaid instalments `WHERE status <> 'PAID'` | Paid instalments are the bulk of the table and are never part of this report. | Buffers fall sharply; the aggregate over joins remains. | |
| Q5 top borrowers | FK index `loans(borrower_id)` | PostgreSQL does not index foreign keys automatically. | Little change is expected: the query aggregates a large share of the table, so scanning is the right plan. Explain why the speed up is small. | |
| Q6 monthly totals | none (CTE aggregation over whole tables) | Every row of `loans` and `repayments` must be read, so no index can reduce the work. Use the materialised view for the dashboard instead. | Same plan before and after. | |
| Q7 reconciliation | none | Must read every ledger row to prove the balances. This is a batch check, not a request path query. | Same plan before and after. | |
| Q8 name search | `GIN (full_name gin_trgm_ops)` from `pg_trgm` | A B-tree orders values from the left, so it cannot help `ILIKE '%text%'`. Trigrams index every 3 letter fragment and can. | `Seq Scan` becomes `Bitmap Index Scan` and `Bitmap Heap Scan`. | |
| Q9a / Q9b correlated subquery versus join | Same covering index, plus rewriting | The correlated version runs its subquery once per user. With no index each run scans all fundings. The join version aggregates once. | Compare Q9a before and after, and Q9b both times. After the index, how close does Q9a get to Q9b? What does that say about the planner and about writing the better query in the first place? | |
| Q10 exact name lookup | Expression index `(lower(full_name))` | The index must contain exactly the expression in the `WHERE` clause. A plain index on `full_name` would be ignored. | `Seq Scan` becomes an index based scan. | |
| Q11 covering | `INCLUDE (loan_request_id, amount)` | All needed columns are in the index, so the table is not read. | `Index Only Scan` and `Heap Fetches: 0` (needs `VACUUM`, done in `indexes.sql`). | |
| Q12a / Q12b index not used | Plain B-tree on `users(status)` | About 97 percent of users are ACTIVE. Fetching nearly every row through an index costs more than one sequential pass, so the planner ignores it. For a rare value (CLOSED) the same index is used. | Q12a stays `Seq Scan` after the index exists. Q12b changes to an index scan. Check `pg_stats` (see `statistics.sql`) to show the frequencies behind the decision. | |

## 4. Statistics

`statistics.sql` shows: the table and column statistics the planner relies on (`pg_stats`), estimated versus actual rows, extended statistics (`CREATE STATISTICS`) for correlated columns, and raising a column's statistics target. Record the "rows=" estimate against the "actual rows" for the queries and say where the estimate was wrong and why.

Points to cover in your own words:
- `ANALYZE` samples the table and stores frequencies and histograms; autovacuum runs it automatically, but after a bulk load run it by hand.
- Wrong estimates produce wrong plans (nested loops chosen for large inputs, or the reverse).
- Extended statistics fix cases where columns are correlated.

## 5. Materialised view

`materialised_view.sql` stores the admin dashboard's daily summary. Run `matview_demo.sql` and record both execution times. Trade off: reads become cheap, but the data is stale until refresh. Strategy chosen: hourly `REFRESH MATERIALIZED VIEW CONCURRENTLY` (requires the unique index on `day`), exact figures such as balances never read from it.

## 6. Cost of indexes

Every index slows inserts and updates and uses disk. The ledger takes the most writes, so `ledger_entries` has exactly one extra index. Run this and discuss:

```sql
SELECT relname, indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size, idx_scan
  FROM pg_stat_user_indexes ORDER BY pg_relation_size(indexrelid) DESC;
```

An index with `idx_scan = 0` after real use is a candidate to drop.
