-- =============================================================================
-- Portfolio 4: the same loan application documents stored as PostgreSQL JSONB.
-- Load with:  python seed_from_postgres.py --also-jsonb
-- (creates loan_applications_jsonb(request_id, doc jsonb) with the SAME documents
--  that went into MongoDB)
-- Run:  psql -f jsonb_comparison.sql
-- =============================================================================
\pset pager off
\timing on

SELECT count(*) AS documents, pg_size_pretty(pg_total_relation_size('loan_applications_jsonb')) AS table_size
  FROM loan_applications_jsonb;

\echo '--- 1. Filter on nested fields, no index (sequential scan)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT request_id FROM loan_applications_jsonb
 WHERE doc @> '{"applicant": {"employment_type": "SELF_EMPLOYED"}}'
   AND (doc #>> '{applicant,monthly_income_ngn}')::int > 800000;

\echo '--- 2. GIN index: containment queries (@>) use it'
CREATE INDEX IF NOT EXISTS ix_apps_doc_gin ON loan_applications_jsonb USING gin (doc jsonb_path_ops);
ANALYZE loan_applications_jsonb;
EXPLAIN (ANALYZE, BUFFERS)
SELECT request_id FROM loan_applications_jsonb
 WHERE doc @> '{"applicant": {"employment_type": "SELF_EMPLOYED"}}'
   AND (doc #>> '{applicant,monthly_income_ngn}')::int > 800000;

\echo '--- 3. Array element search (guarantor relationship) with containment'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM loan_applications_jsonb WHERE doc @> '{"guarantors": [{"relationship": "employer"}]}';

\echo '--- 4. Expression B-tree index for one hot field (range query on income)'
CREATE INDEX IF NOT EXISTS ix_apps_income ON loan_applications_jsonb (((doc #>> '{applicant,monthly_income_ngn}')::int));
ANALYZE loan_applications_jsonb;
EXPLAIN (ANALYZE, BUFFERS)
SELECT request_id FROM loan_applications_jsonb WHERE (doc #>> '{applicant,monthly_income_ngn}')::int > 1000000;

\echo '--- 5. Aggregation: average stated income by employment type (equivalent of the Mongo $group)'
SELECT doc #>> '{applicant,employment_type}' AS employment_type,
       count(*) AS applications,
       round(avg((doc #>> '{applicant,monthly_income_ngn}')::numeric)) AS avg_income_ngn
  FROM loan_applications_jsonb GROUP BY 1 ORDER BY 2 DESC;

\echo '--- 6. Update a nested value (equivalent of $set / $push)'
BEGIN;
UPDATE loan_applications_jsonb
   SET doc = jsonb_set(doc, '{guarantors}', COALESCE(doc->'guarantors', '[]'::jsonb)
                       || '[{"name":"Test Guarantor","phone":"+2348000000000","relationship":"friend"}]'::jsonb)
 WHERE request_id = 1;
SELECT jsonb_array_length(doc->'guarantors') AS guarantors_now FROM loan_applications_jsonb WHERE request_id = 1;
ROLLBACK;

\echo '--- 7. What JSONB cannot do: it will happily store a wrong document (no schema validation)'
BEGIN;
INSERT INTO loan_applications_jsonb VALUES (-1, '{"applicant": {"employment_type": "WIZARD"}, "guarantors": "not even an array"}');
SELECT request_id FROM loan_applications_jsonb WHERE request_id = -1;
ROLLBACK;
\echo '(It could be constrained with CHECK (jsonb_typeof(doc->''guarantors'') = ''array'') or the jsonb_matches_schema extension, but that must be written explicitly.)'
