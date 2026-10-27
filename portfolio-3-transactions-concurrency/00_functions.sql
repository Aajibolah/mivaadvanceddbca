-- =============================================================================
-- Portfolio 3: transactional business functions for Copay
-- Run once after Portfolio 1:  psql -v ON_ERROR_STOP=1 -f 00_functions.sql
--
-- Every function is ONE database transaction: it either completes fully or
-- leaves no trace. All money movement goes through the ledger; the triggers
-- from Portfolio 1 then keep wallets.balance correct and reject overdrafts.
--
-- Lock order used everywhere (prevents deadlocks between these functions):
--   1. loan_requests row   2. wallets (inserted in the order lender/borrower, ESCROW, FEES)
-- =============================================================================

CREATE OR REPLACE FUNCTION system_wallet(p_kind wallet_kind) RETURNS bigint
    LANGUAGE sql STABLE AS $$ SELECT id FROM wallets WHERE kind = p_kind $$;

CREATE OR REPLACE FUNCTION user_wallet(p_user_id bigint) RETURNS bigint
    LANGUAGE sql STABLE AS $$ SELECT id FROM wallets WHERE user_id = p_user_id AND kind = 'USER' $$;

-- Generic two leg posting: money leaves p_from and arrives in p_to.
-- Idempotent when p_key is supplied: a replay returns NULL instead of posting again.
CREATE OR REPLACE FUNCTION post_pair(p_type txn_type, p_from bigint, p_to bigint, p_amount numeric,
                                     p_desc text, p_key text DEFAULT NULL) RETURNS bigint
    LANGUAGE plpgsql AS
$$
DECLARE
    v_txn bigint;
BEGIN
    INSERT INTO ledger_transactions (txn_type, reference, description, idempotency_key)
    VALUES (p_type, 'CPY-' || replace(gen_random_uuid()::text, '-', ''), p_desc, p_key)
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO v_txn;
    IF v_txn IS NULL THEN
        RETURN NULL;                       -- replay of an earlier request
    END IF;
    INSERT INTO ledger_entries (txn_id, wallet_id, amount)
    VALUES (v_txn, p_from, -p_amount), (v_txn, p_to, p_amount);
    RETURN v_txn;
END;
$$;

-- -----------------------------------------------------------------------------
-- 1. Atomic funding: debit lender, credit escrow, ledger rows, funding record and
--    progress update (done by the funding trigger), all or nothing.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fund_loan(p_request_id bigint, p_lender_id bigint,
                                     p_amount numeric, p_idempotency_key text) RETURNS bigint
    LANGUAGE plpgsql AS
$$
DECLARE
    v_txn           bigint;
    v_funding       bigint;
    v_lender_wallet bigint;
    v_existing      loan_fundings%ROWTYPE;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Funding amount must be positive';
    END IF;

    -- Lock the request first (lock order rule). Concurrent funders queue here.
    PERFORM 1 FROM loan_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan request % not found', p_request_id;
    END IF;

    v_lender_wallet := user_wallet(p_lender_id);
    IF v_lender_wallet IS NULL THEN
        RAISE EXCEPTION 'User % has no wallet', p_lender_id;
    END IF;

    v_txn := post_pair('LOAN_FUNDING', v_lender_wallet, system_wallet('ESCROW'), p_amount,
                       format('Funding of loan request %s', p_request_id), p_idempotency_key);

    IF v_txn IS NULL THEN
        -- Same idempotency key seen before: return the original result, do nothing.
        SELECT * INTO v_existing FROM loan_fundings WHERE idempotency_key = p_idempotency_key;
        IF NOT FOUND OR v_existing.loan_request_id <> p_request_id
           OR v_existing.lender_id <> p_lender_id OR v_existing.amount <> p_amount THEN
            RAISE EXCEPTION 'Idempotency key % was already used for a different request', p_idempotency_key;
        END IF;
        RETURN v_existing.id;
    END IF;

    -- The trigger on loan_fundings validates the rules (own request, KYC, over funding),
    -- updates funded_amount and flips the request to FUNDED when it is full.
    INSERT INTO loan_fundings (loan_request_id, lender_id, amount, idempotency_key, ledger_txn_id)
    VALUES (p_request_id, p_lender_id, p_amount, p_idempotency_key, v_txn)
    RETURNING id INTO v_funding;
    RETURN v_funding;
END;
$$;

-- -----------------------------------------------------------------------------
-- 2. Disbursement: when a request is fully funded, pay the borrower (minus the
--    1.5 percent fee), create the loan and the weekly repayment schedule.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION disburse_loan(p_request_id bigint) RETURNS bigint
    LANGUAGE plpgsql AS
$$
DECLARE
    r        loan_requests%ROWTYPE;
    v_fee    numeric(14,2);
    v_txn    bigint;
    v_loan   bigint;
    v_interest numeric(14,2);
BEGIN
    SELECT * INTO r FROM loan_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Loan request % not found', p_request_id; END IF;

    SELECT id INTO v_loan FROM loans WHERE loan_request_id = p_request_id;
    IF FOUND THEN RETURN v_loan; END IF;               -- already disbursed (idempotent)

    IF r.status <> 'FUNDED' THEN
        RAISE EXCEPTION 'Loan request % is % and cannot be disbursed', r.id, r.status;
    END IF;

    v_fee := GREATEST(500.00, round(r.amount * 0.015, 2));
    INSERT INTO ledger_transactions (txn_type, reference, description, idempotency_key)
    VALUES ('DISBURSEMENT', 'CPY-' || replace(gen_random_uuid()::text, '-', ''),
            format('Disbursement of loan request %s', r.id), 'disburse-' || r.id)
    RETURNING id INTO v_txn;

    INSERT INTO ledger_entries (txn_id, wallet_id, amount) VALUES
        (v_txn, system_wallet('ESCROW'),      -r.amount),
        (v_txn, user_wallet(r.borrower_id),   r.amount - v_fee),
        (v_txn, system_wallet('FEES'),        v_fee);

    INSERT INTO loans (loan_request_id, borrower_id, principal, interest_rate_pct, tenor_weeks,
                       platform_fee, disbursed_at)
    VALUES (r.id, r.borrower_id, r.amount, r.interest_rate_pct, r.tenor_weeks, v_fee, now())
    RETURNING id INTO v_loan;

    INSERT INTO fees (loan_id, ledger_txn_id, fee_type, amount)
    VALUES (v_loan, v_txn, 'PLATFORM_SERVICE_FEE', v_fee);

    v_interest := round(r.amount * r.interest_rate_pct / 100, 2);
    INSERT INTO repayment_schedules (loan_id, instalment_no, due_date, principal_due, interest_due, amount_due)
    SELECT v_loan, x.k, current_date + 7 * x.k, x.p, x.i, x.p + x.i
      FROM (SELECT k,
                   CASE WHEN k < r.tenor_weeks THEN trunc(r.amount / r.tenor_weeks, 2)
                        ELSE r.amount - trunc(r.amount / r.tenor_weeks, 2) * (r.tenor_weeks - 1) END AS p,
                   CASE WHEN k < r.tenor_weeks THEN trunc(v_interest / r.tenor_weeks, 2)
                        ELSE v_interest - trunc(v_interest / r.tenor_weeks, 2) * (r.tenor_weeks - 1) END AS i
              FROM generate_series(1, r.tenor_weeks) AS k) x;
    RETURN v_loan;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. Repayment: applies the amount to the oldest unpaid instalments first and
--    shares each payment between the lenders in proportion to what they funded.
--    Idempotent per key: a retry with the same key does nothing.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_repayment(p_loan_id bigint, p_amount numeric, p_idempotency_key text)
    RETURNS integer
    LANGUAGE plpgsql AS
$$
DECLARE
    v_loan     loans%ROWTYPE;
    s          repayment_schedules%ROWTYPE;
    f          RECORD;
    v_left     numeric(14,2) := p_amount;
    v_pay      numeric(14,2);
    v_share    numeric(14,2);
    v_given    numeric(14,2);
    v_txn      bigint;
    v_count    integer := 0;
    v_n        integer;
    v_i        integer;
    v_key      text;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Repayment amount must be positive'; END IF;

    -- Serialise repayments per loan; a concurrent retry waits here and then sees the result.
    SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Loan % not found', p_loan_id; END IF;
    IF EXISTS (SELECT 1 FROM repayments WHERE idempotency_key LIKE p_idempotency_key || '-%') THEN
        RETURN 0;                                          -- replay: nothing applied
    END IF;

    FOR s IN SELECT * FROM repayment_schedules
              WHERE loan_id = p_loan_id AND status <> 'PAID'
              ORDER BY instalment_no FOR UPDATE
    LOOP
        EXIT WHEN v_left <= 0;
        v_pay := LEAST(v_left, s.amount_due - s.amount_paid);
        v_key := p_idempotency_key || '-' || s.instalment_no;

        INSERT INTO ledger_transactions (txn_type, reference, description, idempotency_key)
        VALUES ('REPAYMENT', 'CPY-' || replace(gen_random_uuid()::text, '-', ''),
                format('Repayment of loan %s, instalment %s', p_loan_id, s.instalment_no), v_key)
        RETURNING id INTO v_txn;

        INSERT INTO ledger_entries (txn_id, wallet_id, amount)
        VALUES (v_txn, user_wallet(v_loan.borrower_id), -v_pay);

        SELECT count(*) INTO v_n FROM loan_fundings WHERE loan_request_id = v_loan.loan_request_id;
        v_i := 0; v_given := 0;
        FOR f IN SELECT lender_id, amount FROM loan_fundings
                  WHERE loan_request_id = v_loan.loan_request_id ORDER BY id
        LOOP
            v_i := v_i + 1;
            v_share := CASE WHEN v_i = v_n THEN v_pay - v_given
                            ELSE round(v_pay * f.amount / v_loan.principal, 2) END;
            v_given := v_given + v_share;
            IF v_share > 0 THEN
                INSERT INTO ledger_entries (txn_id, wallet_id, amount)
                VALUES (v_txn, user_wallet(f.lender_id), v_share);
            END IF;
        END LOOP;

        -- Trigger enforces oldest first, no overpayment, and closes the loan when done.
        INSERT INTO repayments (loan_id, schedule_id, payer_id, amount, ledger_txn_id, idempotency_key)
        VALUES (p_loan_id, s.id, v_loan.borrower_id, v_pay, v_txn, v_key);

        v_left := v_left - v_pay;
        v_count := v_count + 1;
    END LOOP;

    IF v_left > 0 THEN
        RAISE EXCEPTION 'Repayment exceeds the outstanding balance of the loan by %', v_left;
    END IF;
    RETURN v_count;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Withdrawal, pessimistic locking version: FOR UPDATE makes concurrent
--    withdrawals from one wallet queue up, and the balance is checked AFTER the
--    lock is held, so the check cannot be stale.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION withdraw_safe(p_wallet_id bigint, p_amount numeric, p_key text DEFAULT NULL)
    RETURNS bigint
    LANGUAGE plpgsql AS
$$
DECLARE
    v_balance numeric;
BEGIN
    SELECT balance INTO v_balance FROM wallets WHERE id = p_wallet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Wallet % not found', p_wallet_id; END IF;
    IF v_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, requested %', v_balance, p_amount
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN post_pair('WALLET_WITHDRAWAL', p_wallet_id, system_wallet('EXTERNAL'), p_amount,
                     'Withdrawal to bank account', p_key);
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. Wallet to wallet transfer.
--    transfer_naive : locks wallets in the order given (deadlock prone). The
--                     optional delay makes the deadlock easy to reproduce.
--    transfer       : locks both wallets in ascending id order first (safe).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_naive(p_from bigint, p_to bigint, p_amount numeric,
                                          p_delay_seconds numeric DEFAULT 0) RETURNS bigint
    LANGUAGE plpgsql AS
$$
DECLARE
    v_txn bigint;
BEGIN
    INSERT INTO ledger_transactions (txn_type, reference, description)
    VALUES ('WALLET_TRANSFER', 'CPY-' || replace(gen_random_uuid()::text, '-', ''), 'Wallet transfer (naive)')
    RETURNING id INTO v_txn;
    INSERT INTO ledger_entries (txn_id, wallet_id, amount) VALUES (v_txn, p_from, -p_amount);   -- locks FROM
    PERFORM pg_sleep(p_delay_seconds);
    INSERT INTO ledger_entries (txn_id, wallet_id, amount) VALUES (v_txn, p_to, p_amount);      -- then locks TO
    RETURN v_txn;
END;
$$;

CREATE OR REPLACE FUNCTION transfer(p_from bigint, p_to bigint, p_amount numeric,
                                    p_delay_seconds numeric DEFAULT 0) RETURNS bigint
    LANGUAGE plpgsql AS
$$
DECLARE
    v_txn bigint;
BEGIN
    -- Consistent lock order: lowest wallet id first, whatever the direction of the transfer.
    PERFORM 1 FROM wallets WHERE id IN (p_from, p_to) ORDER BY id FOR UPDATE;
    INSERT INTO ledger_transactions (txn_type, reference, description)
    VALUES ('WALLET_TRANSFER', 'CPY-' || replace(gen_random_uuid()::text, '-', ''), 'Wallet transfer')
    RETURNING id INTO v_txn;
    INSERT INTO ledger_entries (txn_id, wallet_id, amount) VALUES (v_txn, p_from, -p_amount);
    PERFORM pg_sleep(p_delay_seconds);
    INSERT INTO ledger_entries (txn_id, wallet_id, amount) VALUES (v_txn, p_to, p_amount);
    RETURN v_txn;
END;
$$;
