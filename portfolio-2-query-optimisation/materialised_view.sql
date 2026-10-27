-- =============================================================================
-- Admin dashboard materialised view
-- The dashboard shows one row per day. Computing it live means aggregating the
-- whole of loans, repayments, fees and users on every page load. A materialised
-- view stores the result; the cost moves to a scheduled refresh.
-- =============================================================================
DROP MATERIALIZED VIEW IF EXISTS mv_admin_daily_summary;

CREATE MATERIALIZED VIEW mv_admin_daily_summary AS
WITH u AS (
    SELECT (created_at AT TIME ZONE 'UTC')::date AS day, count(*) AS new_users
      FROM users GROUP BY 1
), l AS (
    SELECT (disbursed_at AT TIME ZONE 'UTC')::date AS day, count(*) AS loans_disbursed, sum(principal) AS disbursed_amount
      FROM loans GROUP BY 1
), r AS (
    SELECT (paid_at AT TIME ZONE 'UTC')::date AS day, count(*) AS repayments, sum(amount) AS repaid_amount
      FROM repayments GROUP BY 1
), f AS (
    SELECT (created_at AT TIME ZONE 'UTC')::date AS day, sum(amount) AS fee_income
      FROM fees GROUP BY 1
), days AS (
    SELECT day FROM u UNION SELECT day FROM l UNION SELECT day FROM r UNION SELECT day FROM f
)
SELECT d.day,
       COALESCE(u.new_users, 0)        AS new_users,
       COALESCE(l.loans_disbursed, 0)  AS loans_disbursed,
       COALESCE(l.disbursed_amount, 0) AS disbursed_amount,
       COALESCE(r.repayments, 0)       AS repayments,
       COALESCE(r.repaid_amount, 0)    AS repaid_amount,
       COALESCE(f.fee_income, 0)       AS fee_income
  FROM days d
  LEFT JOIN u USING (day) LEFT JOIN l USING (day) LEFT JOIN r USING (day) LEFT JOIN f USING (day);

-- A unique index is REQUIRED for REFRESH ... CONCURRENTLY (no read blocking).
CREATE UNIQUE INDEX mv_admin_daily_summary_day ON mv_admin_daily_summary (day);

-- Refresh strategy
--  * The dashboard tolerates data that is up to an hour old, so a time based
--    refresh is enough; no trigger is needed (a trigger per ledger insert would
--    cost more than the view saves).
--  * Run hourly with CONCURRENTLY so readers are never blocked:
--        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_admin_daily_summary;
--    Schedule with pg_cron if installed, or Windows Task Scheduler running
--    psql -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_admin_daily_summary;"
--  * Show "last refreshed at" on the dashboard (store it in a small table) so
--    staff know how fresh the figures are.
--  * Anything that must be exact (balances, reconciliation) is NOT served from
--    this view. It reads the live tables.
