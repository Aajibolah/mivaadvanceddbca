# Running Copay on Windows without Docker

This project runs everything natively: PostgreSQL for Portfolios 1, 2, 3 and 5, and MongoDB Community Server for Portfolio 4. No containers, no virtualisation.

## 1. PostgreSQL

The development machine has PostgreSQL 18 installed at `C:\Program Files\PostgreSQL\18`. The brief suggests PostgreSQL 16; **this project uses PostgreSQL 18 and says so** (all features used exist in 16 and later). Record your exact version with `SELECT version();` in your evidence.

Add the client tools to the PATH for the current PowerShell window:

```powershell
$env:Path += ";C:\Program Files\PostgreSQL\18\bin"
psql --version
```

Create the project database and role (you will be asked for the `postgres` superuser password chosen at install):

```powershell
psql -U postgres -h localhost -c "CREATE ROLE copay_admin LOGIN SUPERUSER PASSWORD 'change_me';"
psql -U postgres -h localhost -c "CREATE DATABASE copay OWNER copay_admin;"
```

`SUPERUSER` is acceptable for a local coursework database. It lets the scripts create extensions (`pg_trgm`, `postgres_fdw`). Never do this on a shared server.

Copy `.env.example` to `.env` and set the same password. The Python scripts read `.env`. For `psql` and the PowerShell scripts, set the standard variables once per window:

```powershell
$env:PGHOST="localhost"; $env:PGPORT="5432"; $env:PGUSER="copay_admin"
$env:PGPASSWORD="change_me"; $env:PGDATABASE="copay"
```

Check: `psql -c "SELECT current_database(), version();"`

## 2. Python

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## 3. MongoDB (Portfolio 4 only)

1. Install **MongoDB Community Server** (Windows MSI, choose "Run as a Service") from mongodb.com/try/download/community.
2. Install the **MongoDB Shell (`mongosh`)** from mongodb.com/try/download/shell and make sure `mongosh` is on the PATH.
3. Check: `mongosh "mongodb://localhost:27017" --eval "db.runCommand({ping:1})"` returns `ok: 1`.
4. Optional: MongoDB Compass (installed with the server MSI) for screenshots of documents.

The scripts expect an instance without authentication on `localhost:27017`. If yours requires credentials, put them in `MONGO_URI` in `.env` and in the `mongosh` URI. Do not commit them.

## 4. Load order

```powershell
# Portfolio 1
python portfolio-1-database-design\seed\generate_seed.py --reset
psql -f portfolio-1-database-design\rule_tests.sql
# Portfolio 2
cd portfolio-2-query-optimisation; .\run_plans.ps1 -Phase before; .\run_plans.ps1 -Phase after; python summarise_plans.py; cd ..
# Portfolio 3
psql -f portfolio-3-transactions-concurrency\00_functions.sql
psql -f portfolio-3-transactions-concurrency\01_test_fixtures.sql
# Portfolio 4 (needs MongoDB)
mongosh --file portfolio-4-nosql\schema-validation.js
python portfolio-4-nosql\seed_from_postgres.py --reset --also-jsonb
# Portfolio 5
cd portfolio-5-distributed-cloud; .\replication\setup_replication.ps1
```

Each portfolio README gives the full steps and the evidence to capture.

## 5. Disk space

The test instances, dumps and MongoDB data need a few GB. Keep at least 5 GB free on C:. `portfolio-5-distributed-cloud\cleanup.ps1` removes the extra PostgreSQL instances, and `portfolio-5-distributed-cloud\backup\out\` can be emptied at any time.

## 6. Docker (optional)

`docker-compose.yml` is kept for anyone who does have Docker (PostgreSQL 16 only). It is not required and no evidence depends on it.
