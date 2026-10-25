#!/usr/bin/env python3
"""
Copay seed generator (Portfolio 1).

Simulates ~21 months of activity on the Copay platform and loads it into
PostgreSQL. Everything is produced by a time ordered event simulation so that
the business rules hold by construction AND are re-checked by the database
triggers while loading:

  * wallet balances never go negative (a borrower or lender is topped up from
    the EXTERNAL wallet before an action that needs more money than they hold);
  * every ledger transaction is a balanced set of double entry rows;
  * requests are funded only up to their amount, never by their own borrower;
  * repayments clear the oldest unpaid instalment first.

Usage (from the repository root):
    python portfolio-1-database-design/seed/generate_seed.py --reset
    python portfolio-1-database-design/seed/generate_seed.py --reset --users 600

Connection: --dsn, or DATABASE_URL, or PG*/POSTGRES_* variables, or .env in the
repository root (see .env.example). All money is handled in integer kobo inside
Python and written as NUMERIC(14,2), so there is no floating point error.
"""
import argparse
import heapq
import itertools
import json
import math
import os
import random
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_SQL = ROOT / "portfolio-1-database-design" / "schema.sql"

FIRST_NAMES = [
    "Adebayo", "Chinedu", "Ngozi", "Emeka", "Aisha", "Fatima", "Ibrahim", "Oluwaseun", "Tolu",
    "Bukola", "Chioma", "Yusuf", "Funmilayo", "Obinna", "Amina", "Kelechi", "Damilola", "Hauwa",
    "Segun", "Ifeanyi", "Zainab", "Tunde", "Nneka", "Musa", "Folake", "Uche", "Halima", "Kunle",
    "Blessing", "Sadiq", "Temitope", "Chukwuemeka", "Abiola", "Ruth", "Gbenga", "Patience",
    "Babatunde", "Rukayat", "Ejiro", "Mariam",
]
LAST_NAMES = [
    "Okafor", "Adeyemi", "Balogun", "Nwosu", "Abdullahi", "Ogunleye", "Eze", "Bello", "Afolabi",
    "Okonkwo", "Lawal", "Ibrahim", "Adeleke", "Chukwu", "Danjuma", "Ogundipe", "Obi", "Musa",
    "Akande", "Nnamdi", "Salako", "Umar", "Olawale", "Onyeka", "Ajayi", "Sanni", "Okoro",
    "Fashola", "Garba", "Idowu", "Emenike", "Yakubu", "Ojo", "Anyanwu", "Alabi", "Tijani",
    "Ekwueme", "Adewale", "Suleiman", "Oyelaran",
]
DOMAINS = ["gmail.com"] * 6 + ["yahoo.com"] * 2 + ["outlook.com", "icloud.com"]
BANKS = ["044", "058", "011", "033", "057", "232", "221", "214"]
PURPOSES = ["SCHOOL_FEES", "RENT", "BUSINESS_STOCK", "MEDICAL", "EQUIPMENT", "TRAVEL", "OTHER"]
DISPUTE_REASONS = [
    "Payment debited but not reflected", "Disputed interest amount",
    "Borrower unreachable after disbursement", "Instalment applied to wrong schedule",
]

KYC_LIMIT_KOBO = 100_000 * 100
FEE_RATE = 0.015
MIN_FEE_KOBO = 500 * 100


# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
def kobo(n):
    """Format integer kobo as a NUMERIC(14,2) literal."""
    sign = "-" if n < 0 else ""
    n = abs(n)
    return f"{sign}{n // 100}.{n % 100:02d}"


def ts(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S") + "+00"


def load_dotenv():
    env_file = ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def build_dsn(cli_dsn):
    if cli_dsn:
        return cli_dsn
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    load_dotenv()
    g = os.environ.get
    return (
        f"host={g('PGHOST', 'localhost')} port={g('PGPORT', g('POSTGRES_PORT', '5432'))} "
        f"dbname={g('PGDATABASE', g('POSTGRES_DB', 'copay'))} "
        f"user={g('PGUSER', g('POSTGRES_USER', 'copay_admin'))} "
        f"password={g('PGPASSWORD', g('POSTGRES_PASSWORD', ''))}"
    )


# ----------------------------------------------------------------------------
# Simulation
# ----------------------------------------------------------------------------
class Simulation:
    def __init__(self, n_users, seed, start, end):
        self.rng = random.Random(seed)
        self.n_users = n_users
        self.start, self.end = start, end
        self.horizon = end - timedelta(hours=2)  # funding must finish before this
        self.seq = itertools.count()
        self.heap = []

        # result tables (lists of tuples, in COPY column order)
        self.users, self.kyc, self.wallets, self.banks = [], [], [], []
        self.requests, self.fundings, self.loans, self.schedules = [], [], [], []
        self.repayments, self.fees = [], []
        self.txns, self.entries = [], []
        self.notifications, self.audit, self.disputes, self.trust = [], [], [], []
        self.final_request_status = {}  # request id -> CANCELLED / EXPIRED

        self.balance = {}      # wallet id -> kobo
        self.wallet_of = {}    # user id -> wallet id
        self.user_info = {}    # user id -> dict
        self.txn_id = itertools.count(1)
        self.entry_id = itertools.count(1)
        self.funding_id = itertools.count(1)
        self.loan_id = itertools.count(1)
        self.schedule_id = itertools.count(1)
        self.repayment_id = itertools.count(1)
        self.fee_id = itertools.count(1)
        self.request_info = {}
        self.loan_info = {}
        self.stats = {"topups": 0, "withdrawals": 0}

    # -- ledger ------------------------------------------------------------
    def post(self, ttype, when, legs, desc, key=None):
        assert sum(a for _, a in legs) == 0, "unbalanced transaction"
        tid = next(self.txn_id)
        ref = f"CPY-{when:%Y%m%d}-{tid:07d}"
        self.txns.append((tid, ttype, ref, desc, key, ts(when)))
        for wallet, amount in legs:
            self.entries.append((next(self.entry_id), tid, wallet, kobo(amount), ts(when)))
            self.balance[wallet] += amount
            ext_ok = wallet == self.EXTERNAL
            assert ext_ok or self.balance[wallet] >= 0, f"wallet {wallet} would go negative"
        return tid

    def ensure_funds(self, user_id, need, when):
        wallet = self.wallet_of[user_id]
        if self.balance[wallet] >= need:
            return wallet
        shortfall = need - self.balance[wallet]
        top = math.ceil((shortfall + self.rng.choice([0, 0, 5_000_00, 20_000_00])) / 1_000_00) * 1_000_00
        self.post("WALLET_FUNDING", when, [(self.EXTERNAL, -top), (wallet, top)],
                  "Wallet top up from bank transfer")
        self.stats["topups"] += 1
        return wallet

    def notify(self, user_id, ntype, title, body, when):
        read = None
        if self.rng.random() < 0.7:
            read = ts(when + timedelta(minutes=self.rng.randint(1, 2880)))
        self.notifications.append((len(self.notifications) + 1, user_id, ntype, title, body, read, ts(when)))

    def push(self, when, kind, data):
        if when <= self.end:
            heapq.heappush(self.heap, (when, next(self.seq), kind, data))

    # -- build people ------------------------------------------------------
    def build_people(self):
        rng = self.rng
        n_staff = max(3, self.n_users // 400)
        self.EXTERNAL, self.ESCROW, self.FEES = 1, 2, 3
        for wid, kind in ((1, "EXTERNAL"), (2, "ESCROW"), (3, "FEES")):
            self.wallets.append((wid, "", kind, ts(self.start)))
            self.balance[wid] = 0
        next_wallet = 4
        used_phones, used_emails = set(), set()
        reg_window = (self.end - self.start - timedelta(days=45)).total_seconds()

        for uid in range(1, self.n_users + 1):
            first, last = rng.choice(FIRST_NAMES), rng.choice(LAST_NAMES)
            email = f"{first}.{last}{uid}@{rng.choice(DOMAINS)}".lower()
            while True:
                phone = "+234" + rng.choice(["803", "805", "806", "810", "813", "816", "903", "905"]) \
                    + f"{rng.randint(0, 9999999):07d}"
                if phone not in used_phones:
                    used_phones.add(phone)
                    break
            staff = uid <= n_staff
            role = ("ADMIN" if uid == 1 else "SUPPORT") if staff else "USER"
            created = self.start + timedelta(seconds=rng.random() ** 1.3 * reg_window)
            if staff:
                created = self.start
            status = "ACTIVE" if staff or rng.random() < 0.97 else rng.choice(["SUSPENDED", "CLOSED"])
            deleted = ts(created + timedelta(days=rng.randint(30, 200))) if status == "CLOSED" else ""
            persona = "STAFF" if staff else rng.choices(["BORROWER", "LENDER", "BOTH"], [55, 30, 15])[0]
            self.users.append((uid, email, phone, f"{first} {last}", role, status, ts(created), deleted))
            self.audit.append((0, uid if staff else None, "USER_REGISTERED", "user", uid,
                               json.dumps({"channel": rng.choice(["ios", "android", "web"])}), ts(created)))

            kyc_state = "NOT_STARTED"
            if not staff:
                kyc_state = rng.choices(["VERIFIED", "PENDING", "REJECTED", "NOT_STARTED"], [80, 8, 4, 8])[0]
                level = {"VERIFIED": rng.choice([1, 2, 3]), "PENDING": 0, "REJECTED": 0, "NOT_STARTED": 0}[kyc_state]
                submitted = created + timedelta(hours=rng.randint(1, 72)) if kyc_state != "NOT_STARTED" else None
                verified = submitted + timedelta(hours=rng.randint(1, 48)) if kyc_state == "VERIFIED" else None
                self.kyc.append((uid, kyc_state, level, f"sha256:{rng.getrandbits(128):032x}" if submitted else "",
                                 ts(submitted) if submitted else "", ts(verified) if verified else ""))
                if verified:
                    self.audit.append((0, None, "KYC_VERIFIED", "kyc_profile", uid, "{}", ts(verified)))

                wid = next_wallet
                next_wallet += 1
                self.wallets.append((wid, uid, "USER", ts(created)))
                self.balance[wid] = 0
                self.wallet_of[uid] = wid
                for i in range(rng.choice([1, 1, 1, 2])):
                    self.banks.append((len(self.banks) + 1, uid, rng.choice(BANKS),
                                       f"{rng.randint(0, 9999999999):010d}", f"{first} {last}".upper(),
                                       "t" if i == 0 else "f", ts(created + timedelta(days=1)),
                                       ""))
            self.user_info[uid] = {
                "persona": persona, "created": created, "status": status,
                "verified": kyc_state == "VERIFIED",
                "reliability": rng.choices(["GOOD", "AVERAGE", "BAD"], [70, 22, 8])[0],
                "weight": rng.paretovariate(1.4),
            }

        active = [u for u, i in self.user_info.items() if i["status"] == "ACTIVE" and i["persona"] != "STAFF"]
        self.borrowers = [u for u in active if self.user_info[u]["persona"] in ("BORROWER", "BOTH")]
        self.lenders = [u for u in active if self.user_info[u]["persona"] in ("LENDER", "BOTH")]
        self.lender_weights = [self.user_info[u]["weight"] for u in self.lenders]

    # -- plan loan requests -------------------------------------------------
    def plan_requests(self, n_requests):
        rng = self.rng
        for rid in range(1, n_requests + 1):
            bid = rng.choice(self.borrowers)
            info = self.user_info[bid]
            earliest = info["created"] + timedelta(days=1)
            if earliest >= self.end - timedelta(days=2):
                earliest = self.end - timedelta(days=30)
            span = (self.end - timedelta(hours=3) - earliest).total_seconds()
            created = earliest + timedelta(seconds=rng.random() * span)
            amount = rng.choice([20, 30, 50, 50, 75, 100, 100, 150, 200, 250, 300, 400, 500, 750, 1000, 1500]) * 1000_00
            if amount > KYC_LIMIT_KOBO and not info["verified"]:
                amount = KYC_LIMIT_KOBO
            weeks = rng.choice([4, 8, 12, 12, 16, 20, 26, 26, 36])
            rate = round((3 + weeks * 0.35 + rng.uniform(-1, 2)) * 2) / 2
            expires = created + timedelta(days=14)
            recent = (self.end - created) < timedelta(days=14)
            if recent:
                outcome = rng.choices(["OPEN", "FUNDED"], [55, 45])[0]
            else:
                outcome = rng.choices(["FUNDED", "CANCELLED", "EXPIRED"], [72, 8, 20])[0]
            self.requests.append((rid, bid, kobo(amount), rng.choice(PURPOSES), weeks, f"{rate:.2f}",
                                  ts(created), ts(expires)))
            self.request_info[rid] = {"borrower": bid, "amount": amount, "weeks": weeks, "rate": rate,
                                      "created": created, "expires": expires, "lenders": []}
            self.audit.append((0, bid, "LOAN_REQUEST_CREATED", "loan_request", rid,
                               json.dumps({"amount": kobo(amount), "weeks": weeks}), ts(created)))
            if outcome in ("CANCELLED", "EXPIRED"):
                self.final_request_status[rid] = outcome
                continue
            partial = outcome == "OPEN" and rng.random() < 0.3
            if outcome == "OPEN" and not partial:
                continue
            self.plan_fundings(rid, partial)

    def plan_fundings(self, rid, partial):
        rng = self.rng
        info = self.request_info[rid]
        amount = info["amount"]
        n = rng.choices([1, 2, 3, 4], [40, 30, 20, 10])[0]
        units = amount // 1000_00
        n = min(n, units)
        cuts = sorted(rng.sample(range(1, units), n - 1)) if n > 1 else []
        parts = [b - a for a, b in zip([0] + cuts, cuts + [units])]
        shares = [p * 1000_00 for p in parts]
        chosen = []
        for share in shares:
            for _ in range(30):
                lender = rng.choices(self.lenders, self.lender_weights)[0]
                ok = lender != info["borrower"] and lender not in chosen
                if share > KYC_LIMIT_KOBO and not self.user_info[lender]["verified"]:
                    ok = False
                if ok:
                    chosen.append(lender)
                    break
            else:
                return  # could not find a lender: leave the request unfunded and OPEN
        if partial and n > 1:
            shares, chosen = shares[:-1], chosen[:-1]
        elif partial:
            return
        offsets, t = [], 0.0
        for _ in shares:
            t += rng.uniform(0.02, 1.5)
            offsets.append(t)
        window = (min(info["expires"], self.horizon) - info["created"]).total_seconds() - 60
        scale = min(1.0, window / (offsets[-1] * 86400))
        if window <= 0:
            return
        for idx, (lender, share, off) in enumerate(zip(chosen, shares, offsets)):
            when = info["created"] + timedelta(days=off * scale)
            last = idx == len(shares) - 1 and not partial
            self.push(when, "FUND", (rid, lender, share, idx, last))

    # -- event handlers -------------------------------------------------------
    def run(self):
        while self.heap:
            when, _, kind, data = heapq.heappop(self.heap)
            getattr(self, f"on_{kind.lower()}")(when, *data)

    def on_fund(self, when, rid, lender, share, idx, last):
        info = self.request_info[rid]
        lw = self.ensure_funds(lender, share, when)
        tid = self.post("LOAN_FUNDING", when, [(lw, -share), (self.ESCROW, share)],
                        f"Funding of loan request {rid}")
        self.fundings.append((next(self.funding_id), rid, lender, kobo(share),
                              f"fund-{rid}-{lender}-{idx}", tid, ts(when)))
        info["lenders"].append((lender, share))
        if last:
            self.push(when + timedelta(minutes=self.rng.randint(2, 30)), "DISBURSE", (rid,))

    def on_disburse(self, when, rid):
        rng = self.rng
        info = self.request_info[rid]
        principal = info["amount"]
        fee = max(MIN_FEE_KOBO, round(principal * FEE_RATE / 100) * 100)
        bw = self.wallet_of[info["borrower"]]
        tid = self.post("DISBURSEMENT", when,
                        [(self.ESCROW, -principal), (bw, principal - fee), (self.FEES, fee)],
                        f"Disbursement of loan request {rid}")
        lid = next(self.loan_id)
        self.loans.append([lid, rid, info["borrower"], kobo(principal), f"{info['rate']:.2f}",
                           info["weeks"], kobo(fee), ts(when)])
        self.fees.append((next(self.fee_id), lid, tid, "PLATFORM_SERVICE_FEE", kobo(fee), ts(when)))
        self.audit.append((0, None, "LOAN_REQUEST_FUNDED", "loan_request", rid, "{}", ts(when)))
        self.notify(info["borrower"], "LOAN_FUNDED", "Your loan has been funded",
                    f"NGN {principal // 100:,} has been added to your wallet.", when)

        n = info["weeks"]
        total_interest = round(principal * info["rate"] / 100 / 100) * 100
        principal_part, interest_part = principal // n, total_interest // n
        reliability = self.user_info[info["borrower"]]["reliability"]
        sched_ids, prev_paid, stopped = [], when, False
        for k in range(1, n + 1):
            p_due = principal_part if k < n else principal - principal_part * (n - 1)
            i_due = interest_part if k < n else total_interest - interest_part * (n - 1)
            due = (when + timedelta(days=7 * k)).date()
            sid = next(self.schedule_id)
            self.schedules.append((sid, lid, k, due.isoformat(), kobo(p_due), kobo(i_due), kobo(p_due + i_due)))
            due_dt = datetime(due.year, due.month, due.day, rng.randint(7, 20), rng.randint(0, 59))
            if stopped or due_dt > self.end:
                continue
            miss_p = {"GOOD": 0.01, "AVERAGE": 0.04, "BAD": 0.30}[reliability]
            late_p = {"GOOD": 0.03, "AVERAGE": 0.25, "BAD": 0.40}[reliability]
            if rng.random() < miss_p:
                stopped = True
                continue
            paid_at = due_dt - timedelta(hours=rng.randint(0, 48))
            if rng.random() < late_p:
                paid_at = due_dt + timedelta(days=rng.randint(1, 10), hours=rng.randint(0, 20))
            paid_at = max(paid_at, prev_paid + timedelta(minutes=1), when + timedelta(hours=1))
            if paid_at > self.end:
                stopped = True
                continue
            prev_paid = paid_at
            on_time = paid_at.date() <= due + timedelta(days=1)
            self.push(paid_at, "REPAY", (lid, rid, sid, k, p_due + i_due, on_time))
        self.loan_info[lid] = {"request": rid, "borrower": info["borrower"], "principal": principal}
        if rng.random() < 0.03:
            when_d = when + timedelta(days=rng.randint(3, 60))
            if when_d <= self.end:
                raiser = info["borrower"] if rng.random() < 0.5 else info["lenders"][0][0]
                status = rng.choices(["OPEN", "UNDER_REVIEW", "RESOLVED", "REJECTED"], [25, 20, 40, 15])[0]
                resolved = ts(min(self.end, when_d + timedelta(days=rng.randint(1, 20)))) \
                    if status in ("RESOLVED", "REJECTED") else ""
                self.disputes.append((len(self.disputes) + 1, lid, raiser, rng.choice(DISPUTE_REASONS),
                                      status, ts(when_d), resolved))

    def on_repay(self, when, lid, rid, sid, k, amount, on_time):
        info = self.request_info[rid]
        borrower = info["borrower"]
        bw = self.ensure_funds(borrower, amount, when)
        legs, remaining = [(bw, -amount)], amount
        for i, (lender, share) in enumerate(info["lenders"]):
            part = remaining if i == len(info["lenders"]) - 1 else amount * share // info["amount"]
            remaining -= part
            if part:
                legs.append((self.wallet_of[lender], part))
        tid = self.post("REPAYMENT", when, legs, f"Repayment of loan {lid}, instalment {k}")
        self.repayments.append((next(self.repayment_id), lid, sid, borrower, kobo(amount), ts(when),
                                tid, f"repay-{lid}-{k}"))
        stat = self.loan_info[lid].setdefault("stat", [0, 0])
        stat[0] += 1
        stat[1] += 1 if on_time else 0
        if self.rng.random() < 0.4:
            self.notify(info["lenders"][0][0], "REPAYMENT_RECEIVED", "Repayment received",
                        f"NGN {amount // 100:,} received on loan {lid}.", when)
        if self.rng.random() < 0.05:
            self.push(when + timedelta(days=self.rng.randint(1, 3)), "WITHDRAW", (info["lenders"][0][0],))

    def on_withdraw(self, when, user_id):
        wallet = self.wallet_of[user_id]
        amount = (self.balance[wallet] * 6 // 10) // 100 * 100
        if amount >= 1000_00:
            self.post("WALLET_WITHDRAWAL", when, [(wallet, -amount), (self.EXTERNAL, amount)],
                      "Withdrawal to bank account")
            self.stats["withdrawals"] += 1

    # -- derived tables --------------------------------------------------------
    def expire_unfunded(self):
        """Requests that never received funding and are past expiry become EXPIRED."""
        funded = {f[1] for f in self.fundings}
        for rid, info in self.request_info.items():
            if rid not in funded and rid not in self.final_request_status and info["expires"] < self.end:
                self.final_request_status[rid] = "EXPIRED"

    def build_trust_scores(self):
        by_borrower = {}
        for lid, li in self.loan_info.items():
            paid, ontime = li.get("stat", [0, 0])
            agg = by_borrower.setdefault(li["borrower"], [0, 0])
            agg[0] += paid
            agg[1] += ontime
        due_count = {}
        today = self.end.date().isoformat()
        for (_, lid, _, due, *_rest) in self.schedules:
            if due < today:
                b = self.loan_info[lid]["borrower"]
                due_count[b] = due_count.get(b, 0) + 1
        for uid, info in self.user_info.items():
            if info["persona"] == "STAFF":
                continue
            due = due_count.get(uid, 0)
            if due:
                rate = min(1.0, by_borrower.get(uid, [0, 0])[1] / due)
                score = round(300 + 550 * rate)
                self.trust.append((uid, score, f"{rate * 100:.2f}", ts(self.end)))
            else:
                self.trust.append((uid, 500, "", ts(self.end)))


# ----------------------------------------------------------------------------
# Loading
# ----------------------------------------------------------------------------
def copy_rows(cur, table, columns, rows):
    with cur.copy(f"COPY {table} ({', '.join(columns)}) FROM STDIN") as cp:
        for row in rows:
            cp.write_row([None if v == "" else v for v in row])


def load(sim, conn):
    with conn.transaction():
        cur = conn.cursor()
        cur.execute("SET LOCAL synchronous_commit = off")
        copy_rows(cur, "users", ["id", "email", "phone", "full_name", "role", "status", "created_at", "deleted_at"],
                  sim.users)
        copy_rows(cur, "kyc_profiles", ["user_id", "status", "level", "bvn_hash", "submitted_at", "verified_at"],
                  sim.kyc)
        copy_rows(cur, "wallets", ["id", "user_id", "kind", "created_at"], sim.wallets)
        copy_rows(cur, "bank_accounts", ["id", "user_id", "bank_code", "account_number", "account_name",
                                         "is_primary", "created_at", "deleted_at"], sim.banks)
        copy_rows(cur, "loan_requests", ["id", "borrower_id", "amount", "purpose", "tenor_weeks",
                                         "interest_rate_pct", "created_at", "expires_at"], sim.requests)
        copy_rows(cur, "ledger_transactions", ["id", "txn_type", "reference", "description", "idempotency_key",
                                               "created_at"], sim.txns)
        copy_rows(cur, "ledger_entries", ["id", "txn_id", "wallet_id", "amount", "created_at"], sim.entries)
        copy_rows(cur, "loan_fundings", ["id", "loan_request_id", "lender_id", "amount", "idempotency_key",
                                         "ledger_txn_id", "created_at"], sim.fundings)
        copy_rows(cur, "loans", ["id", "loan_request_id", "borrower_id", "principal", "interest_rate_pct",
                                 "tenor_weeks", "platform_fee", "disbursed_at"], sim.loans)
        copy_rows(cur, "repayment_schedules", ["id", "loan_id", "instalment_no", "due_date", "principal_due",
                                               "interest_due", "amount_due"], sim.schedules)
        copy_rows(cur, "fees", ["id", "loan_id", "ledger_txn_id", "fee_type", "amount", "created_at"], sim.fees)
        sim.repayments.sort(key=lambda r: (r[5], r[0]))
        copy_rows(cur, "repayments", ["id", "loan_id", "schedule_id", "payer_id", "amount", "paid_at",
                                      "ledger_txn_id", "idempotency_key"], sim.repayments)

        for rid, status in sim.final_request_status.items():
            cur.execute("UPDATE loan_requests SET status = %s WHERE id = %s", (status, rid))
        cur.execute("SELECT * FROM mark_overdue(%s)", (sim.end.date(),))
        print("  mark_overdue:", cur.fetchone())

        copy_rows(cur, "trust_scores", ["user_id", "score", "on_time_rate", "computed_at"], sim.trust)
        copy_rows(cur, "disputes", ["id", "loan_id", "raised_by", "reason", "status", "created_at", "resolved_at"],
                  sim.disputes)
        copy_rows(cur, "notifications", ["id", "user_id", "type", "title", "body", "read_at", "created_at"],
                  sim.notifications)
        audit = sorted(sim.audit, key=lambda r: r[6])
        copy_rows(cur, "audit_logs", ["id", "actor_user_id", "action", "entity_type", "entity_id", "details",
                                      "created_at"], [(i + 1,) + r[1:] for i, r in enumerate(audit)])

        for table in ("users", "wallets", "bank_accounts", "loan_requests", "loan_fundings", "loans",
                      "repayment_schedules", "repayments", "fees", "ledger_transactions", "ledger_entries",
                      "disputes", "notifications", "audit_logs"):
            cur.execute(f"SELECT setval(pg_get_serial_sequence('{table}', 'id'), "
                        f"COALESCE((SELECT max(id) FROM {table}), 1))")
    conn.execute("ANALYZE")


def verify(conn):
    print("\nRow counts:")
    for table in ("users", "kyc_profiles", "wallets", "bank_accounts", "loan_requests", "loan_fundings", "loans",
                  "repayment_schedules", "repayments", "fees", "ledger_transactions", "ledger_entries",
                  "trust_scores", "disputes", "notifications", "audit_logs"):
        n = conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
        print(f"  {table:<22}{n:>10,}")
    bad = conn.execute("SELECT count(*) FROM wallet_reconciliation WHERE difference <> 0").fetchone()[0]
    total = conn.execute("SELECT COALESCE(sum(amount), 0) FROM ledger_entries").fetchone()[0]
    print(f"\nReconciliation: wallets where cached balance <> ledger sum = {bad}")
    print(f"Ledger grand total (must be 0.00) = {total}")
    print("Request status:", conn.execute(
        "SELECT string_agg(status || '=' || n, ', ') FROM "
        "(SELECT status::text, count(*) n FROM loan_requests GROUP BY 1 ORDER BY 1) s").fetchone()[0])
    if bad or total != 0:
        sys.exit("RECONCILIATION FAILED")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--users", type=int, default=3200, help="registered users (600 to 3200 in the case study)")
    ap.add_argument("--seed", type=int, default=42, help="random seed (same seed, same data)")
    ap.add_argument("--start", default="2025-01-01")
    ap.add_argument("--end", default="2026-10-15", help="simulation 'today'; used as as-of date for overdue")
    ap.add_argument("--requests-per-user", type=float, default=1.875)
    ap.add_argument("--reset", action="store_true", help="re-create the schema first (destroys data)")
    ap.add_argument("--dsn")
    args = ap.parse_args()

    start = datetime.fromisoformat(args.start)
    end = datetime.fromisoformat(args.end).replace(hour=23, minute=0)
    print(f"Simulating {args.users} users from {args.start} to {args.end} (seed {args.seed}) ...")
    sim = Simulation(args.users, args.seed, start, end)
    sim.build_people()
    sim.plan_requests(round(args.users * args.requests_per_user))
    sim.run()
    sim.expire_unfunded()
    sim.build_trust_scores()
    print(f"  ledger transactions={len(sim.txns):,} entries={len(sim.entries):,} "
          f"topups={sim.stats['topups']:,} withdrawals={sim.stats['withdrawals']:,}")

    dsn = build_dsn(args.dsn)
    with psycopg.connect(dsn, autocommit=True) as conn:
        if args.reset:
            print("Applying schema.sql ...")
            conn.execute(SCHEMA_SQL.read_text(encoding="utf-8"))
        print("Loading (triggers re-validate every business rule) ...")
        load(sim, conn)
        verify(conn)
    print("\nDone.")


if __name__ == "__main__":
    main()
