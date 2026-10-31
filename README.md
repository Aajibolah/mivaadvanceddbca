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
| System of record | PostgreSQL 18 (native Windows install) | Portfolios 1, 2, 3, 5 |
| Document store | MongoDB Community Server 7 or later (native Windows install) | Portfolio 4 only |
| Seed and utility scripts | Python 3.11+ (`psycopg`, `Faker`, `pymongo`), PowerShell | Portfolios 1 to 5 |
| Extra PostgreSQL instances | `initdb` on several ports (replica, shards) | Portfolio 5 |

PostgreSQL holds money, balances and the ledger, where ACID guarantees and constraints matter. MongoDB holds document shaped data (activity events, notifications, flexible loan application payloads). The work is done without Docker (the development laptop cannot run it); `docker-compose.yml` remains as an optional alternative for PostgreSQL only. The brief suggests PostgreSQL 16; the project uses 18 because that is what is installed, and every feature used exists in 16 and later.

## Repository map

| Folder | Content |
|---|---|
| [portfolio-1-database-design](portfolio-1-database-design/) | Requirements, ER diagram, schema with triggers, normalisation, seed generator, rule tests |
| [portfolio-2-query-optimisation](portfolio-2-query-optimisation/) | 14 queries, execution plans before and after indexing, materialised view, statistics, performance analysis |
| [portfolio-3-transactions-concurrency](portfolio-3-transactions-concurrency/) | Atomic funding, rollback, lost update, isolation levels, deadlock, idempotency, scenario runner |
| [portfolio-4-nosql](portfolio-4-nosql/) | MongoDB collections, validation, aggregation, indexes, graph traversal, JSONB comparison |
| [portfolio-5-distributed-cloud](portfolio-5-distributed-cloud/) | Replication, failover, partitioning, sharding with two phase commit, backup and restore, cloud design |
| [docs](docs/) | Windows setup guide and the final documentation |

## How to run

Full instructions: [docs/SETUP_WINDOWS.md](docs/SETUP_WINDOWS.md). In short:

1. Install PostgreSQL (already present), Python 3.11+, and for Portfolio 4 MongoDB Community Server and `mongosh`.
2. Create the `copay` database and a `copay_admin` role, copy `.env.example` to `.env`, create the Python venv and `pip install -r requirements.txt`.
3. Load order, one portfolio at a time:

| Step | Command (from the repository root) |
|---|---|
| P1 schema and data | `python portfolio-1-database-design\seed\generate_seed.py --reset` (add `--users 600` for the small version) |
| P1 tests | `psql -f portfolio-1-database-design\rule_tests.sql` |
| P2 plans | `cd portfolio-2-query-optimisation` then `.\run_plans.ps1 -Phase before`, `.\run_plans.ps1 -Phase after`, `python summarise_plans.py` |
| P3 | `psql -f portfolio-3-transactions-concurrency\00_functions.sql`, `01_test_fixtures.sql`, then the scenario files and `python portfolio-3-transactions-concurrency\run_scenarios.py` |
| P4 | `mongosh --file portfolio-4-nosql\schema-validation.js`, `python portfolio-4-nosql\seed_from_postgres.py --reset --also-jsonb`, `queries.js`, `explain.js` |
| P5 | see [portfolio-5-distributed-cloud/README.md](portfolio-5-distributed-cloud/README.md) |

## Tools used and why

I used more than one tool in this project, and I moved between them on purpose. This section explains what I used for each part and why.

| Tool | Used for | Why |
|---|---|---|
| `psql` and PowerShell | Loading schemas and functions, running SQL files, the plan capture script, the replication, sharding and backup scripts | Scripts must be repeatable and the Portfolio 5 scripts start and stop extra PostgreSQL servers, which only a shell can do |
| Python (run from the terminal or VS Code) | The seed generators, the concurrent scenario runner `run_scenarios.py`, the MongoDB seeder | The data generation is code, and the scenario runner opens several real connections at the same time |
| pgAdmin 4 (Query Tool) | The two session concurrency scenarios in Portfolio 3 (lost update, isolation levels, deadlock), and queries against the extra PostgreSQL instances | Two Query Tool tabs give me Session A and Session B side by side, with results and errors in separate panels. See "Why I used pgAdmin for the concurrency scenarios" below. |
| MongoDB Compass or `mongosh` | Portfolio 4 collections, queries and explain output | pgAdmin only connects to PostgreSQL, so the document database needs its own client |
| mermaid.live | The ER diagram image exported from the Mermaid source in `er-diagram.md` | Renders the diagram text to a PNG |

### Why I used pgAdmin for the concurrency scenarios

I ran concurrency scenarios 3, 4 and 5 of Portfolio 3 (lost update, isolation levels and deadlock) in **two** ways: in pgAdmin 4, and from the command line with `psql` and my Python runner `run_scenarios.py`. Every result is therefore confirmed by two different clients.

**Why I switched to pgAdmin in the first place.** I started these scenarios in PowerShell and kept hitting errors. Anything I typed at the PowerShell prompt before starting `psql` was read as a PowerShell command, not SQL (`SELECT` is an alias of `Select-Object` in PowerShell), and the psql-only commands such as `\gset` were easy to get wrong while moving between two windows. The errors were about the tool, not about the database, and they were getting in the way of what the scenarios are meant to show.

**Why I kept using it.** In pgAdmin every Query Tool tab is its own database session, so Session A and Session B sit side by side exactly as the scenarios need. Results and error messages appear in separate panels, so a lock wait, a deadlock or a serialisation failure is easy to see and to capture in a screenshot. The behaviour I am demonstrating (row locks, isolation levels, deadlock detection) happens inside PostgreSQL, so it is the same whichever client sends the statements. I kept the command line reproduction as well so the results do not depend on one client, and I used each tool where it fits best: scripts and automation in the terminal, interactive two session work in pgAdmin.

Each portfolio README states which tool produced which screenshot.

## Progress checklist

- [x] Phase 0: repository structure, case study
- [ ] Phase 1: Portfolio 1, database design and modelling (code and documents written; run it, capture the evidence in `portfolio-1-database-design/evidence/`, export the ER diagram PNG)
- [ ] Phase 2: Portfolio 2, query processing and optimisation (run the plan scripts yourself, fill in `performance-analysis.md`)
- [ ] Phase 3: Portfolio 3, transactions and concurrency (run the scenarios, capture screenshots)
- [ ] Phase 4: Portfolio 4, NoSQL and advanced data models (install MongoDB, run the scripts, capture screenshots)
- [ ] Phase 5: Portfolio 5, distributed and cloud database exercise (run the scripts, capture screenshots)
- [ ] Phase 6: final documentation, reflection and checklist

## Testing approach

Each portfolio folder has scripts that check themselves and print PASS or MATCH lines: `rule_tests.sql` (19 business rule tests and the reconciliation), `run_scenarios.py` (nine concurrency scenarios with real concurrent connections and a final integrity check), the validators in `schema-validation.js` (five rejected documents), `backup_restore_test.ps1` (ten checks between source and restored copy), and the seed generators, which re-verify reconciliation after loading. Every result in this repository must come from a command that was actually run on the student's machine; the `evidence/` folders hold the screenshots and logs.

## Design decisions

- **Rules in the database.** Constraints and triggers enforce the business rules, so no client can bypass them (Portfolio 1).
- **Double entry ledger with a cached balance.** Reconciliation proves the cache; the ledger is append only.
- **Indexes added later, measured.** Portfolio 1 has only integrity indexes so that Portfolio 2's before and after plans are honest.
- **Defence in depth against concurrency bugs.** Delta updates with a CHECK constraint, row locks, optimistic versions, SERIALIZABLE with retry, lock ordering and idempotency keys (Portfolio 3).
- **PostgreSQL for money, MongoDB for documents.** The split is justified entity by entity and compared with JSONB (Portfolio 4).
- **Money is CP, the rest is AP.** Synchronous replication for wallet writes, asynchronous for everything else; cross shard transfers by saga (Portfolio 5).

## References

- PostgreSQL Global Development Group, *PostgreSQL 18 Documentation*: https://www.postgresql.org/docs/18/ (chapters on constraints, triggers, concurrency control, performance tips, indexes, high availability, partitioning, `postgres_fdw`, continuous archiving and PITR).
- MongoDB Inc., *MongoDB Manual*: https://www.mongodb.com/docs/manual/ (schema validation, aggregation pipeline, indexes, TTL indexes, `$graphLookup`, replication, read and write concern).
- Python libraries: psycopg 3 (https://www.psycopg.org/psycopg3/docs/), PyMongo (https://pymongo.readthedocs.io/), Faker (https://faker.readthedocs.io/).
- Add here the textbooks and course materials you actually used, for example the prescribed database textbook and *Designing Data Intensive Applications* by M. Kleppmann if you read it.
- Nigeria Data Protection Act 2023, for the data residency discussion in Portfolio 5.

## AI Use Declaration

> Draft for the student to confirm. Keep only statements that are true; edit anything that is not.

1. **Tool used:** Claude (Anthropic), via Claude Code.
2. **What it was used for:** drafting the SQL schema and scripts, the Python seed and scenario scripts, the PowerShell scripts, the MongoDB scripts and the explanatory documentation templates, under my direction and following the assessment brief.
3. **How I reviewed, corrected, tested and verified it:** [CONFIRM AND COMPLETE AFTER YOU HAVE DONE THESE THINGS] I ran every script on my own machine, captured all outputs and screenshots myself, read and modified the code, and can explain each design choice. The technical reflection is written by me without AI assistance.
