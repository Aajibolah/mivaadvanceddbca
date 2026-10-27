# Concurrency guide: what to run and what to capture

Open two `psql` windows (Session A and Session B). In each, set the connection variables (see [docs/SETUP_WINDOWS.md](../docs/SETUP_WINDOWS.md)). Before the first scenario, once:

```powershell
psql -v ON_ERROR_STOP=1 -f 00_functions.sql
psql -v ON_ERROR_STOP=1 -f 01_test_fixtures.sql
```

Scenario files contain the exact statements, as numbered steps with the session each belongs to. Statements starting with `-- 1. A:` are typed into Session A, and so on. Run them in the order given.

Name screenshots `p3-NN-description.png` and save them in `evidence/`. Also save full text logs where useful (`\o evidence/p3-xx.log`).

| # | Scenario | File | Session A | Session B | Expected output | Screenshot |
|---|---|---|---|---|---|---|
| 1 | Atomic funding (function and plain SQL) | `02_atomic_funding_and_rollback.sql` | run the file | none | funded_amount grows by 30000 then 5000; alice balance falls by the same amount; escrow rises | `p3-01-atomic-funding.png` |
| 2a | Rollback after failure | same file | run the file | none | bob's 20000 funding fails with a CHECK violation; new_ledger_txns, bob_balance_change, funded_change, bob_funding_rows all 0 | `p3-02-rollback.png` |
| 2b | SAVEPOINT partial rollback | same file | run the file | none | after the failed step is rolled back to the savepoint, the other fundings commit; funded_amount 50000, status FUNDED | `p3-03-savepoint.png` |
| 3a | Lost update (absolute write) | `03_lost_update.sql` Part 1 | read 1000, write 300 | read 1000, write 300 | final balance 300 after two 700 withdrawals; `wallet_reconciliation` difference is not 0 | `p3-04-lost-update.png` |
| 3b | Design defence (ledger delta + CHECK) | `03_lost_update.sql` Part 2 | withdraw 700 | blocks, then fails | B: `wallets_balance_non_negative` violation, balance 300, never negative | `p3-05-check-defence.png` |
| 3c | Fix: `SELECT ... FOR UPDATE` | `03_lost_update.sql` Fix 1 | lock, withdraw | blocks until A commits, then sees 300 | B receives a clean "Insufficient funds" decision | `p3-06-for-update.png` |
| 3d | Fix: optimistic version column | `03_lost_update.sql` Fix 2 | UPDATE ... WHERE version = V matches 1 row | `UPDATE 0` | B detects the conflict and re-reads | `p3-07-optimistic.png` |
| 4a | Non repeatable read | `04_isolation_levels.sql` 4a | reads 1000 then 1500 | commits +500 between | two different answers in one transaction | `p3-08-nonrepeatable.png` |
| 4b | REPEATABLE READ | same, 4b | reads 1500 twice | commits +500 | same answer twice; the UPDATE fails with a serialization error | `p3-09-repeatable-read.png` |
| 4c | Write skew, then SERIALIZABLE | same, 4c | check then insert 600000 | check then insert 600000 | RR: total 1,200,000 (rule broken). SERIALIZABLE: SQLSTATE 40001 on one session; retry declines | `p3-10-write-skew.png`, `p3-11-serializable.png` |
| 5a | Deadlock | `05_deadlock.sql` 5a | `transfer_naive(a,b,100,5)` | `transfer_naive(b,a,100,5)` | `ERROR: deadlock detected` SQLSTATE 40P01 | `p3-12-deadlock.png` |
| 5b | Lock ordering fix | `05_deadlock.sql` 5b | `transfer(a,b,100,5)` | `transfer(b,a,100,5)` | no error; B waits then completes | `p3-13-lock-order.png` |
| 6 | Idempotency | `06_idempotency.sql` | run the file | optional race | retries return the same funding id; one funding row; one debit; duplicate key rejected; repayment retry touches 0 instalments | `p3-14-idempotency.png` |
| All | Automated run of every scenario with real concurrent connections | `run_scenarios.py` | n/a | n/a | log ending with "wallets where cached balance differs from the ledger: 0" | `p3-15-run-scenarios.png` and `evidence/run_scenarios.log` |

## Capturing the log

```powershell
python portfolio-3-transactions-concurrency\run_scenarios.py | Tee-Object portfolio-3-transactions-concurrency\evidence\run_scenarios.log
```

`run_scenarios.py` is the repeatable proof; the two window sessions are the readable demonstration. Do both: the assessor can see you understand what each window is doing, and the log shows the same behaviour reproduced by code.

## Sizes of the effect

Do not be surprised if a scenario behaves slightly differently on your machine (for example, which of two deadlocked sessions is chosen as the victim). Record what actually happened and explain it.

## Explaining each scenario (use in your reflection and viva)

- **Atomicity:** the funding changes five things (lender wallet, escrow, ledger header and legs, funding record, request progress). They live in one transaction, so a failure part way leaves none of them changed.
- **Lost update:** two transactions read the same value and each writes a result based on it, so one write silently disappears. `READ COMMITTED` does not prevent it because each statement sees committed data, but nothing says the data read earlier is still current.
- **Why the ledger design already resists it:** the balance change is a delta applied by a trigger under a row lock, and the CHECK constraint refuses a negative balance. The lost update only appears when code overwrites the cached balance with an absolute value. Reconciliation exists to catch exactly that.
- **Pessimistic versus optimistic:** `FOR UPDATE` makes the second writer wait; the version column lets everyone proceed and rejects the stale writer. Pick pessimistic for hot rows, optimistic when conflicts are rare.
- **Isolation levels:** READ COMMITTED sees fresh data on each statement; REPEATABLE READ keeps one snapshot for the whole transaction; SERIALIZABLE additionally detects patterns such as write skew and aborts one transaction, which the application must retry.
- **Deadlock:** a cycle of waits. PostgreSQL detects it and aborts one participant. Prevent it by taking locks in a consistent order, keep transactions short, and retry on SQLSTATE 40P01.
- **Idempotency:** a unique key stored with the transaction makes retries safe. A second request with the same key, even if concurrent, finds the first and returns its result; a key reused with a different payload is rejected.
- **Hot row:** every funding and disbursement touches the single ESCROW wallet row, so those operations serialise on it. At Copay's scale (hundreds of fundings a day) this is acceptable; at larger scale use one escrow sub account per loan request.
