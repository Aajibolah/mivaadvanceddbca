-- Return to the Portfolio 1 baseline (no performance indexes) so plans can be re-captured.
DROP INDEX IF EXISTS idx_ledger_entries_wallet_created;
DROP INDEX IF EXISTS idx_loan_requests_open_created;
DROP INDEX IF EXISTS idx_loan_fundings_lender_covering;
DROP INDEX IF EXISTS idx_schedules_unpaid_due;
DROP INDEX IF EXISTS idx_loans_borrower;
DROP INDEX IF EXISTS idx_users_full_name_trgm;
DROP INDEX IF EXISTS idx_users_full_name_lower;
DROP INDEX IF EXISTS idx_users_status;
ANALYZE;
