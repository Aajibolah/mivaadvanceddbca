# Portfolio 2: Query Processing and Optimisation (Copay)

Same Copay database as Portfolio 1, loaded with about 3,200 users, 6,000 loan requests, 4,000+ loans, 40,000+ repayments and 180,000 ledger entries, so that plans are meaningful.

## Files

| File | Purpose |
|---|---|
| [queries.sql](queries.sql) and [queries/](queries/) | 14 queries (12 numbered, two with variants) covering joins, aggregates, window functions, CTEs, subqueries, reconciliation and search |
| [indexes.sql](indexes.sql) / [indexes_drop.sql](indexes_drop.sql) | The performance indexes and the script that removes them again |
| [run_plans.ps1](run_plans.ps1) | Captures `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` for every query into `plans/` |
| [summarise_plans.py](summarise_plans.py) | Reads the saved plans and writes `performance-summary.md` (before and after table) |
| [materialised_view.sql](materialised_view.sql), [matview_demo.sql](matview_demo.sql) | Admin dashboard view, refresh strategy, timing comparison |
| [statistics.sql](statistics.sql) | Planner statistics, extended statistics, estimate against actual |
| [performance-analysis.md](performance-analysis.md) | Reasoning for each optimisation and a place for your measured results |
| `plans/`, `evidence/` | Saved plans and screenshots (empty until you run them) |

## The queries

| # | Business question | Concepts |
|---|---|---|
| Q1 | Wallet statement with balance after each movement | join, CTE, window function, LIMIT |
| Q2 | Open loan marketplace with filters | filtering, sorting, LEFT JOIN |
| Q3 | Lender portfolio summary | join, GROUP BY, DISTINCT aggregate |
| Q4 | Overdue repayments report | join, aggregate, date arithmetic |
| Q5 | Top borrowers by repayment rate | CTE, FILTER, `rank()`, `ntile()` |
| Q6 | Monthly disbursement and repayment totals | two CTEs, FULL JOIN, running total |
| Q7 | Reconciliation: balance against ledger | aggregate, HAVING |
| Q8 | Search users by part of a name | `ILIKE` substring search |
| Q9a, Q9b | Large lenders: correlated subquery against join | query rewriting |
| Q10 | Exact name lookup ignoring case | expression predicate |
| Q11 | A lender's fundings, two columns | covering index |
| Q12a, Q12b | Filter on a common value and on a rare value | when an index is not used |

## How to run

Prerequisites: Portfolio 1 loaded (`generate_seed.py --reset`), `psql` on the PATH and the `PG*` variables set (see [docs/SETUP_WINDOWS.md](../docs/SETUP_WINDOWS.md)).

```powershell
cd portfolio-2-query-optimisation
psql -f queries.sql                      # run all queries once, see the results
.\run_plans.ps1 -Phase before            # drops indexes, saves plans\before_*.txt
.\run_plans.ps1 -Phase after             # creates indexes, saves plans\after_*.txt
python summarise_plans.py                # writes performance-summary.md
psql -f materialised_view.sql
psql -f matview_demo.sql
psql -f statistics.sql
```

If PowerShell blocks the script: `powershell -ExecutionPolicy Bypass -File .\run_plans.ps1 -Phase before`.

Indexes can be applied one at a time to show each effect. Open `indexes.sql`, run a single `CREATE INDEX`, then `EXPLAIN (ANALYZE, BUFFERS)` the matching query from `queries/`.

## Index types demonstrated

| Type | Index | Query |
|---|---|---|
| B-tree, composite and covering | `ledger_entries (wallet_id, created_at DESC, id DESC) INCLUDE (txn_id, amount)` | Q1 |
| Partial | `loan_requests (created_at DESC) WHERE status = 'OPEN'` | Q2 |
| Partial and covering | `repayment_schedules (due_date) INCLUDE (...) WHERE status <> 'PAID'` | Q4 |
| Covering (`INCLUDE`) | `loan_fundings (lender_id) INCLUDE (loan_request_id, amount)` | Q3, Q9a, Q11 |
| Foreign key B-tree | `loans (borrower_id)` | Q5 |
| GIN trigram | `users USING gin (full_name gin_trgm_ops)` | Q8 |
| Expression | `users (lower(full_name))` | Q10 |
| Index that is not used | `users (status)` | Q12a (not used), Q12b (used) |

## Evidence to capture

| File | Command | Show |
|---|---|---|
| `evidence/p2-01-plan-q01-before.png` | open `plans\before_q01_wallet_statement.txt` | Seq Scan, buffers, time |
| `evidence/p2-02-plan-q01-after.png` | open `plans\after_q01_wallet_statement.txt` | Index Only Scan, buffers, time |
| `evidence/p2-03-q09a-before-after.png` | both Q9a plans side by side | correlated subquery cost |
| `evidence/p2-04-trigram.png` | Q8 before and after | Bitmap Index Scan |
| `evidence/p2-05-index-not-used.png` | Q12a after | Seq Scan despite the index |
| `evidence/p2-06-summary-table.png` | `performance-summary.md` | the full table |
| `evidence/p2-07-matview.png` | `matview_demo.sql` | both execution times |
| `evidence/p2-08-index-sizes.png` | query in performance-analysis.md section 6 | index sizes |

## Notes

- The plans folder is empty on purpose. Plans produced by anyone else's machine would not be your evidence.
- `run_plans.ps1` runs each query twice and saves the second run, so timings are warm cache. Say so in the write up.
- The scripts were exercised once on a temporary PostgreSQL 18 cluster during development to confirm they run. Results from that cluster are not used anywhere.
