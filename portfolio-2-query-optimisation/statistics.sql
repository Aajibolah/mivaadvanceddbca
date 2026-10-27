-- =============================================================================
-- Statistics: how the planner knows how many rows to expect.  psql -f statistics.sql
-- =============================================================================
-- 1. When were tables last analysed, and how many dead rows are there?
SELECT relname, n_live_tup, n_dead_tup, last_analyze, last_autoanalyze
  FROM pg_stat_user_tables
 ORDER BY n_live_tup DESC
 LIMIT 8;

-- 2. What the planner believes about loan_requests.status (most common values and
--    their frequencies). This is why it ignores an index on 'FUNDED' (Q12a).
SELECT attname, n_distinct, most_common_vals, most_common_freqs
  FROM pg_stats
 WHERE tablename = 'loan_requests' AND attname = 'status';

-- 3. Estimated versus actual rows for a skewed filter.
EXPLAIN (ANALYZE, SUMMARY OFF) SELECT * FROM loan_requests WHERE status = 'OPEN';
EXPLAIN (ANALYZE, SUMMARY OFF) SELECT * FROM loan_requests WHERE status = 'FUNDED';

-- 4. Correlated columns fool the planner: it multiplies selectivities as if the
--    columns were independent. Extended statistics teach it the real dependency.
--    Instalments with status 'PAID' are exactly those with amount_paid = amount_due.
EXPLAIN (ANALYZE, SUMMARY OFF)
SELECT * FROM repayment_schedules WHERE status = 'OVERDUE' AND amount_paid = 0;

CREATE STATISTICS IF NOT EXISTS st_schedule_status_paid (dependencies, mcv)
    ON status, amount_paid FROM repayment_schedules;
ANALYZE repayment_schedules;

EXPLAIN (ANALYZE, SUMMARY OFF)
SELECT * FROM repayment_schedules WHERE status = 'OVERDUE' AND amount_paid = 0;

-- 5. Raise the detail kept for a column used in many predicates.
ALTER TABLE ledger_entries ALTER COLUMN wallet_id SET STATISTICS 500;
ANALYZE ledger_entries (wallet_id);
