-- =============================================================================
-- Scenario 5: deadlock between two wallet transfers, and the lock ordering fix.
-- TWO psql windows. The 5 second delay inside the function gives you time to
-- switch windows. (deadlock_timeout defaults to 1s; PostgreSQL aborts one of the
-- two transactions when it finds the cycle.)
-- =============================================================================

-- ---------- Setup (once) ----------
-- SELECT p3_reset_wallet('alice', 1000), p3_reset_wallet('bob', 1000);
-- SELECT p3_wallet('alice') AS a, p3_wallet('bob') AS b \gset

-- =============================================================================
-- 5a. THE DEADLOCK: opposite directions, locks taken in opposite order
-- =============================================================================
-- 1. A: BEGIN;
-- 2. A: SELECT transfer_naive(:a, :b, 100, 5);   -- debits alice (locks alice), sleeps 5s ...
-- 3. B (within the 5 seconds): BEGIN;
-- 4. B: SELECT transfer_naive(:b, :a, 100, 5);   -- debits bob (locks bob), sleeps 5s ...
-- 5. Wait. A wakes and wants bob (held by B); B wakes and wants alice (held by A): a cycle.
--    After about 1 second one session fails with:
--       ERROR:  deadlock detected
--       DETAIL:  Process X waits for ShareLock on transaction Y; blocked by process Z. ...
--       SQLSTATE 40P01
-- 6. The survivor: COMMIT;   The victim: ROLLBACK;  (application retries the victim)

-- =============================================================================
-- 5b. THE FIX: always lock in the same order (lowest wallet id first)
-- =============================================================================
-- Same steps, but call transfer() instead of transfer_naive():
-- 2. A: BEGIN; SELECT transfer(:a, :b, 100, 5);
-- 4. B: BEGIN; SELECT transfer(:b, :a, 100, 5);  -- BLOCKS at the first statement until A finishes, no cycle is possible
-- 6. A: COMMIT;  then B completes;  B: COMMIT;
-- Result: both transfers succeed, one after the other, no error.

-- Useful while it is happening, in a third window:
-- SELECT pid, wait_event_type, wait_event, left(query, 60) FROM pg_stat_activity WHERE datname = current_database() AND state <> 'idle';
-- SELECT * FROM pg_locks WHERE NOT granted;
