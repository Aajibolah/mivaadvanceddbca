#!/usr/bin/env python3
"""
Portfolio 4 seeder: builds the MongoDB collections from the Copay PostgreSQL data,
so both databases describe the same users, loan requests and lenders.

    mongosh --file portfolio-4-nosql/schema-validation.js        # creates validated, empty collections
    python portfolio-4-nosql/seed_from_postgres.py --reset --also-jsonb

What comes from where
  notifications      <- PostgreSQL notifications (copied, reshaped)
  trust_graph_edges  <- PostgreSQL loan_fundings joined to loan_requests (aggregated per lender/borrower pair)
  activity_events    <- PostgreSQL audit_logs (copied) + generated app usage events (login, browsing)
  loan_applications  <- one per PostgreSQL loan_request; the nested payload is generated with Faker
                        because PostgreSQL deliberately has no place for it

Connection: PostgreSQL through PG*/DATABASE_URL/.env (as the other scripts);
MongoDB through MONGO_URI (default mongodb://localhost:27017). The generated
documents are deterministic for a given --seed.
"""
import argparse
import json
import os
import random
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import psycopg
from bson.decimal128 import Decimal128
from faker import Faker
from pymongo import MongoClient

ROOT = Path(__file__).resolve().parents[1]
DB_NAME = "copay_docs"
END = datetime(2026, 10, 15, 23, 0, tzinfo=timezone.utc)

FIRST = ["Adebayo", "Chinedu", "Ngozi", "Aisha", "Ibrahim", "Tolu", "Chioma", "Yusuf", "Kelechi", "Hauwa",
         "Segun", "Zainab", "Folake", "Uche", "Blessing", "Musa"]
LAST = ["Okafor", "Adeyemi", "Balogun", "Nwosu", "Abdullahi", "Eze", "Bello", "Lawal", "Chukwu", "Danjuma"]
RELATIONS = ["sibling", "parent", "friend", "colleague", "spouse", "employer"]
SEARCH_TERMS = ["school fees", "rent", "medical", "stock", "equipment", "travel", "low interest"]
DOC_TYPES = ["national_id", "utility_bill", "bank_statement", "payslip", "student_id", "cac_certificate"]


def load_dotenv():
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def pg_dsn():
    load_dotenv()
    g = os.environ.get
    return g("DATABASE_URL") or (
        f"host={g('PGHOST', 'localhost')} port={g('PGPORT', g('POSTGRES_PORT', '5432'))} "
        f"dbname={g('PGDATABASE', g('POSTGRES_DB', 'copay'))} user={g('PGUSER', g('POSTGRES_USER', 'copay_admin'))} "
        f"password={g('PGPASSWORD', g('POSTGRES_PASSWORD', ''))}")


def mongo_uri():
    load_dotenv()
    return os.environ.get("MONGO_URI", "mongodb://localhost:27017")


def to_bson(value):
    """Decimal -> Decimal128 so money keeps exact precision in MongoDB."""
    if isinstance(value, Decimal):
        return Decimal128(value)
    if isinstance(value, dict):
        return {k: to_bson(v) for k, v in value.items()}
    if isinstance(value, list):
        return [to_bson(v) for v in value]
    return value


def build_application(rng, fake, req):
    """A loan application whose shape depends on who is applying."""
    emp = rng.choices(["SALARIED", "SELF_EMPLOYED", "STUDENT", "CIVIL_SERVANT"], [40, 30, 15, 15])[0]
    applicant = {"employment_type": emp}
    if emp == "SALARIED":
        applicant["monthly_income_ngn"] = rng.randrange(150, 1200, 10) * 1000
        applicant["employer"] = {"name": fake.company(), "position": fake.job(),
                                 "years": rng.randint(1, 15), "hr_phone": f"+234{rng.randint(7000000000, 9099999999)}"}
    elif emp == "CIVIL_SERVANT":
        applicant["monthly_income_ngn"] = rng.randrange(80, 500, 10) * 1000
        applicant["employer"] = {"name": rng.choice(["Lagos State Civil Service", "Federal Ministry of Works",
                                                     "Kaduna State Civil Service"]),
                                 "grade_level": rng.randint(5, 16), "ippis_number": f"IP{rng.randint(10**6, 10**7 - 1)}"}
    elif emp == "SELF_EMPLOYED":
        applicant["monthly_income_ngn"] = rng.randrange(60, 1500, 10) * 1000
        applicant["business"] = {"name": fake.company(), "sector": rng.choice(["retail", "agro", "transport", "tech", "fashion"]),
                                 "years": rng.randint(1, 12), "cac_registered": rng.random() < 0.5}
    else:
        applicant["monthly_income_ngn"] = rng.randrange(0, 60, 5) * 1000
        applicant["school"] = {"name": rng.choice(["University of Lagos", "Ahmadu Bello University", "Covenant University",
                                                   "University of Nigeria"]), "level": rng.choice(["100", "200", "300", "400", "MSc"])}
    n_guarantors = rng.choices([0, 1, 2, 3], [20, 40, 30, 10])[0]
    guarantors = [{"name": f"{rng.choice(FIRST)} {rng.choice(LAST)}", "phone": f"+234{rng.randint(7000000000, 9099999999)}",
                   "relationship": rng.choice(RELATIONS)} for _ in range(n_guarantors)]
    submitted = req["created_at"]
    documents = [{"type": t, "uploaded_at": submitted + timedelta(minutes=rng.randint(1, 90)),
                  "verified": rng.random() < 0.8} for t in rng.sample(DOC_TYPES, rng.randint(1, 3))]
    doc = {
        "request_id": req["id"], "borrower_id": req["borrower_id"], "submitted_at": submitted,
        "requested_amount": req["amount"], "purpose": req["purpose"], "tenor_weeks": req["tenor_weeks"],
        "applicant": applicant, "guarantors": guarantors, "documents": documents,
        "device": {"os": rng.choice(["android", "ios", "web"]), "app_version": f"2.{rng.randint(0, 9)}.{rng.randint(0, 20)}",
                   "ip": fake.ipv4_public()},
        "risk_flags": rng.sample(["new_device", "high_amount", "first_loan", "income_unverified", "multiple_requests"],
                                 rng.randint(0, 2)),
    }
    return doc


def usage_events(rng, users):
    """Generated app usage: lots of small events, payload shape depends on the type."""
    events = []
    for uid, created in users:
        n = rng.randint(3, 40)
        span = max(1, int((END - created).total_seconds()))
        for _ in range(n):
            ts = created + timedelta(seconds=rng.randrange(span))
            kind = rng.choices(["LOGIN", "VIEW_MARKETPLACE", "VIEW_LOAN", "SEARCH", "WALLET_VIEW"], [30, 25, 20, 10, 15])[0]
            source = rng.choice(["mobile", "mobile", "web"])
            session = f"s{rng.getrandbits(40):010x}"
            if kind == "LOGIN":
                data = {"method": rng.choice(["password", "biometric", "otp"]), "success": rng.random() < 0.96,
                        "device": {"os": rng.choice(["android", "ios", "web"]), "app_version": f"2.{rng.randint(0, 9)}.{rng.randint(0, 20)}"}}
            elif kind == "VIEW_MARKETPLACE":
                data = {"filters": {"min_amount": rng.choice([20000, 50000, 100000]), "max_tenor_weeks": rng.choice([8, 12, 26])},
                        "results_shown": rng.randint(0, 20)}
            elif kind == "VIEW_LOAN":
                data = {"loan_request_id": rng.randint(1, 6000), "dwell_seconds": rng.randint(2, 240)}
            elif kind == "SEARCH":
                data = {"query": rng.choice(SEARCH_TERMS), "results": rng.randint(0, 30)}
            else:
                data = {}
            events.append({"user_id": uid, "type": kind, "ts": ts, "source": source, "session_id": session, "data": data})
    return events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--reset", action="store_true", help="empty the collections first (validators are kept)")
    ap.add_argument("--also-jsonb", action="store_true",
                    help="also store the same loan application documents in PostgreSQL (jsonb) for the comparison")
    args = ap.parse_args()
    rng = random.Random(args.seed)
    Faker.seed(args.seed)
    fake = Faker()

    mongo = MongoClient(mongo_uri(), serverSelectionTimeoutMS=5000)
    db = mongo[DB_NAME]
    missing = {"activity_events", "notifications", "loan_applications", "trust_graph_edges"} - set(db.list_collection_names())
    if missing:
        raise SystemExit(f"Collections {sorted(missing)} do not exist. Run schema-validation.js first.")
    if args.reset:
        for name in ("activity_events", "notifications", "loan_applications", "trust_graph_edges"):
            db[name].delete_many({})

    with psycopg.connect(pg_dsn()) as pg:
        cur = pg.cursor()

        cur.execute("SELECT id, user_id, type, title, body, read_at, created_at FROM notifications ORDER BY id")
        notes = []
        for pid, uid, ntype, title, body, read_at, created in cur.fetchall():
            channels = ["in_app"] + [c for c in ("push", "sms", "email") if rng.random() < {"push": 0.8, "sms": 0.2, "email": 0.3}[c]]
            notes.append({"pg_id": pid, "user_id": uid, "type": ntype, "title": title, "body": body,
                          "created_at": created, "read_at": read_at, "channels": channels})
        db.notifications.insert_many(notes)
        print(f"notifications      {len(notes):>8,}")

        cur.execute("""SELECT f.lender_id, r.borrower_id, count(*), sum(f.amount), min(f.created_at), max(f.created_at)
                         FROM loan_fundings f JOIN loan_requests r ON r.id = f.loan_request_id
                        GROUP BY f.lender_id, r.borrower_id""")
        edges = [to_bson({"lender_id": a, "borrower_id": b, "fundings": n, "total_amount": amt, "first_at": f, "last_at": l})
                 for a, b, n, amt, f, l in cur.fetchall()]
        db.trust_graph_edges.insert_many(edges)
        print(f"trust_graph_edges  {len(edges):>8,}")

        cur.execute("SELECT id, borrower_id, amount, purpose, tenor_weeks, created_at FROM loan_requests ORDER BY id")
        reqs = [dict(zip(("id", "borrower_id", "amount", "purpose", "tenor_weeks", "created_at"), r)) for r in cur.fetchall()]
        apps = [build_application(rng, fake, r) for r in reqs]
        db.loan_applications.insert_many([to_bson(a) for a in apps])
        print(f"loan_applications  {len(apps):>8,}")

        # users created after the simulation end (for example the Portfolio 3 test users) get no generated history
        cur.execute("SELECT id, created_at FROM users WHERE role = 'USER' AND created_at < %s ORDER BY id", (END,))
        users = cur.fetchall()
        events = usage_events(rng, users)
        cur.execute("SELECT actor_user_id, action, entity_type, entity_id, details, created_at FROM audit_logs ORDER BY id")
        for actor, action, etype, eid, details, created in cur.fetchall():
            if action in ("USER_REGISTERED", "KYC_VERIFIED", "LOAN_REQUEST_CREATED", "LOAN_REQUEST_FUNDED"):
                uid = actor if actor else (eid if etype in ("user", "kyc_profile") else None)
                if uid:
                    events.append({"user_id": uid, "type": action, "ts": created, "source": "system",
                                   "data": {"entity_type": etype, "entity_id": eid, **(details or {})}})
        events.sort(key=lambda e: e["ts"])
        for i in range(0, len(events), 20000):
            db.activity_events.insert_many(events[i:i + 20000])
        print(f"activity_events    {len(events):>8,}")

        if args.also_jsonb:
            cur.execute("DROP TABLE IF EXISTS loan_applications_jsonb")
            cur.execute("CREATE TABLE loan_applications_jsonb (request_id bigint PRIMARY KEY, doc jsonb NOT NULL)")
            with cur.copy("COPY loan_applications_jsonb (request_id, doc) FROM STDIN") as cp:
                for a in apps:
                    cp.write_row([a["request_id"], json.dumps(a, default=lambda o: o.isoformat() if hasattr(o, "isoformat") else str(o))])
            cur.execute("ANALYZE loan_applications_jsonb")
            pg.commit()
            print(f"loan_applications_jsonb (PostgreSQL) {len(apps):,}")
    print("Done.")


if __name__ == "__main__":
    main()
