-- Compare the live aggregation with the materialised view.  psql -f matview_demo.sql
\timing on
\echo '--- Live aggregation (what the dashboard would run without the view)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT (disbursed_at AT TIME ZONE 'UTC')::date AS day, count(*), sum(principal)
  FROM loans GROUP BY 1 ORDER BY 1 DESC LIMIT 30;

\echo '--- Same screen from the materialised view'
EXPLAIN (ANALYZE, BUFFERS)
SELECT day, loans_disbursed, disbursed_amount FROM mv_admin_daily_summary ORDER BY day DESC LIMIT 30;

\echo '--- Refresh without blocking readers'
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_admin_daily_summary;
SELECT count(*) AS days_in_view, max(day) AS latest_day FROM mv_admin_daily_summary;
