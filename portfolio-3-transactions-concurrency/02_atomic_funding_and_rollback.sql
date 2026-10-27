-- =============================================================================
-- Scenarios 1 and 2: atomic funding, rollback and SAVEPOINT.
-- Single session. Run:  psql -f 02_atomic_funding_and_rollback.sql
-- Prerequisite: 00_functions.sql and 01_test_fixtures.sql.
-- =============================================================================
\set ON_ERROR_STOP off
\pset pager off

SELECT p3_reset_wallet('alice', 100000) AS alice_start, p3_reset_wallet('bob', 1000) AS bob_start;
SELECT p3_new_request(50000) AS request_id \gset
\echo 'Request' :request_id 'for NGN 50,000 created.'

\echo
\echo '=== 1a. Atomic funding with the PL/pgSQL function (commit) ==='
BEGIN;
SELECT fund_loan(:request_id, p3_user('alice'), 30000, 'p3-demo-' || :request_id || '-a1') AS funding_id;
COMMIT;
SELECT id, amount, funded_amount, status FROM loan_requests WHERE id = :request_id;
SELECT 'alice' AS who, balance FROM wallets WHERE id = p3_wallet('alice')
UNION ALL SELECT 'escrow', balance FROM wallets WHERE kind = 'ESCROW';

\echo
\echo '=== 1b. The same operation as plain SQL (one data modifying statement inside BEGIN/COMMIT) ==='
BEGIN;
WITH t AS (
    INSERT INTO ledger_transactions (txn_type, reference, description, idempotency_key)
    VALUES ('LOAN_FUNDING', 'CPY-PLAIN-' || :request_id, 'Plain SQL funding', 'p3-demo-' || :request_id || '-plain')
    RETURNING id),
e AS (
    INSERT INTO ledger_entries (txn_id, wallet_id, amount)
    SELECT t.id, p3_wallet('alice'), -5000 FROM t
    UNION ALL SELECT t.id, system_wallet('ESCROW'), 5000 FROM t)
INSERT INTO loan_fundings (loan_request_id, lender_id, amount, idempotency_key, ledger_txn_id)
SELECT :request_id, p3_user('alice'), 5000, 'p3-demo-' || :request_id || '-plain', t.id FROM t;
COMMIT;
SELECT id, amount, funded_amount, status FROM loan_requests WHERE id = :request_id;

\echo
\echo '=== 2a. Rollback: bob has NGN 1,000 and tries to fund NGN 20,000 ==='
SELECT count(*) AS ledger_txns_before FROM ledger_transactions \gset
SELECT balance AS bob_before FROM wallets WHERE id = p3_wallet('bob') \gset
SELECT funded_amount AS funded_before FROM loan_requests WHERE id = :request_id \gset
BEGIN;
SELECT fund_loan(:request_id, p3_user('bob'), 20000, 'p3-demo-' || :request_id || '-bob');   -- fails: CHECK violation
ROLLBACK;     -- the failed transaction is already aborted; ROLLBACK ends it
\echo 'Nothing may have changed:'
SELECT (SELECT count(*) FROM ledger_transactions) - :ledger_txns_before AS new_ledger_txns,
       (SELECT balance FROM wallets WHERE id = p3_wallet('bob')) - :bob_before AS bob_balance_change,
       (SELECT funded_amount FROM loan_requests WHERE id = :request_id) - :funded_before AS funded_change,
       (SELECT count(*) FROM loan_fundings WHERE idempotency_key = 'p3-demo-' || :request_id || '-bob') AS bob_funding_rows;

\echo
\echo '=== 2b. SAVEPOINT: keep the good part of a transaction, undo the failed part ==='
BEGIN;
SELECT fund_loan(:request_id, p3_user('alice'), 5000, 'p3-demo-' || :request_id || '-a2') AS first_ok;
SAVEPOINT try_bob;
SELECT fund_loan(:request_id, p3_user('bob'), 20000, 'p3-demo-' || :request_id || '-bob2');  -- fails
ROLLBACK TO SAVEPOINT try_bob;                                     -- undo only the failed step
SELECT fund_loan(:request_id, p3_user('alice'), 10000, 'p3-demo-' || :request_id || '-a3') AS second_ok;
COMMIT;
SELECT id, amount, funded_amount, status FROM loan_requests WHERE id = :request_id;
\echo 'Expected: funded_amount = 50000 (30000 + 5000 + 5000 + 10000), status FUNDED.'

\echo
\echo '=== Integrity check ==='
SELECT count(*) AS wallets_out_of_balance FROM wallet_reconciliation
 WHERE difference <> 0 AND wallet_id IN (p3_wallet('alice'), p3_wallet('bob'), p3_wallet('borrower'),
                                         system_wallet('ESCROW'));
