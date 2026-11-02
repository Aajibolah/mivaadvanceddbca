# Portfolio 3: Transactions and Concurrency (Copay)

Money moves in Copay only through transactions that either complete fully or leave no trace. This portfolio shows the atomic funding transaction, rollback and savepoints, the classic concurrency problems on wallets and loans, the controls that fix them, and idempotency for safe retries.

## Files

| File | Purpose |
|---|---|
| [00_functions.sql](00_functions.sql) | `fund_loan`, `disburse_loan`, `apply_repayment`, `withdraw_safe`, `transfer`, `transfer_naive`, `post_pair` |
| [01_test_fixtures.sql](01_test_fixtures.sql) | Three dedicated test users (alice, bob, borrower) and reset helpers. The seeded customers are never touched |
| [02_atomic_funding_and_rollback.sql](02_atomic_funding_and_rollback.sql) | Scenarios 1 and 2: commit, plain SQL version, rollback, SAVEPOINT |
| [03_lost_update.sql](03_lost_update.sql) | Scenario 3: lost update, the design's own defence, `FOR UPDATE`, optimistic version column |
| [04_isolation_levels.sql](04_isolation_levels.sql) | Scenario 4: non repeatable read, REPEATABLE READ, write skew, SERIALIZABLE |
| [05_deadlock.sql](05_deadlock.sql) | Scenario 5: deadlock and the consistent lock order fix |
| [06_idempotency.sql](06_idempotency.sql) | Scenario 6: idempotency keys on funding and repayment |
| [run_scenarios.py](run_scenarios.py) | Runs all scenarios with real concurrent connections and prints the outcome |
| [concurrency-guide.md](concurrency-guide.md) | Table of every scenario: Session A steps, Session B steps, expected output, screenshot name |
| [pgadmin-scenarios.md](pgadmin-scenarios.md) | Scenarios 3, 4 and 5 written for two pgAdmin Query Tool tabs, with ready to paste statements |
| `evidence/` | Screenshots and logs |

## Tools used and why

| Part | Tool | Reason |
|---|---|---|
| Loading the functions, the single session scenarios (1, 2, 6) and the automated runner `run_scenarios.py` | `psql` and Python from the command line | These are scripts, and the runner opens several real database connections at once, which a graphical client cannot do |
| Scenarios 3, 4 and 5 (lost update, isolation levels, deadlock) | pgAdmin 4 Query Tool, two tabs as Session A and Session B, **and** the command line (`psql` windows and `run_scenarios.py`) | I ran these scenarios both ways so that each result is confirmed by two different clients. See below for why I used pgAdmin |

**Why I switched to pgAdmin.** I started scenarios 3 to 5 in PowerShell and kept hitting errors. SQL typed at the PowerShell prompt before starting `psql` was read as a PowerShell command (`SELECT` is an alias of `Select-Object`), and psql-only commands such as `\gset` were easy to get wrong while moving between two windows. Those errors were about the tool, not the database, and they hid what the scenarios are meant to show.

**Why I kept using it.** Each pgAdmin Query Tool tab is its own database session, so Session A and Session B sit side by side exactly as the scenarios need. Results and error messages appear in separate panels, which makes a lock wait, a deadlock or a serialisation failure easy to see and to capture. The behaviour itself happens inside PostgreSQL and is the same whichever client sends the statements. I kept the command line reproduction too, and its log is in `evidence/run_scenarios.log`, so the results do not depend on a single tool. The statements I used in pgAdmin are in [pgadmin-scenarios.md](pgadmin-scenarios.md).

## How it works

### Atomic funding (`fund_loan`)
One call, one transaction. In order:
1. Lock the loan request row (`FOR UPDATE`), so lenders funding the same request queue.
2. Post a ledger transaction with two legs: lender wallet debited, ESCROW credited. The ledger trigger updates both balances. If the lender is short, the `wallets_balance_non_negative` CHECK fails and everything is undone.
3. Insert the `loan_fundings` row. Its trigger checks the rules (not your own request, KYC limit, no over funding), adds to `funded_amount` and changes the status to FUNDED when the request is full.

`02_atomic_funding_and_rollback.sql` also shows the same operation as a single plain SQL statement using data modifying CTEs inside `BEGIN ... COMMIT`.

### Why a function and not only application code
The function keeps the whole business transaction inside the database in one round trip, so there is no window in which an application crash could leave a debit without a credit. The rules are also in triggers and constraints, so a different caller cannot bypass them.

### Concurrency controls used

| Problem | Where | Control |
|---|---|---|
| Overdraft by two simultaneous withdrawals | wallets | CHECK constraint with delta updates, plus `FOR UPDATE` in `withdraw_safe` |
| Over funding by two lenders | loan requests | row lock in the funding trigger |
| Stale read overwritten | wallets | optimistic `version` column (bumped by trigger) |
| Cross row rule (total open requests) | loan requests | SERIALIZABLE with retry |
| Deadlock between transfers | wallets | lock ordering (`transfer`) |
| Duplicate request on retry | fundings, repayments | unique idempotency keys |

### Lock order rule
Every function locks the loan request first, then wallets in a fixed order. This is why `fund_loan` and `disburse_loan` cannot deadlock with each other.

### Known limitation
Every funding and disbursement updates the one ESCROW wallet row, so those operations serialise on it. That is fine at Copay's size. At larger scale, use one escrow sub account per loan request. This is noted in [concurrency-guide.md](concurrency-guide.md).

## How to run

```powershell
cd portfolio-3-transactions-concurrency
psql -v ON_ERROR_STOP=1 -f 00_functions.sql
psql -v ON_ERROR_STOP=1 -f 01_test_fixtures.sql
psql -f 02_atomic_funding_and_rollback.sql
psql -f 06_idempotency.sql
python run_scenarios.py | Tee-Object evidence\run_scenarios.log
```

Scenarios 3, 4 and 5 need two windows: follow the numbered steps inside each file, and the table in [concurrency-guide.md](concurrency-guide.md).

## Evidence

| Files | Tool | Shows |
|---|---|---|
| `evidence/p3-01-atomic-funding.png`, `p3-02-rollback.png`, `p3-03-savepoint.png` | terminal, `02_atomic_funding_and_rollback.sql` | atomic funding, nothing changed after a failed funding, and a savepoint keeping the good part of a transaction |
| `evidence/p3-04-lost-update-a.png`, `p3-04-lost-update-b.png` | pgAdmin | two sessions overwrite each other: the cached balance is 300 while the ledger says 1000, and the reconciliation difference is minus 700 |
| `evidence/p3-05-1` to `p3-05-6` | pgAdmin | the ledger and its CHECK constraint refuse the second withdrawal, which waits for the first and is then rejected; balance and ledger agree |
| `evidence/p3-06-1` to `p3-06-4` | pgAdmin | pessimistic locking: the second session waits, then sees the true balance of 300; `withdraw_safe` gives a clear insufficient funds message |
| `evidence/p3-07-1` to `p3-07-5` | pgAdmin | optimistic locking: the update with the old version number changes 0 rows, and the re-read shows version 52 |
| `evidence/p3-08-1`, `p3-08-2`, `p3-09-1` to `p3-09-3` | pgAdmin | READ COMMITTED returns 1000 then 1500; REPEATABLE READ keeps 1500 and refuses a write to a changed row |
| `evidence/p3-10-1` to `p3-10-3`, `p3-11-1`, `p3-11-2` | pgAdmin | write skew: both sessions pass the rule check and the total becomes 1,200,000; under SERIALIZABLE one is refused and the total stays 600,000 |
| `evidence/p3-12-1`, `p3-12-2`, `p3-12-4`, `p3-13-2` | pgAdmin | two transfers in opposite directions, one of which fails with a deadlock; the ordered version completes |
| `evidence/p3-14-idempotency.png` | terminal, `06_idempotency.sql` | a retried request charges once, and repayments are applied oldest first |
| `evidence/p3-15-run-scenarios-a.png`, `p3-15-run-scenarios-b.png`, `evidence/run_scenarios.log` | terminal, `run_scenarios.py` | every scenario reproduced with real concurrent connections, including `DeadlockDetected (40P01)` and the SERIALIZABLE retry |
| `evidence/p3-16-final-check.png` | pgAdmin | no wallet is out of balance after all scenarios |

The deadlock error message itself is recorded in `evidence/run_scenarios.log` and in `p3-15-run-scenarios-b.png`.

## Testing

I ran every script and every scenario myself, in pgAdmin and from the command line, and the screenshots above come from those runs. Running them found and fixed a bug in `disburse_loan` (an invalid repayment schedule insert) before the scenarios were captured.
