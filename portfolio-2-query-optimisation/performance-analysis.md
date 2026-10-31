# Portfolio 2: performance analysis

This document explains why each change was made and what the measured plans show. All figures come from the plan files in `plans/` (captured by `run_plans.ps1`), the table in `performance-summary.md`, and the output of `statistics.sql`, `matview_demo.sql` and the index size query, run on 31 October 2026.

**Environment.** PostgreSQL 18.1 on Windows (x86_64), local installation. Data from the Portfolio 1 seed: 3,200 users, 6,000 loan requests, 76,404 repayment instalments, 66,371 ledger transactions and 180,748 ledger entries. All timings are warm cache (each query is run once to warm up and the second run is saved). Machine: Windows 11 Pro laptop, Intel Core i3-1005G1 (2 cores, 4 threads), 7.8 GB RAM, NVMe SSD.

## 1. Method

1. Baseline: only primary keys, unique constraints and `ledger_entries(txn_id)` exist (Portfolio 1 schema).
2. `ANALYZE`, then `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` for each query, run twice, second run saved to `plans/before_*.txt`.
3. Apply `indexes.sql`, `VACUUM (ANALYZE)`, capture again to `plans/after_*.txt`.
4. Compare execution time, buffers touched and plan node types.

Buffers are as important as time. Time varies with whatever else the laptop is doing; "shared buffers touched" is the amount of data the plan had to read and is stable between runs. For queries that finish in a few milliseconds, differences of one or two milliseconds are within run to run noise, so conclusions below rely mainly on the plan shape and the buffer counts.

## 2. Results table

| Query | Before (ms) | After (ms) | Speed up | Buffers before | Buffers after | Main plan change |
|---|---:|---:|---:|---:|---:|---|
| Q1 wallet statement | 15.23 | 0.67 | 22.9x | 1,706 | 161 | Seq Scan on `ledger_entries` to Index Only Scan |
| Q2 marketplace | 1.56 | 1.15 | 1.4x | 497 | 366 | Seq Scan on `loan_requests` to Bitmap Index Scan on the partial index |
| Q3 lender portfolio | 2.88 | 2.21 | 1.3x | 308 | 218 | Seq Scan on `loan_fundings` to Index Only Scan |
| Q4 overdue report | 24.37 | 28.56 | 0.9x | 1,495 | 198 | Seq Scan on `repayment_schedules` to Index Only Scan (partial index) |
| Q5 top borrowers | 33.59 | 36.51 | 0.9x | 1,453 | 1,453 | none (same plan) |
| Q6 monthly totals | 22.46 | 23.01 | 1.0x | 660 | 660 | none (same plan) |
| Q7 reconciliation | 110.94 | 104.79 | 1.1x | 3,415 | 3,415 | none (same plan) |
| Q8 name search | 1.77 | 0.69 | 2.6x | 45 | 16 | Seq Scan on `users` to Bitmap Index Scan (trigram GIN) |
| Q9a correlated subquery | 1,764.18 | 8.52 | 207.0x | 341,585 | 7,146 | per user Seq Scans to per user Index Only Scans |
| Q9b join | 5.53 | 4.39 | 1.3x | 145 | 145 | none (same plan) |
| Q10 exact name lookup | 1.81 | 0.10 | 17.3x | 45 | 5 | Seq Scan on `users` to Bitmap Index Scan (expression index) |
| Q11 covering | 0.94 | 0.21 | 4.5x | 97 | 7 | Seq Scan on `loan_fundings` to Index Only Scan |
| Q12a status = ACTIVE | 0.97 | 0.68 | 1.4x | 45 | 45 | none: index not used |
| Q12b status = CLOSED | 0.68 | 0.23 | 2.9x | 45 | 34 | Seq Scan on `users` to Index Scan |

Full output with every scan node: `performance-summary.md`. Screenshots: `evidence/p2-01` to `p2-08`.

## 3. Query by query

| Query | Technique | Why it works | Observed |
|---|---|---|---|
| Q1 wallet statement | Query rewrite plus composite covering B-tree `(wallet_id, created_at DESC, id DESC) INCLUDE (txn_id, amount)` | `wallet_id` is the equality column and `created_at` the sort column, so entries come out of the index already ordered and `LIMIT 50` stops early. `INCLUDE` lets the scan skip the table. The rewrite takes the page of 50 first and derives balances from the cached wallet balance, instead of a running total over the wallet's whole history. | Before: `Seq Scan on ledger_entries` read 1,544 buffers, kept 2,714 rows and discarded 178,034, then sorted. After: `Index Only Scan using idx_ledger_entries_wallet_created` with `Heap Fetches: 0`, and the limit node needed only 8 buffers. Total time fell from 15.23 ms to 0.67 ms and buffers from 1,706 to 161. The remaining 150 buffers are the 50 lookups into `ledger_transactions`. |
| Q2 marketplace | Partial index `(created_at DESC) WHERE status = 'OPEN'` | Only open requests are listed, a few percent of the table, so the index is tiny and always relevant. | The plan changed from a Seq Scan (5,902 rows discarded) to a Bitmap Index Scan on `idx_loan_requests_open_created`, which finds the 155 OPEN rows directly. The gain is small in absolute terms (1.56 ms to 1.15 ms, 497 to 366 buffers) because the whole table is only a few hundred pages. The planner chose a bitmap scan rather than a plain index scan because the amount and tenor filters are not in the index and still have to be applied to each row (57 rows removed by the filter). The benefit would grow with the table size. |
| Q3 lender portfolio | B-tree with `INCLUDE` on `loan_fundings(lender_id)` | Finds one lender's rows without scanning all fundings. | The scan of `loan_fundings` became an `Index Only Scan` returning the lender's 149 rows with `Heap Fetches: 0`. Buffers fell from 308 to 218, time from 2.88 ms to 2.21 ms. `loan_requests` is still read by a Seq Scan (6,000 rows) because the plan hashes the whole table; at this size that is cheaper than 149 index probes. |
| Q4 overdue report | Partial index on unpaid instalments `WHERE status <> 'PAID'` | Paid instalments are the bulk of the table and are never part of this report. | Buffers fell by 87 percent (1,495 to 198) and the scan of `repayment_schedules` became an `Index Only Scan` (about 9.9 ms before to about 3.0 ms after for that node). Total time did not fall (24.37 ms to 28.56 ms): the rest of the plan (two hash joins and the aggregate over 11,225 rows) dominates and is unchanged, and the extra few milliseconds sit in the aggregate step, not in the index scan. A few milliseconds either way on a 25 ms query is within noise, so the honest conclusion is that this index reduces I/O (and would matter more on a larger table or colder cache) but does not change the elapsed time here. |
| Q5 top borrowers | FK index `loans(borrower_id)` | PostgreSQL does not index foreign keys automatically. | The plan is identical before and after (Seq Scan on `repayment_schedules` and on `loans`, hash join, same 1,453 buffers). The query needs 55,822 of the 76,404 instalments (73 percent: every instalment due before the report date), so scanning is the right plan and the new index is not used. The small difference in time (33.59 ms to 36.51 ms) is noise. This is an example of an index that is created but cannot help because the query reads most of the table. |
| Q6 monthly totals | none (CTE aggregation over whole tables) | Every row of `loans` and `repayments` must be read, so no index can reduce the work. Use the materialised view for the dashboard instead. | Identical plan and buffers (660) before and after, 22.46 ms against 23.01 ms. |
| Q7 reconciliation | none | Must read every ledger row to prove the balances. This is a batch check, not a request path query. | Identical plan and buffers (3,415) before and after; about 105 to 111 ms. All 180,748 ledger rows are read by design. |
| Q8 name search | `GIN (full_name gin_trgm_ops)` from `pg_trgm` | A B-tree orders values from the left, so it cannot help `ILIKE '%text%'`. Trigrams index every 3 letter fragment and can. | Before: Seq Scan on `users`, 3,197 rows discarded, 45 buffers, 1.77 ms. After: `Bitmap Index Scan on idx_users_full_name_trgm` then `Bitmap Heap Scan`, 3 heap blocks, 16 buffers, 0.69 ms. The three matching rows are found without reading the table. The absolute saving is small at 3,200 users; the difference grows with table size. |
| Q9a / Q9b correlated subquery versus join | Same covering index, plus rewriting | The correlated version runs its subquery once per user. With no index each run scans all fundings. The join version aggregates once. | Q9a before: the planner ran two subplans per user (321 and 3,200 executions), each a Seq Scan of `loan_fundings`, giving 341,585 buffers and 1,764 ms. After the covering index each execution is an `Index Only Scan` (`Heap Fetches: 0`): 7,146 buffers and 8.52 ms, a 207 times improvement. Q9b was already efficient without any index: one Seq Scan of `loan_fundings` (97 buffers) feeding a HashAggregate, 5.53 ms before and 4.39 ms after (same plan). Even after indexing, Q9a (8.52 ms) is still about twice as slow as Q9b (4.39 ms) and reads 50 times more buffers. The index rescued the poorly written query but writing the set based version first gave a better result with no index at all. |
| Q10 exact name lookup | Expression index `(lower(full_name))` | The index must contain exactly the expression in the `WHERE` clause. A plain index on `full_name` would be ignored. | Seq Scan (45 buffers, 1.81 ms) became a Bitmap Index Scan on `idx_users_full_name_lower` (5 buffers, 0.10 ms), 17 times faster. |
| Q11 covering | `INCLUDE (loan_request_id, amount)` | All needed columns are in the index, so the table is not read. | Seq Scan (97 buffers, 0.94 ms) became an Index Only Scan on `idx_loan_fundings_lender_covering` (7 buffers, 0.21 ms). The `VACUUM` in `indexes.sql` matters here because index only scans need an up to date visibility map. |
| Q12a / Q12b index not used | Plain B-tree on `users(status)` | About 97 percent of users are ACTIVE. Fetching nearly every row through an index costs more than one sequential pass, so the planner ignores it. For a rare value (CLOSED) the same index is used. | Q12a after the index: still `Seq Scan on users`, filter `status = 'ACTIVE'`, 3,087 rows returned and 113 discarded (96.5 percent of the table), 45 buffers, so `idx_users_status` was not used. Q12b (CLOSED, 62 rows, about 2 percent) used `Index Scan using idx_users_status` and read 34 buffers instead of 45. The planner's row estimate for ACTIVE was 3,087, equal to the actual count, which is why it correctly rejected the index. |

## 4. Statistics

Output of `statistics.sql` on the same database:

**Table statistics.** `ledger_entries` 180,748 live rows, `repayment_schedules` 76,404, `ledger_transactions` 66,371, `repayments` 44,774, `notifications` 22,178, `audit_logs` 16,044, `loan_fundings` 8,521, `loan_requests` 6,000. All were analysed within a minute of each other (18:34 to 18:35 on 31 October), because `indexes_drop.sql` and `indexes.sql` (which runs `VACUUM (ANALYZE)`) refresh the statistics at the start of each plan capture. Dead tuples are negligible (at most 4 per table) and `last_autoanalyze` is empty, which means autovacuum had not analysed these tables by itself in this period; the manual `ANALYZE` after the bulk load is what the planner is relying on.

**What the planner believes about `loan_requests.status`** (`pg_stats`): 4 distinct values with frequencies FUNDED 71.63 percent, EXPIRED 18.5 percent, CANCELLED 7.28 percent and OPEN 2.58 percent. This explains the plans:
- `status = 'OPEN'` (2.58 percent) is estimated at 155 rows, matches the 155 actual rows and uses the partial index through a Bitmap Index Scan (1 buffer for the index, 68 heap blocks).
- `status = 'FUNDED'` (71.63 percent) is estimated at 4,298 rows, matches the 4,298 actual rows, and the planner picks a sequential scan (200 buffers, 1,702 rows removed by the filter) because reading 72 percent of the table through an index would cost more.

**Correlated columns and extended statistics.** For `WHERE status = 'OVERDUE' AND amount_paid = 0` on `repayment_schedules`:
- Before extended statistics the planner estimated **4,656** rows, but **11,225** were returned: an underestimate of about 2.4 times. The planner multiplies the selectivity of each condition as if the columns were independent, but they are strongly related (an overdue instalment has nothing paid).
- After `CREATE STATISTICS st_schedule_status_paid (dependencies, mcv) ON status, amount_paid` and `ANALYZE`, the estimate became **11,364**, within 1.2 percent of the actual 11,225. The plan shape did not change here (still a Seq Scan, which is the right plan for 15 percent of the table), but with a join or a larger table a 2.4 times underestimate could have led to a wrong join method.

**Statistics target.** `ALTER TABLE ledger_entries ALTER COLUMN wallet_id SET STATISTICS 500` followed by `ANALYZE` makes the planner keep a more detailed histogram for `wallet_id`, which is used in many predicates; it costs a slightly longer `ANALYZE`.

Key points:
- `ANALYZE` samples the table and stores frequencies and histograms; autovacuum runs it automatically, but after a bulk load it is run by hand.
- Wrong estimates produce wrong plans (nested loops chosen for large inputs, or the reverse). The extended statistics example shows an estimate improving from 2.4 times too low to 1.2 percent off.
- Extended statistics fix cases where columns are correlated.

## 5. Materialised view

`materialised_view.sql` stores the admin dashboard's daily summary, one row per day (653 days in the view, latest day 2026-10-15).

- Reading the dashboard page from the view (`matview_demo.sql`, second query): `Index Scan Backward using mv_admin_daily_summary_day`, 30 rows, **0.146 ms** execution time, 29 buffers.
- The same page computed live from the base tables (the first query in `matview_demo.sql`): `Seq Scan on loans` then a `HashAggregate`, 4,298 rows grouped into 588 days, **4.949 ms** execution time, 84 buffers. The view is therefore about 34 times faster for this screen (4.949 ms against 0.146 ms) and reads about a third of the buffers (29 against 84).
- Note that the demonstration query aggregates only `loans`. The real dashboard also needs `users`, `repayments` and `fees`, so its live cost would be higher and the gap larger; the 34 times figure is the conservative one.
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` took **123.748 ms**. CONCURRENTLY needs the unique index on `day` and does not block readers while it runs.

Trade off: reads become very cheap, but the data is stale until refresh. Strategy chosen: hourly `REFRESH MATERIALIZED VIEW CONCURRENTLY`, with a "last refreshed" time shown on the dashboard. Exact figures such as balances and reconciliation never read from the view; they read the live tables.

## 6. Cost of indexes

Every index slows inserts and updates and uses disk. The ledger takes the most writes, so `ledger_entries` has exactly one extra index. Output of the size query:

| Index | Size | Scans |
|---|---:|---:|
| `idx_ledger_entries_wallet_created` | 10 MB | 6 |
| `repayment_schedules_loan_id_instalment_no_key` | 4,488 kB | 20 |
| `ledger_entries_pkey` | 3,984 kB | 0 |
| `repayment_schedules_pkey` | 3,248 kB | 0 |
| `ledger_entries_txn_id_idx` | 2,944 kB | 0 |
| `ledger_transactions_reference_key` | 2,648 kB | 0 |
| `repayments_idempotency_key_key` | 1,840 kB | 0 |
| `idx_schedules_unpaid_due` | 1,520 kB | 2 |
| `ledger_transactions_pkey` | 1,472 kB | 260 |
| `wallets_pkey` | 1,336 kB | 15 |

Observations:
- The new `idx_ledger_entries_wallet_created` is the largest index in the database (10 MB, bigger than the ledger primary key at about 4 MB) because it stores `wallet_id`, `created_at`, `id` and the two included columns for every row. That size is the price of the 23 times faster statement query, and it is paid on every ledger insert.
- `idx_schedules_unpaid_due` is 1.5 MB, a third of the size of the unique index on the same table, because the partial index holds only instalments that are not yet paid.
- Several indexes show `idx_scan = 0` (for example `ledger_entries_pkey` and `ledger_entries_txn_id_idx`) in this session, because the counters reflect only this short test run. They are needed for constraints and for the balancing trigger, not for queries, so a zero scan count does not make them candidates to drop. An index with `idx_scan = 0` after a long period of real use, and not needed for a constraint, would be.

## 7. Summary of findings

1. The biggest wins come from replacing repeated or wasteful scans: Q9a (207 times faster, 98 percent fewer buffers) and Q1 (23 times faster, 90 percent fewer buffers).
2. Specialised index types solved problems a plain B-tree cannot: trigram GIN for substring search (Q8), expression index for `lower(...)` (Q10), partial and covering indexes (Q2, Q3, Q4, Q11).
3. Some indexes did not help, for good reasons: Q5, Q6 and Q7 read most of the table; Q12a asks for 96.5 percent of the rows.
4. Buffers are a more reliable measure than milliseconds at this data size; Q4 shows an 87 percent drop in buffers with no change in elapsed time.
5. Writing the query well matters as much as indexing: Q9b needed no index and was faster than Q9a even after it was indexed.
6. Statistics drive the planner: extended statistics reduced an estimate error from 2.4 times to 1.2 percent.
