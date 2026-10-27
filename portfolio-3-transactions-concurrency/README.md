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
| `evidence/` | Your screenshots and logs |

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

## Evidence to capture

See the last column of the table in [concurrency-guide.md](concurrency-guide.md) (screenshots `p3-01` to `p3-15` and `evidence/run_scenarios.log`).

## Testing

The functions and `run_scenarios.py` were run end to end on a temporary PostgreSQL 18 cluster during development. That run found and fixed a bug (an invalid schedule insert in `disburse_loan`) before delivery. The scenario outputs are reproducible, but the evidence in your submission must come from your own runs.
