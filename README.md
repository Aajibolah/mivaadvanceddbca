# Copay: Advanced Database Systems Portfolio

**Course:** MIT 8103 Advanced Database Systems, First Semester Continuous Assessment, 2026/2027
**Institution:** Miva Open University (Master of Information Technology)
**Student:** Azeez Akande
**Assessment:** Individual Practical Database Portfolio (40 marks)

## Case study

**Organisation:** Copay (a simulated but realistic Nigerian peer to peer lending platform).

**Nature of the business:** Copay is a marketplace where people can source money from other people to pay for things, and then pay it back. It is lending, but from another person rather than from a bank: Copay brings **lenders and borrowers together**. A borrower posts a loan request (amount, purpose, tenor, proposed interest). One or more lenders fund it from their Copay wallets. The borrower repays in instalments through the platform, and the platform records everything in a ledger and takes a small service fee.

**Users of the database:** between **600 and 3,200 registered users** (borrowers, lenders, and some who are both), plus admin and support staff and a back office reconciliation job. The seed data uses roughly 3,200 users, and the design is also shown to work at the 600 user end.

**Major data stored:** users and KYC status, wallets and balances, funding sources and bank accounts, loan requests, offers and funding, loans, repayment schedules, repayments, ledger transactions, fees, credit and trust scores, disputes, notifications and audit logs.

**Key operations the database supports:**

- Write: register users, fund wallets, create loan requests, fund loans, record repayments.
- Read: wallet balance, statements, open loan marketplace, repayment schedule, lender portfolio, admin reports.
- Update: loan status changes, wallet balance movements, KYC status, repayment status.
- Deletes are mostly soft deletes, because financial records must be retained.

### Business rules the design enforces

- A wallet balance can never go below zero.
- Money is never created or destroyed. Every transfer is a double entry pair of ledger rows that sum to zero, and a wallet balance must equal the sum of its ledger entries (a reconciliation query proves this).
- A loan request can only be funded up to its requested amount, and becomes `FUNDED` only when fully funded.
- A user cannot lend to their own request.
- Only KYC verified users can lend or borrow above a set limit.
- Repayments are applied to the oldest unpaid instalment first.
- Amounts use `NUMERIC(14,2)` and the currency is NGN. Floats are never used for money.
- Ledger rows are append only (no updates or deletes), enforced with a trigger.

## Architecture overview

| Component | Technology | Used in |
|---|---|---|
| System of record | PostgreSQL 16 | Portfolios 1, 2, 3, 5 |
| Document store | MongoDB (single container) | Portfolio 4 only |
| Seed and utility scripts | Python 3.11+ (`psycopg`, `Faker`, `pymongo`) | Portfolios 1, 4 |
| Runtime | Docker Compose | All |

PostgreSQL holds money, balances and the ledger, where ACID guarantees and constraints matter. MongoDB holds document shaped data (activity events, notifications, flexible loan application payloads).

## Repository map

| Folder | Content |
|---|---|
| [portfolio-1-database-design](portfolio-1-database-design/) | Requirements, ER diagram, schema, constraints, normalisation, seed generator |
| [portfolio-2-query-optimisation](portfolio-2-query-optimisation/) | Queries, execution plans before and after indexing, materialised view, performance analysis |
| [portfolio-3-transactions-concurrency](portfolio-3-transactions-concurrency/) | Atomic funding, rollback, lost update, isolation levels, deadlock, idempotency |
| [portfolio-4-nosql](portfolio-4-nosql/) | MongoDB collections, validation, aggregation, indexes, JSONB comparison |
| [portfolio-5-distributed-cloud](portfolio-5-distributed-cloud/) | Replication, partitioning, sharding, backup and recovery, cloud discussion |
| [docs](docs/) | Final documentation and supporting notes |

## How to run

Prerequisites: Docker with Compose, Git, Python 3.11 or later, and a PostgreSQL client (`psql`).

```bash
cp .env.example .env        # then edit the password
docker compose up -d
docker compose ps           # postgres should report "healthy"
```

Script load order is documented in each portfolio README as the portfolios are completed.

## Progress checklist

- [x] Phase 0: repository structure, Docker Compose (PostgreSQL), case study
- [ ] Phase 1: Portfolio 1, database design and modelling
- [ ] Phase 2: Portfolio 2, query processing and optimisation
- [ ] Phase 3: Portfolio 3, transactions and concurrency
- [ ] Phase 4: Portfolio 4, NoSQL and advanced data models
- [ ] Phase 5: Portfolio 5, distributed and cloud database exercise
- [ ] Phase 6: final documentation and checklist

## Testing approach

Filled in per portfolio as each phase is completed. Every result in this repository comes from a command that was actually run, and outputs are stored as evidence files.

## Design decisions

Summarised here as each portfolio is completed. See the portfolio READMEs for the reasoning behind each decision.

## References

To be completed in the final phase.

## AI Use Declaration

To be completed and confirmed in the final phase.
