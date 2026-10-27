-- =============================================================================
-- Portfolio 3: test fixtures. Creates three dedicated test users so the
-- scenarios never touch seeded customers. Safe to re-run.
--   alice    : a lender / wallet owner       bob : another lender / wallet owner
--   borrower : a KYC verified borrower
-- Because the ledger is append only, "resetting" a wallet posts a normal ledger
-- adjustment (funding or withdrawal) to reach the target balance.
-- =============================================================================
INSERT INTO users (email, phone, full_name)
VALUES ('p3_alice@example.test',    '+2349000000001', 'P3 Alice Test'),
       ('p3_bob@example.test',      '+2349000000002', 'P3 Bob Test'),
       ('p3_borrower@example.test', '+2349000000003', 'P3 Borrower Test')
ON CONFLICT DO NOTHING;

INSERT INTO kyc_profiles (user_id, status, level, submitted_at, verified_at)
SELECT id, 'VERIFIED', 2, now(), now() FROM users WHERE email LIKE 'p3\_%@example.test'
ON CONFLICT DO NOTHING;

INSERT INTO wallets (user_id, kind)
SELECT id, 'USER' FROM users WHERE email LIKE 'p3\_%@example.test'
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION p3_user(p_label text) RETURNS bigint
    LANGUAGE sql STABLE AS $$ SELECT id FROM users WHERE email = 'p3_' || p_label || '@example.test' $$;

CREATE OR REPLACE FUNCTION p3_wallet(p_label text) RETURNS bigint
    LANGUAGE sql STABLE AS $$ SELECT user_wallet(p3_user(p_label)) $$;

-- Bring a test wallet to an exact balance. Also repairs the cached balance if an
-- earlier scenario deliberately corrupted it, then adjusts through the ledger.
CREATE OR REPLACE FUNCTION p3_reset_wallet(p_label text, p_target numeric) RETURNS numeric
    LANGUAGE plpgsql AS
$$
DECLARE
    v_wallet bigint := p3_wallet(p_label);
    v_ledger numeric;
    v_diff   numeric;
BEGIN
    SELECT COALESCE(sum(amount), 0) INTO v_ledger FROM ledger_entries WHERE wallet_id = v_wallet;
    UPDATE wallets SET balance = v_ledger WHERE id = v_wallet AND balance <> v_ledger;   -- repair
    v_diff := p_target - v_ledger;
    IF v_diff > 0 THEN
        PERFORM post_pair('WALLET_FUNDING', system_wallet('EXTERNAL'), v_wallet, v_diff, 'P3 reset');
    ELSIF v_diff < 0 THEN
        PERFORM post_pair('WALLET_WITHDRAWAL', v_wallet, system_wallet('EXTERNAL'), -v_diff, 'P3 reset');
    END IF;
    RETURN p_target;
END;
$$;

-- A fresh OPEN request by the test borrower (amount up to 100000 needs no KYC; the
-- borrower is verified anyway).
CREATE OR REPLACE FUNCTION p3_new_request(p_amount numeric, p_tenor_weeks integer DEFAULT 4) RETURNS bigint
    LANGUAGE sql AS
$$
    INSERT INTO loan_requests (borrower_id, amount, purpose, tenor_weeks, interest_rate_pct, expires_at)
    VALUES (p3_user('borrower'), p_amount, 'OTHER', p_tenor_weeks, 6, now() + interval '14 days')
    RETURNING id
$$;

-- Remove test requests that have no fundings and no loan (used by the write skew scenario).
CREATE OR REPLACE FUNCTION p3_cleanup_requests() RETURNS integer
    LANGUAGE sql AS
$$
    WITH d AS (
        DELETE FROM loan_requests r
         WHERE r.borrower_id = p3_user('borrower')
           AND NOT EXISTS (SELECT 1 FROM loan_fundings f WHERE f.loan_request_id = r.id)
           AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.loan_request_id = r.id)
        RETURNING 1)
    SELECT count(*)::integer FROM d
$$;

SELECT 'alice wallet' AS item, p3_wallet('alice') AS id
UNION ALL SELECT 'bob wallet', p3_wallet('bob')
UNION ALL SELECT 'borrower wallet', p3_wallet('borrower')
UNION ALL SELECT 'escrow wallet', system_wallet('ESCROW')
UNION ALL SELECT 'external wallet', system_wallet('EXTERNAL');
