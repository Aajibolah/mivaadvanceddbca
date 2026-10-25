-- =============================================================================
-- Portfolio 1: business rule tests
-- Run after schema.sql and the seed:  psql -f rule_tests.sql
--
-- Each test attempts an action that a business rule forbids and expects the
-- database to reject it. Every attempt runs in its own sub-transaction, so the
-- data is left unchanged. Expected output: PASS for every line.
-- =============================================================================
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

CREATE FUNCTION pg_temp.expect_fail(p_label text, p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN format('FAIL  %s  (statement was accepted)', p_label);
EXCEPTION WHEN OTHERS THEN
    RETURN format('PASS  %s  [%s: %s]', p_label, SQLSTATE, left(SQLERRM, 90));
END $$;

-- Pick test subjects from the seeded data --------------------------------------
SELECT id AS open_req, borrower_id AS open_borrower, amount AS open_amount,
       amount - funded_amount AS open_remaining
  FROM loan_requests WHERE status = 'OPEN' AND funded_amount = 0 ORDER BY id LIMIT 1 \gset
SELECT user_id AS verified_lender FROM kyc_profiles k
  JOIN users u ON u.id = k.user_id
 WHERE k.status = 'VERIFIED' AND u.role = 'USER' AND k.user_id <> :open_borrower ORDER BY user_id LIMIT 1 \gset
SELECT user_id AS unverified_user FROM kyc_profiles WHERE status <> 'VERIFIED' ORDER BY user_id LIMIT 1 \gset
SELECT id AS rich_wallet, balance AS rich_balance FROM wallets WHERE kind = 'USER' ORDER BY balance DESC LIMIT 1 \gset
SELECT id AS any_txn FROM ledger_transactions ORDER BY id LIMIT 1 \gset
SELECT l.id AS loan_id, s2.id AS second_schedule, s2.amount_due AS second_due, l.borrower_id AS loan_borrower
  FROM loans l
  JOIN repayment_schedules s1 ON s1.loan_id = l.id AND s1.instalment_no = 1 AND s1.status <> 'PAID'
  JOIN repayment_schedules s2 ON s2.loan_id = l.id AND s2.instalment_no = 2
 ORDER BY l.id LIMIT 1 \gset
SELECT l.id AS paid_loan, s.id AS paid_schedule, l.borrower_id AS paid_borrower
  FROM loans l JOIN repayment_schedules s ON s.loan_id = l.id AND s.instalment_no = 1 AND s.status = 'PAID'
 ORDER BY l.id LIMIT 1 \gset

SELECT '--- Ledger rules ---';
SELECT pg_temp.expect_fail('R1 wallet cannot go below zero',
  format($f$WITH t AS (INSERT INTO ledger_transactions(txn_type, reference) VALUES ('WALLET_WITHDRAWAL','TEST-R1') RETURNING id)
            INSERT INTO ledger_entries(txn_id, wallet_id, amount)
            SELECT id, %s, -(%s + 1) FROM t UNION ALL SELECT id, 1, (%s + 1) FROM t$f$,
         :rich_wallet, :rich_balance, :rich_balance));
SELECT pg_temp.expect_fail('R2 ledger transaction must sum to zero',
  $f$SET CONSTRAINTS ALL IMMEDIATE;
     WITH t AS (INSERT INTO ledger_transactions(txn_type, reference) VALUES ('WALLET_FUNDING','TEST-R2') RETURNING id)
     INSERT INTO ledger_entries(txn_id, wallet_id, amount)
     SELECT id, 1, -100 FROM t UNION ALL SELECT id, 4, 50 FROM t$f$);
SELECT pg_temp.expect_fail('R3 ledger entries cannot be updated', 'UPDATE ledger_entries SET amount = amount + 1 WHERE id = 1');
SELECT pg_temp.expect_fail('R4 ledger entries cannot be deleted', 'DELETE FROM ledger_entries WHERE id = 1');
SELECT pg_temp.expect_fail('R5 ledger cannot be truncated', 'TRUNCATE ledger_entries');
SELECT pg_temp.expect_fail('R6 ledger transactions cannot be updated', 'UPDATE ledger_transactions SET description = ''x'' WHERE id = 1');
SELECT pg_temp.expect_fail('R7 zero value entry rejected',
  format($f$INSERT INTO ledger_entries(txn_id, wallet_id, amount) VALUES (%s, 1, 0)$f$, :any_txn));

SELECT '--- Lending rules ---';
SELECT pg_temp.expect_fail('R8 user cannot lend to own request',
  format($f$INSERT INTO loan_fundings(loan_request_id, lender_id, amount, idempotency_key, ledger_txn_id)
            VALUES (%s, %s, 1000, 'TEST-R8', %s)$f$, :open_req, :open_borrower, :any_txn));
SELECT pg_temp.expect_fail('R9 request cannot be over funded',
  format($f$INSERT INTO loan_fundings(loan_request_id, lender_id, amount, idempotency_key, ledger_txn_id)
            VALUES (%s, %s, %s + 1000, 'TEST-R9', %s)$f$, :open_req, :verified_lender, :open_remaining, :any_txn));
SELECT pg_temp.expect_fail('R10 unverified user cannot borrow above the KYC limit',
  format($f$INSERT INTO loan_requests(borrower_id, amount, purpose, tenor_weeks, interest_rate_pct, expires_at)
            VALUES (%s, 500000, 'RENT', 12, 8, now() + interval '14 days')$f$, :unverified_user));
SELECT pg_temp.expect_fail('R11 unverified user cannot lend above the KYC limit',
  format($f$INSERT INTO loan_fundings(loan_request_id, lender_id, amount, idempotency_key, ledger_txn_id)
            VALUES (%s, %s, 150000, 'TEST-R11', %s)$f$, :open_req, :unverified_user, :any_txn));
SELECT pg_temp.expect_fail('R12 funded request must be fully funded',
  format($f$UPDATE loan_requests SET status = 'FUNDED' WHERE id = %s$f$, :open_req));
SELECT pg_temp.expect_fail('R13 money must be NGN',
  $f$UPDATE wallets SET currency = 'USD' WHERE id = 4$f$);

SELECT '--- Repayment rules ---';
SELECT pg_temp.expect_fail('R14 repayments must clear the oldest unpaid instalment first',
  format($f$INSERT INTO repayments(loan_id, schedule_id, payer_id, amount, ledger_txn_id, idempotency_key)
            VALUES (%s, %s, %s, %s, %s, 'TEST-R14')$f$, :loan_id, :second_schedule, :loan_borrower, :second_due, :any_txn));
SELECT pg_temp.expect_fail('R15 cannot repay an already paid instalment (overpayment)',
  format($f$INSERT INTO repayments(loan_id, schedule_id, payer_id, amount, ledger_txn_id, idempotency_key)
            VALUES (%s, %s, %s, 1000, %s, 'TEST-R15')$f$, :paid_loan, :paid_schedule, :paid_borrower, :any_txn));
SELECT pg_temp.expect_fail('R16 only the borrower can repay',
  format($f$INSERT INTO repayments(loan_id, schedule_id, payer_id, amount, ledger_txn_id, idempotency_key)
            VALUES (%s, %s, 1, 1000, %s, 'TEST-R16')$f$, :loan_id, :second_schedule, :any_txn));

SELECT '--- Identity rules ---';
SELECT pg_temp.expect_fail('R17 duplicate email rejected',
  $f$INSERT INTO users(email, phone, full_name) SELECT email, '+2348000000001', 'Dup' FROM users LIMIT 1$f$);
SELECT pg_temp.expect_fail('R18 malformed phone rejected',
  $f$INSERT INTO users(email, phone, full_name) VALUES ('x@example.com', '0803', 'Bad Phone')$f$);
SELECT pg_temp.expect_fail('R19 one wallet per user',
  $f$INSERT INTO wallets(user_id, kind) SELECT user_id, 'USER' FROM wallets WHERE kind = 'USER' LIMIT 1$f$);

SELECT '--- Reconciliation ---';
SELECT 'Wallets where cached balance <> ledger sum: ' || count(*) FROM wallet_reconciliation WHERE difference <> 0;
SELECT 'Ledger grand total (must be 0.00): ' || COALESCE(sum(amount), 0) FROM ledger_entries;
