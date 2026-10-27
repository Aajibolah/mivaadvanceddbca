-- Portfolio 2: all Copay queries in one script (run for results, not plans).
-- Usage:  psql -f queries.sql
-- Parameters are picked automatically; the plan runner (run_plans.ps1) does the same.
\set as_of '2026-10-15'
\set as_of_ts '2026-10-15 23:00:00+00'
SELECT wallet_id AS wallet_id FROM (SELECT wallet_id, count(*) c FROM ledger_entries GROUP BY 1 ORDER BY c DESC LIMIT 1 OFFSET 5) x \gset
SELECT lender_id AS lender_id FROM (SELECT lender_id, count(*) c FROM loan_fundings GROUP BY 1 ORDER BY c DESC LIMIT 1 OFFSET 3) x \gset
\echo '--- parameters: wallet_id' :wallet_id 'lender_id' :lender_id 'as_of' :as_of
\ir queries/q01_wallet_statement.sql
\ir queries/q02_marketplace_open.sql
\ir queries/q03_lender_portfolio.sql
\ir queries/q04_overdue_report.sql
\ir queries/q05_top_borrowers.sql
\ir queries/q06_monthly_totals.sql
\ir queries/q07_reconciliation.sql
\ir queries/q08_search_name.sql
\ir queries/q09a_correlated.sql
\ir queries/q09b_join.sql
\ir queries/q10_exact_name_lookup.sql
\ir queries/q11_lender_fundings_covering.sql
\ir queries/q12a_status_active.sql
\ir queries/q12b_status_closed.sql
