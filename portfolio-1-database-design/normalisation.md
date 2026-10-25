# Normalisation of the Copay design

This note shows how the Copay schema was reached from a flat "loan sheet", the kind of spreadsheet a small lending group might keep before moving to a database. It then records where the design is deliberately denormalised and how that is protected.

## 1. Unnormalised sheet (UNF)

One row per loan, with repeating groups for lenders and instalments:

| loan_id | borrower_name | borrower_phone | borrower_kyc | amount | tenor_weeks | lenders (repeating) | instalments (repeating) |
|---|---|---|---|---|---|---|---|
| 1001 | Ngozi Okafor | +2348031112222 | VERIFIED | 200000 | 12 | Aisha Bello: 120000; Tunde Ajayi: 80000 | 1: 2026-03-07, 18500, PAID; 2: 2026-03-14, 18500, PAID; ... |

Problems: repeating groups cannot be queried or constrained; the borrower's name, phone and KYC are repeated on every loan (update anomaly); a lender with no loan yet cannot be stored (insertion anomaly); deleting the only loan of a user loses the user (deletion anomaly).

## 2. First normal form (1NF): remove repeating groups

Every cell holds one atomic value and each row is identified by a key. The repeating groups become their own rows:

- `loan(loan_id, borrower_name, borrower_phone, borrower_kyc, amount, tenor_weeks)`
- `loan_lender(loan_id, lender_name, lender_phone, lender_amount)` key `(loan_id, lender_phone)`
- `instalment(loan_id, instalment_no, due_date, amount_due, status)` key `(loan_id, instalment_no)`

## 3. Second normal form (2NF): remove partial dependencies

In `loan_lender` with composite key `(loan_id, lender_phone)`:

- `lender_name` depends on `lender_phone` only. That is a partial dependency.
- `lender_amount` depends on the whole key, so it stays.

Functional dependencies found:

- `lender_phone -> lender_name`
- `(loan_id, lender_phone) -> lender_amount`

Fix: move lender attributes to a `users` table. `loan_lender` keeps only the key parts and the amount. This becomes `loan_fundings(loan_request_id, lender_id, amount)`.

## 4. Third normal form (3NF): remove transitive dependencies

In `loan`, `borrower_name`, `borrower_phone` and `borrower_kyc` depend on the borrower, not on the loan:

- `loan_id -> borrower_id -> (name, phone, kyc status)`

Fix: store the borrower once in `users` and `kyc_profiles`, and keep only `borrower_id` as a foreign key in `loan_requests` and `loans`. KYC is split from `users` because it has its own lifecycle (status, level, verified date) and is only meaningful for some users.

In `instalment`, the status is derived from amount paid versus amount due plus the date. It is kept because it is updated by events (and indexed in Portfolio 2), and a CHECK constraint (`schedule_paid_iff_status`) stops it drifting from the amounts.

## 5. Resulting relations and keys

| Relation | Primary key | Candidate and foreign keys |
|---|---|---|
| users | id | email, phone unique |
| kyc_profiles | user_id | FK users |
| wallets | id | FK users; unique wallet per user and per system kind |
| loan_requests | id | FK users (borrower) |
| loan_fundings | id | FK loan_requests, users (lender), ledger_transactions; idempotency_key unique |
| loans | id | loan_request_id unique, FK users |
| repayment_schedules | id | (loan_id, instalment_no) unique |
| repayments | id | FK schedule, loan, payer, ledger_transactions |
| ledger_transactions, ledger_entries | id | entries FK transaction and wallet |

All determinants are candidate keys in these relations, so they are also in Boyce-Codd normal form. The loan request and the loan are separate relations on purpose: a request exists before there is a loan, and many requests never become one.

## 6. Deliberate denormalisation

| Item | Why | Protection |
|---|---|---|
| `wallets.balance` | The balance is derivable as `SUM(ledger_entries.amount)`, but summing every entry on every read would be slow for active wallets. A cached value gives O(1) reads and lets a CHECK constraint forbid negative balances. | An AFTER INSERT trigger on `ledger_entries` applies each entry to the wallet inside the same transaction; ledger rows cannot be updated or deleted; the `wallet_reconciliation` view proves cache equals ledger (`WHERE difference <> 0` must return no rows). |
| `loan_requests.funded_amount` and `status` | Avoids summing fundings to show marketplace progress. | Updated by the funding trigger under a row lock; CHECK constraints bound it between 0 and the amount. |
| `repayment_schedules.amount_paid` and `status` | Fast "what is due" queries. | Updated by the repayment trigger; CHECK constraint ties status to amounts. |
| `loans.platform_fee` | Fee is also in `fees` and the ledger. Kept on the loan for reporting. | Written in the same disbursement transaction. |

Denormalised data is acceptable only because every cached value has a single writer (a trigger) and a way to prove it correct.
