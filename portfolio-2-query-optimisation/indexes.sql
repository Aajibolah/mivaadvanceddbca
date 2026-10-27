-- =============================================================================
-- Portfolio 2: performance indexes (applied AFTER the "before" plans are saved)
-- Safe to re-run. Use indexes_drop.sql to return to the baseline.
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 1. Composite B-tree + covering (INCLUDE) for the wallet statement (Q1).
--    wallet_id is the equality column, created_at the sort column, so the index
--    returns rows already in order and LIMIT 50 can stop early. INCLUDE adds the
--    columns the query reads without making them part of the sort key.
CREATE INDEX IF NOT EXISTS idx_ledger_entries_wallet_created
    ON ledger_entries (wallet_id, created_at DESC, id DESC) INCLUDE (txn_id, amount);

-- 2. Partial index for the marketplace (Q2). Only OPEN requests are ever listed
--    and they are a tiny fraction of the table, so the index stays very small.
CREATE INDEX IF NOT EXISTS idx_loan_requests_open_created
    ON loan_requests (created_at DESC) WHERE status = 'OPEN';

-- 3. Covering index for lender queries (Q3, Q9, Q11): lender_id to find rows,
--    INCLUDE so Q11 becomes an Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_loan_fundings_lender_covering
    ON loan_fundings (lender_id) INCLUDE (loan_request_id, amount);

-- 4. Partial index for collections (Q4): only unpaid instalments, ordered by due date.
CREATE INDEX IF NOT EXISTS idx_schedules_unpaid_due
    ON repayment_schedules (due_date) INCLUDE (loan_id, amount_due, amount_paid) WHERE status <> 'PAID';

-- 5. Foreign key index. PostgreSQL does not create these automatically (Q5 joins loans).
CREATE INDEX IF NOT EXISTS idx_loans_borrower ON loans (borrower_id);

-- 6. Trigram GIN index for substring search (Q8). A B-tree cannot serve '%text%'.
CREATE INDEX IF NOT EXISTS idx_users_full_name_trgm
    ON users USING gin (full_name gin_trgm_ops);

-- 7. Expression index (Q10): index the exact expression the query uses.
CREATE INDEX IF NOT EXISTS idx_users_full_name_lower ON users (lower(full_name));

-- 8. A plain B-tree on a low selectivity column (Q12). Created on purpose to show
--    that an index is not always used.
CREATE INDEX IF NOT EXISTS idx_users_status ON users (status);

-- Refresh statistics and the visibility map (needed for Index Only Scans).
VACUUM (ANALYZE) ledger_entries;
VACUUM (ANALYZE) loan_requests;
VACUUM (ANALYZE) loan_fundings;
VACUUM (ANALYZE) repayment_schedules;
VACUUM (ANALYZE) loans;
VACUUM (ANALYZE) users;
