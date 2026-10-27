-- =============================================================================
-- Scenario 6: idempotency. A client retries after a timeout (the classic stuck
-- and re-queried transaction). The same idempotency key must never charge twice.
-- Single session first, then a two session variant.
-- Run:  psql -f 06_idempotency.sql
-- =============================================================================
\set ON_ERROR_STOP off
\pset pager off

SELECT p3_reset_wallet('alice', 100000);
SELECT p3_new_request(50000) AS request_id \gset
SELECT balance AS alice_before FROM wallets WHERE id = p3_wallet('alice') \gset

\echo '=== First request with key idem-:request_id ==='
SELECT fund_loan(:request_id, p3_user('alice'), 20000, 'idem-' || :request_id) AS funding_id;
\echo '=== Retry (same key, same payload): returns the SAME funding id, charges nothing ==='
SELECT fund_loan(:request_id, p3_user('alice'), 20000, 'idem-' || :request_id) AS funding_id;
SELECT fund_loan(:request_id, p3_user('alice'), 20000, 'idem-' || :request_id) AS funding_id;

\echo '=== Same key with a DIFFERENT amount is a client bug and is rejected ==='
SELECT fund_loan(:request_id, p3_user('alice'), 99999, 'idem-' || :request_id) AS funding_id;

\echo '=== Result: exactly one funding row and one debit of 20000 ==='
SELECT count(*) AS funding_rows, sum(amount) AS total_funded
  FROM loan_fundings WHERE loan_request_id = :request_id;
SELECT :alice_before - balance AS alice_debited FROM wallets WHERE id = p3_wallet('alice');

\echo '=== The database refuses a duplicate key even if application code forgets ==='
INSERT INTO ledger_transactions (txn_type, reference, idempotency_key)
VALUES ('LOAN_FUNDING', 'CPY-DUP-' || :request_id, 'idem-' || :request_id);

-- ---------------------------------------------------------------------------
-- Two session variant (the real race): two connections send the SAME request
-- at the same moment.
-- 1. A: BEGIN;  SELECT fund_loan(<req>, p3_user('alice'), 10000, 'race-1');   -- do not commit yet
-- 2. B: BEGIN;  SELECT fund_loan(<req>, p3_user('alice'), 10000, 'race-1');   -- BLOCKS on the unique key
-- 3. A: COMMIT;                                                              -- B unblocks, sees the key exists, returns A's funding id
-- 4. B: COMMIT;
-- SELECT count(*) FROM loan_fundings WHERE idempotency_key = 'race-1';       -- 1
-- ---------------------------------------------------------------------------

\echo
\echo '=== Repayment idempotency and oldest-first allocation ==='
SELECT fund_loan(:request_id, p3_user('alice'), 30000, 'idem-' || :request_id || '-rest');
SELECT disburse_loan(:request_id) AS loan_id \gset
SELECT p3_reset_wallet('borrower', 30000);
SELECT apply_repayment(:loan_id, 1.5 * amount_due, 'rep-' || :loan_id) AS instalments_touched
  FROM repayment_schedules WHERE loan_id = :loan_id AND instalment_no = 1;
\echo 'Retry the identical repayment:'
SELECT apply_repayment(:loan_id, 1.5 * amount_due, 'rep-' || :loan_id) AS instalments_touched
  FROM repayment_schedules WHERE loan_id = :loan_id AND instalment_no = 1;
SELECT instalment_no, amount_due, amount_paid, status
  FROM repayment_schedules WHERE loan_id = :loan_id ORDER BY instalment_no LIMIT 3;
\echo 'Expected: instalment 1 PAID, instalment 2 PARTIAL (half paid), instalment 3 PENDING, retry touched 0.'
