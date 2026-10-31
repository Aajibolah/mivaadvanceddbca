# Concurrency scenarios 3, 4 and 5 in pgAdmin 4

These are the same scenarios as `03_lost_update.sql`, `04_isolation_levels.sql` and `05_deadlock.sql`, written for pgAdmin's **Query Tool** instead of two `psql` windows. Two Query Tool tabs opened on the same database are two separate database sessions, which is exactly what the scenarios need (Session A and Session B).

The statements do not use psql variables (`:w`, `\gset`). Wallet and user ids are looked up inline with `p3_wallet('alice')` and `p3_user('borrower')`, so every statement can be pasted as it is.

## Why I used pgAdmin for these scenarios

I started these scenarios in PowerShell and kept hitting errors: SQL typed at the PowerShell prompt before starting `psql` is read as a PowerShell command (`SELECT` is an alias for `Select-Object`), and psql variable commands were easy to get wrong across two windows. I switched to pgAdmin's Query Tool and kept using it because each tab is a separate session, the two sessions sit side by side, and results and errors appear in separate panels that are easy to capture. The behaviour being demonstrated (locks, isolation levels, deadlock detection) happens inside PostgreSQL and is the same whichever client sends the statements. I also ran the same scenarios from the command line (two `psql` windows and the automated runner `run_scenarios.py`), and that log is in `evidence/run_scenarios.log`, so each result is confirmed by two clients.

## Setup

1. Prerequisite: `00_functions.sql` and `01_test_fixtures.sql` loaded (see the README).
2. In pgAdmin, right-click the **copay** database and choose **Query Tool**. Do it a second time so there are two tabs. Call them **A** and **B**.
3. Check they are separate sessions: run `SELECT pg_backend_pid();` in each tab. The two numbers must differ.
4. Leave autocommit on (the default). Run `BEGIN`, `COMMIT` and `ROLLBACK` exactly as written.
5. To run one statement, select only that statement with the mouse and press **F5**. Pressing F5 with nothing selected runs the whole editor.
6. Results appear in **Data Output**, errors in **Messages**. If a tab reports `current transaction is aborted`, run `ROLLBACK;` in that tab.

**Reset** the wallet in **one** tab only (the balance lives in the database, not in the tab). Make sure neither tab has an unfinished `BEGIN` first:

```sql
SELECT p3_reset_wallet('alice', 1000);
```

## Screenshot rules

- Every row with a **SCREENSHOT** entry needs a picture at that moment. Take it **before** running the next statement, because results and waiting states disappear.
- Each picture must show the SQL you ran, the result or the Messages panel, and the tab title (A or B).
- Save as `evidence/<name>.png` using the exact name in the table. Take screenshots with Win+Shift+S and paste them into Paint or save from the snipping tool.
- Do not show passwords. The pgAdmin window does not, but check.

## Scenario 3: lost update and fixes

### 3a. Lost update (absolute write)
Reset to 1000, then:

| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `BEGIN;` | | |
| 2 | A | `SELECT balance FROM wallets WHERE id = p3_wallet('alice');` | 1000.00 | `p3-04-1-a-read.png` |
| 3 | B | `BEGIN;` | | |
| 4 | B | `SELECT balance FROM wallets WHERE id = p3_wallet('alice');` | 1000.00 | `p3-04-2-b-read.png` |
| 5 | B | `UPDATE wallets SET balance = 1000 - 700 WHERE id = p3_wallet('alice');` | | |
| 6 | B | `COMMIT;` | | |
| 7 | A | `UPDATE wallets SET balance = 1000 - 700 WHERE id = p3_wallet('alice');` | | |
| 8 | A | `COMMIT;` | | |
| 9 | either | `SELECT balance FROM wallets WHERE id = p3_wallet('alice');` | 300.00 | |
| 10 | either | `SELECT * FROM wallet_reconciliation WHERE wallet_id = p3_wallet('alice');` | `difference` -700.00 | `p3-04-3-result.png` (show rows 9 and 10) |

Also screenshot each tab's **Query History** panel: `p3-04-4-history-a.png`, `p3-04-4-history-b.png`.

### 3b. The design's own defence (ledger delta plus CHECK constraint)
Reset to 1000, then:

| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `BEGIN;` | | |
| 2 | A | `SELECT balance FROM wallets WHERE id = p3_wallet('alice');` | 1000.00 | `p3-05-1-a-read.png` |
| 3 | B | `BEGIN;` | | |
| 4 | B | `SELECT balance FROM wallets WHERE id = p3_wallet('alice');` | 1000.00 | `p3-05-2-b-read.png` |
| 5 | A | `SELECT post_pair('WALLET_WITHDRAWAL', p3_wallet('alice'), system_wallet('EXTERNAL'), 700, 'A');` | a number (ledger transaction id) | `p3-05-3-a-withdraw.png` |
| 6 | B | `SELECT post_pair('WALLET_WITHDRAWAL', p3_wallet('alice'), system_wallet('EXTERNAL'), 700, 'B');` | **waits**, the spinner keeps going | `p3-05-4-b-waiting.png` (take it while B is still waiting) |
| 7 | A | `COMMIT;` | B's statement now stops | |
| 8 | B | look at **Messages** | `violates check constraint "wallets_balance_non_negative"` | `p3-05-5-b-error.png` |
| 9 | B | `ROLLBACK;` | | |
| 10 | either | `SELECT balance FROM wallets WHERE id = p3_wallet('alice');` | 300.00 | |
| 11 | either | `SELECT * FROM wallet_reconciliation WHERE wallet_id = p3_wallet('alice');` | `difference` 0.00 | `p3-05-6-result.png` (show rows 10 and 11) |

### 3c. Fix 1: pessimistic locking
Reset to 1000, then:

| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `BEGIN;` | | |
| 2 | A | `SELECT balance FROM wallets WHERE id = p3_wallet('alice') FOR UPDATE;` | 1000.00, lock taken | `p3-06-1-a-lock.png` |
| 3 | B | `BEGIN;` | | |
| 4 | B | `SELECT balance FROM wallets WHERE id = p3_wallet('alice') FOR UPDATE;` | **waits** | `p3-06-2-b-waiting.png` |
| 5 | A | `SELECT post_pair('WALLET_WITHDRAWAL', p3_wallet('alice'), system_wallet('EXTERNAL'), 700, 'A');` | | |
| 6 | A | `COMMIT;` | B unblocks and returns 300.00 | `p3-06-3-b-unblocked.png` (tab B result) |
| 7 | B | `ROLLBACK;` | | |

Then reset to 1000 and run, one at a time, in tab A:

| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 8 | A | `SELECT withdraw_safe(p3_wallet('alice'), 700);` | succeeds | |
| 9 | A | `SELECT withdraw_safe(p3_wallet('alice'), 700);` | `Insufficient funds: balance 300.00, requested 700` | `p3-06-4-withdraw-safe.png` (Messages) |

### 3d. Fix 2: optimistic locking with the version column
Reset to 1000, then:

| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `SELECT balance, version FROM wallets WHERE id = p3_wallet('alice');` | note the version, call it V | `p3-07-1-a-read.png` |
| 2 | B | `SELECT balance, version FROM wallets WHERE id = p3_wallet('alice');` | same V | `p3-07-2-b-read.png` |
| 3 | A | `UPDATE wallets SET balance = 300 WHERE id = p3_wallet('alice') AND version = V;` (use the real number) | Messages: 1 row affected | `p3-07-3-a-update.png` |
| 4 | B | the same UPDATE with the same V | Messages: **0 rows affected**, a conflict | `p3-07-4-b-conflict.png` |
| 5 | B | `SELECT balance, version FROM wallets WHERE id = p3_wallet('alice');` | 300.00 and version V+1 | `p3-07-5-b-reread.png` |

## Scenario 4: isolation levels

### 4a. Non repeatable read (READ COMMITTED)
Reset to 1000, then:

| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `BEGIN ISOLATION LEVEL READ COMMITTED;` | | |
| 2 | A | `SELECT balance FROM wallets WHERE id = p3_wallet('alice');` | 1000.00 | `p3-08-1-a-first-read.png` |
| 3 | B | `SELECT post_pair('WALLET_FUNDING', system_wallet('EXTERNAL'), p3_wallet('alice'), 500, 'top up');` | a number | |
| 4 | A | the SELECT from row 2 again | **1500.00**, a different answer inside one transaction | `p3-08-2-a-second-read.png` |
| 5 | A | `COMMIT;` | | |

### 4b. REPEATABLE READ
| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | | |
| 2 | A | `SELECT balance FROM wallets WHERE id = p3_wallet('alice');` | 1500.00 | `p3-09-1-a-read.png` |
| 3 | B | `SELECT post_pair('WALLET_FUNDING', system_wallet('EXTERNAL'), p3_wallet('alice'), 500, 'top up');` | a number | |
| 4 | A | the SELECT from row 2 again | still 1500.00 | `p3-09-2-a-read-again.png` |
| 5 | A | `UPDATE wallets SET balance = balance WHERE id = p3_wallet('alice');` | `could not serialize access due to concurrent update` | `p3-09-3-a-error.png` (Messages) |
| 6 | A | `ROLLBACK;` | | |

### 4c. Write skew
Rule: the total of one borrower's OPEN requests must not exceed NGN 1,000,000. First, in either tab: `SELECT p3_cleanup_requests();`

Run 1, REPEATABLE READ:

| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | | |
| 2 | A | `SELECT COALESCE(sum(amount),0) FROM loan_requests WHERE borrower_id = p3_user('borrower') AND status = 'OPEN';` | 0 | `p3-10-1-a-sum.png` |
| 3 | B | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | | |
| 4 | B | the same SELECT | 0 | `p3-10-2-b-sum.png` |
| 5 | A | `INSERT INTO loan_requests (borrower_id, amount, purpose, tenor_weeks, interest_rate_pct, expires_at) VALUES (p3_user('borrower'), 600000, 'RENT', 12, 8, now() + interval '14 days');` | 1 row | |
| 6 | B | the same INSERT | 1 row | |
| 7 | A | `COMMIT;` | | |
| 8 | B | `COMMIT;` | both succeed | |
| 9 | either | `SELECT sum(amount) FROM loan_requests WHERE borrower_id = p3_user('borrower') AND status = 'OPEN';` | **1200000.00**, the rule is broken | `p3-10-3-result.png` |

Then `SELECT p3_cleanup_requests();`

Run 2, SERIALIZABLE: repeat rows 1 to 8 with `BEGIN ISOLATION LEVEL SERIALIZABLE;`.

| # | Tab | What happens | SCREENSHOT |
|---|---|---|---|
| 5 to 8 | A and B | One tab fails with `could not serialize access due to read/write dependencies among transactions` (it may appear at the INSERT or at the COMMIT). Run `ROLLBACK;` in that tab. | `p3-11-1-error.png` (Messages of the failing tab, showing which tab) |
| 9 | either | After a cleanup, the total shows at most 600000.00: `SELECT sum(amount) FROM loan_requests WHERE borrower_id = p3_user('borrower') AND status = 'OPEN';` (run before the cleanup) | `p3-11-2-result.png` |

The application would retry the failed transaction; on retry it sees 600,000 and declines. Finish with `SELECT p3_cleanup_requests();`

## Scenario 5: deadlock

The delay is 20 seconds so there is time to switch tabs. Reset both wallets:

```sql
SELECT p3_reset_wallet('alice', 1000), p3_reset_wallet('bob', 1000);
```

### 5a. Deadlock (locks taken in opposite order)
| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `BEGIN;` | | |
| 2 | A | `SELECT transfer_naive(p3_wallet('alice'), p3_wallet('bob'), 100, 20);` | starts running | `p3-12-1-a-running.png` |
| 3 | B | quickly: `BEGIN;` | | |
| 4 | B | `SELECT transfer_naive(p3_wallet('bob'), p3_wallet('alice'), 100, 20);` | starts running | `p3-12-2-b-running.png` |
| 5 | wait | within about 20 seconds one tab reports `deadlock detected` (SQLSTATE 40P01) | | `p3-12-3-deadlock-error.png` (Messages of that tab) |
| 6 | survivor | `COMMIT;` | | |
| 7 | the tab that failed | `ROLLBACK;` | | |

### 5b. Fix: consistent lock order
Reset both wallets, then:

| # | Tab | Run | Expected | SCREENSHOT |
|---|---|---|---|---|
| 1 | A | `BEGIN;` | | |
| 2 | A | `SELECT transfer(p3_wallet('alice'), p3_wallet('bob'), 100, 20);` | starts running | |
| 3 | B | `BEGIN;` | | |
| 4 | B | `SELECT transfer(p3_wallet('bob'), p3_wallet('alice'), 100, 20);` | **waits** (no deadlock) | `p3-13-1-b-waiting.png` |
| 5 | A | `COMMIT;` (when its call finishes) | | |
| 6 | B | `COMMIT;` (when its call finishes) | both succeed, no error | `p3-13-2-both-done.png` (B's result and Messages) |

## Final check

```sql
SELECT count(*) AS out_of_balance FROM wallet_reconciliation WHERE difference <> 0;
```
Expected: `0`. Screenshot `p3-16-final-check.png`.
