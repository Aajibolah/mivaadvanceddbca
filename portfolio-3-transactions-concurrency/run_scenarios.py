#!/usr/bin/env python3
"""
Portfolio 3 scenario runner: reproduces every concurrency scenario with real,
simultaneous database connections and prints what happened.

    python portfolio-3-transactions-concurrency/run_scenarios.py
    python portfolio-3-transactions-concurrency/run_scenarios.py | Tee-Object portfolio-3-transactions-concurrency/evidence/run_scenarios.log

Prerequisites: Portfolio 1 loaded, then 00_functions.sql and 01_test_fixtures.sql.
Only the three p3_* test users and the shared ESCROW/EXTERNAL wallets are touched.
Interleaving is forced with threading.Event/Barrier so the results are repeatable.
Every line printed comes from a query result; nothing is hard coded.
"""
import os
import sys
import threading
import time
from pathlib import Path

import psycopg
from psycopg import errors

ROOT = Path(__file__).resolve().parents[1]


def dsn():
    env = ROOT / ".env"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())
    g = os.environ.get
    return os.environ.get("DATABASE_URL") or (
        f"host={g('PGHOST', 'localhost')} port={g('PGPORT', g('POSTGRES_PORT', '5432'))} "
        f"dbname={g('PGDATABASE', g('POSTGRES_DB', 'copay'))} user={g('PGUSER', g('POSTGRES_USER', 'copay_admin'))} "
        f"password={g('PGPASSWORD', g('POSTGRES_PASSWORD', ''))}")


DSN = dsn()


def connect(**kw):
    return psycopg.connect(DSN, **kw)


def q1(conn, sql, params=None):
    return conn.execute(sql, params).fetchone()[0]


def say(msg=""):
    print(msg, flush=True)


def title(t):
    say(f"\n{'=' * 78}\n{t}\n{'=' * 78}")


def short(e):
    return f"{type(e).__name__} (SQLSTATE {e.sqlstate}): {str(e).splitlines()[0]}"


def run_threads(*targets):
    errors_seen = []

    def wrap(fn):
        def inner():
            try:
                fn()
            except Exception as e:  # noqa: BLE001 - report, do not hide
                errors_seen.append(e)
        return inner

    threads = [threading.Thread(target=wrap(t)) for t in targets]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return errors_seen


class Ctx:
    def __init__(self):
        with connect(autocommit=True) as c:
            self.alice_user = q1(c, "SELECT p3_user('alice')")
            self.bob_user = q1(c, "SELECT p3_user('bob')")
            self.borrower = q1(c, "SELECT p3_user('borrower')")
            self.alice = q1(c, "SELECT p3_wallet('alice')")
            self.bob = q1(c, "SELECT p3_wallet('bob')")
            self.external = q1(c, "SELECT system_wallet('EXTERNAL')")

    def reset(self, label, amount):
        with connect(autocommit=True) as c:
            c.execute("SELECT p3_reset_wallet(%s, %s)", (label, amount))

    def balance(self, wallet):
        with connect(autocommit=True) as c:
            return q1(c, "SELECT balance FROM wallets WHERE id = %s", (wallet,))

    def recon_diff(self, wallet):
        with connect(autocommit=True) as c:
            return q1(c, "SELECT difference FROM wallet_reconciliation WHERE wallet_id = %s", (wallet,))


# ----------------------------------------------------------------------------
def s1_atomic_and_rollback(x):
    title("Scenario 1 and 2: atomic funding, rollback, savepoint")
    with connect(autocommit=True) as c:
        c.execute("SELECT p3_reset_wallet('alice', 100000)")
        c.execute("SELECT p3_reset_wallet('bob', 1000)")
        req = q1(c, "SELECT p3_new_request(50000)")
        say(f"Request {req} for NGN 50,000. alice has 100,000, bob has 1,000.")

        c.execute("SELECT fund_loan(%s, %s, 30000, %s)", (req, x.alice_user, f"s1-{req}-a1"))
        say(f"alice funds 30,000 -> funded_amount = {q1(c, 'SELECT funded_amount FROM loan_requests WHERE id=%s', (req,))}, "
            f"alice balance = {x.balance(x.alice)}")

        before = (q1(c, "SELECT count(*) FROM ledger_transactions"), x.balance(x.bob),
                  q1(c, "SELECT funded_amount FROM loan_requests WHERE id=%s", (req,)))
        try:
            with c.transaction():
                c.execute("SELECT fund_loan(%s, %s, 20000, %s)", (req, x.bob_user, f"s1-{req}-bob"))
            say("UNEXPECTED: bob's funding was accepted")
        except psycopg.Error as e:
            say(f"bob tries 20,000 with 1,000 in the wallet -> {short(e)}")
        after = (q1(c, "SELECT count(*) FROM ledger_transactions"), x.balance(x.bob),
                 q1(c, "SELECT funded_amount FROM loan_requests WHERE id=%s", (req,)))
        say(f"Before {before} / after {after} (ledger txns, bob balance, funded_amount): "
            f"{'nothing partially applied' if before == after else 'CHANGED - PROBLEM'}")

        with c.transaction():
            c.execute("SELECT fund_loan(%s, %s, 5000, %s)", (req, x.alice_user, f"s1-{req}-a2"))
            try:
                with c.transaction():                      # a nested transaction is a SAVEPOINT
                    c.execute("SELECT fund_loan(%s, %s, 20000, %s)", (req, x.bob_user, f"s1-{req}-bob2"))
            except psycopg.Error as e:
                say(f"inside one transaction, SAVEPOINT rolled back bob's step: {short(e)}")
            c.execute("SELECT fund_loan(%s, %s, 15000, %s)", (req, x.alice_user, f"s1-{req}-a3"))
        row = c.execute("SELECT funded_amount, status FROM loan_requests WHERE id=%s", (req,)).fetchone()
        say(f"After savepoint demo: funded_amount={row[0]} status={row[1]} (expected 50000.00 FUNDED)")


# ----------------------------------------------------------------------------
def s2_lost_update(x):
    title("Scenario 3a: lost update (read, decide in code, write absolute value)")
    x.reset("alice", 1000)
    both_read = threading.Barrier(2)
    b_done = threading.Event()

    def worker(name, wait_for_b):
        def run():
            with connect() as c:
                bal = q1(c, "SELECT balance FROM wallets WHERE id=%s", (x.alice,))
                say(f"  {name} read balance {bal}; wants to withdraw 700")
                both_read.wait()
                if wait_for_b:
                    b_done.wait()
                if bal >= 700:
                    c.execute("UPDATE wallets SET balance = %s WHERE id = %s", (bal - 700, x.alice))
                c.commit()
                say(f"  {name} wrote {bal - 700} and committed")
                if not wait_for_b:
                    b_done.set()
        return run

    errs = run_threads(worker("A", True), worker("B", False))
    say(f"Final cached balance = {x.balance(x.alice)} although 1,400 was 'withdrawn' from 1,000")
    say(f"wallet_reconciliation difference = {x.recon_diff(x.alice)} (non zero: the corruption is caught by reconciliation)")
    for e in errs:
        say(f"  error: {short(e)}")


def s3_ledger_defence(x):
    title("Scenario 3b: same stale check, but the withdrawal goes through the ledger")
    x.reset("alice", 1000)
    both_read = threading.Barrier(2)
    a_committed = threading.Event()
    results = {}

    def worker(name, waits):
        def run():
            with connect() as c:
                bal = q1(c, "SELECT balance FROM wallets WHERE id=%s", (x.alice,))
                both_read.wait()
                if waits:
                    time.sleep(0.5)       # make sure A is first on the row lock
                try:
                    c.execute("SELECT post_pair('WALLET_WITHDRAWAL', %s, %s, 700, %s)", (x.alice, x.external, name))
                    if not waits:
                        time.sleep(1.0)   # A holds the lock; B is blocked meanwhile
                    c.commit()
                    results[name] = f"committed (it had read balance {bal})"
                except psycopg.Error as e:
                    c.rollback()
                    results[name] = f"rejected: {short(e)}"
        return run

    run_threads(worker("A", False), worker("B", True))
    for k in sorted(results):
        say(f"  {k}: {results[k]}")
    say(f"Final balance = {x.balance(x.alice)} (never negative; reconciliation difference {x.recon_diff(x.alice)})")


def s4_for_update(x):
    title("Scenario 3c: fix 1, pessimistic locking (withdraw_safe uses SELECT ... FOR UPDATE)")
    x.reset("alice", 1000)
    start = threading.Barrier(2)
    results = {}

    def worker(name):
        def run():
            with connect() as c:
                start.wait()
                try:
                    c.execute("SELECT withdraw_safe(%s, 700)", (x.alice,))
                    c.commit()
                    results[name] = "withdrew 700"
                except psycopg.Error as e:
                    c.rollback()
                    results[name] = f"refused: {short(e)}"
        return run

    run_threads(worker("A"), worker("B"))
    for k in sorted(results):
        say(f"  {k}: {results[k]}")
    say(f"Final balance = {x.balance(x.alice)}; the loser got a clean business error, not a constraint error")


def s5_optimistic(x):
    title("Scenario 3d: fix 2, optimistic locking with the version column")
    x.reset("alice", 1000)
    both_read = threading.Barrier(2)
    a_written = threading.Event()
    outcome = {}

    def worker(name, second):
        def run():
            with connect() as c:
                for attempt in (1, 2, 3):
                    bal, ver = c.execute("SELECT balance, version FROM wallets WHERE id=%s", (x.alice,)).fetchone()
                    if attempt == 1:
                        both_read.wait()
                        if second:
                            a_written.wait()
                    if bal < 700:
                        outcome[name] = f"attempt {attempt}: sees balance {bal} < 700, refuses cleanly"
                        c.rollback()
                        return
                    cur = c.execute("UPDATE wallets SET balance = %s WHERE id = %s AND version = %s",
                                    (bal - 700, x.alice, ver))
                    c.commit()
                    if cur.rowcount == 1:
                        outcome[name] = f"attempt {attempt}: updated version {ver} -> {ver + 1}"
                        if not second:
                            a_written.set()
                        return
                    say(f"  {name} attempt {attempt}: UPDATE matched 0 rows (version {ver} is stale) -> retry")
        return run

    run_threads(worker("A", False), worker("B", True))
    for k in sorted(outcome):
        say(f"  {k}: {outcome[k]}")
    say(f"Final balance = {x.balance(x.alice)}")


# ----------------------------------------------------------------------------
def s6_isolation(x):
    title("Scenario 4a/4b: non repeatable read, and REPEATABLE READ")
    for level in ("READ COMMITTED", "REPEATABLE READ"):
        x.reset("alice", 1000)
        with connect(autocommit=True) as a, connect(autocommit=True) as b:
            a.execute(f"BEGIN ISOLATION LEVEL {level}")
            first = q1(a, "SELECT balance FROM wallets WHERE id=%s", (x.alice,))
            b.execute("SELECT post_pair('WALLET_FUNDING', %s, %s, 500, 'top up')", (x.external, x.alice))
            second = q1(a, "SELECT balance FROM wallets WHERE id=%s", (x.alice,))
            say(f"  {level}: A read {first}, B committed +500, A read again {second} "
                f"-> {'NON REPEATABLE READ' if first != second else 'repeatable'}")
            if level == "REPEATABLE READ":
                try:
                    a.execute("UPDATE wallets SET balance = balance WHERE id=%s", (x.alice,))
                except psycopg.Error as e:
                    say(f"  REPEATABLE READ update of a row changed since the snapshot -> {short(e)}")
            a.execute("ROLLBACK")


def write_skew_attempt(x, level, label, retry):
    """Both sessions check 'sum of OPEN requests + new <= 1,000,000' then insert 600,000."""
    start = threading.Barrier(2)
    log = []

    def worker(name):
        def run():
            first = True
            for attempt in range(1, 4 if retry else 2):
                with connect() as c:
                    c.isolation_level = psycopg.IsolationLevel[level.replace(" ", "_")]
                    try:
                        total = q1(c, "SELECT COALESCE(sum(amount),0) FROM loan_requests "
                                      "WHERE borrower_id=%s AND status='OPEN'", (x.borrower,))
                        if first:
                            start.wait()          # both have read before either writes
                            first = False
                        if total + 600000 <= 1000000:
                            c.execute("INSERT INTO loan_requests (borrower_id, amount, purpose, tenor_weeks, "
                                      "interest_rate_pct, expires_at) VALUES (%s, 600000, 'RENT', 12, 8, "
                                      "now() + interval '14 days')", (x.borrower,))
                            time.sleep(0.3)
                        c.commit()
                        log.append(f"{name} attempt {attempt}: saw total {total}, "
                                   f"{'inserted 600000' if total + 600000 <= 1000000 else 'declined (rule)'}; committed")
                        return
                    except errors.SerializationFailure as e:
                        c.rollback()
                        log.append(f"{name} attempt {attempt}: {short(e)} -> {'retrying' if retry else 'gave up'}")
                        if not retry:
                            return
        return run

    with connect(autocommit=True) as c:
        c.execute("SELECT p3_cleanup_requests()")
    run_threads(worker("A"), worker("B"))
    with connect(autocommit=True) as c:
        total = q1(c, "SELECT COALESCE(sum(amount),0) FROM loan_requests WHERE borrower_id=%s AND status='OPEN'",
                   (x.borrower,))
        c.execute("SELECT p3_cleanup_requests()")
    for line in sorted(log):
        say(f"  {line}")
    say(f"  {label}: total OPEN after both finish = {total} -> {'RULE BROKEN (limit 1,000,000)' if total > 1000000 else 'rule holds'}")


def s7_write_skew(x):
    title("Scenario 4c: write skew under REPEATABLE READ, fixed by SERIALIZABLE with retry")
    write_skew_attempt(x, "REPEATABLE READ", "REPEATABLE READ", retry=False)
    write_skew_attempt(x, "SERIALIZABLE", "SERIALIZABLE + retry", retry=True)


# ----------------------------------------------------------------------------
def s8_deadlock(x):
    title("Scenario 5: deadlock, and lock ordering")
    for fn, label in (("transfer_naive", "naive (locks in the order given)"),
                      ("transfer", "ordered (lowest wallet id first)")):
        x.reset("alice", 1000)
        x.reset("bob", 1000)
        start = threading.Barrier(2)
        res = {}

        def worker(name, frm, to):
            def run():
                with connect() as c:
                    start.wait()
                    try:
                        c.execute(f"SELECT {fn}(%s, %s, 100, 2)", (frm, to))
                        c.commit()
                        res[name] = "committed"
                    except psycopg.Error as e:
                        c.rollback()
                        res[name] = f"aborted: {short(e)}"
            return run

        t0 = time.time()
        run_threads(worker("A alice->bob", x.alice, x.bob), worker("B bob->alice", x.bob, x.alice))
        say(f"  {label}: finished in {time.time() - t0:.1f}s")
        for k in sorted(res):
            say(f"    {k}: {res[k]}")


def s9_idempotency(x):
    title("Scenario 6: idempotency under retries and races")
    x.reset("alice", 100000)
    with connect(autocommit=True) as c:
        req = q1(c, "SELECT p3_new_request(50000)")
    before = x.balance(x.alice)
    key = f"s9-{req}"
    start = threading.Barrier(4)
    ids = []

    def worker():
        with connect() as c:
            start.wait()
            ids.append(q1(c, "SELECT fund_loan(%s, %s, 20000, %s)", (req, x.alice_user, key)))
            c.commit()

    errs = run_threads(worker, worker, worker, worker)
    with connect(autocommit=True) as c:
        n = q1(c, "SELECT count(*) FROM loan_fundings WHERE idempotency_key=%s", (key,))
        ledger_n = q1(c, "SELECT count(*) FROM ledger_transactions WHERE idempotency_key=%s", (key,))
    say(f"  4 simultaneous identical requests returned funding ids {sorted(set(ids))}; errors: {len(errs)}")
    say(f"  funding rows = {n}, ledger transactions = {ledger_n}, alice debited {before - x.balance(x.alice)} (expected 20000.00 once)")

    with connect(autocommit=True) as c:
        c.execute("SELECT fund_loan(%s, %s, 30000, %s)", (req, x.alice_user, key + "-rest"))
        loan = q1(c, "SELECT disburse_loan(%s)", (req,))
        c.execute("SELECT p3_reset_wallet('borrower', 30000)")
        due = q1(c, "SELECT amount_due FROM repayment_schedules WHERE loan_id=%s AND instalment_no=1", (loan,))
        amount = due * 3 / 2
        first = q1(c, "SELECT apply_repayment(%s, %s, %s)", (loan, amount, f"rep-{loan}"))
        retry = q1(c, "SELECT apply_repayment(%s, %s, %s)", (loan, amount, f"rep-{loan}"))
        rows = c.execute("SELECT instalment_no, amount_paid, status FROM repayment_schedules "
                         "WHERE loan_id=%s ORDER BY instalment_no LIMIT 3", (loan,)).fetchall()
        say(f"  repayment of {amount}: first call touched {first} instalments, identical retry touched {retry}")
        for r in rows:
            say(f"    instalment {r[0]}: paid {r[1]} {r[2]}")
        say("  (oldest first: 1 PAID, 2 PARTIAL, 3 PENDING)")


def final_integrity():
    title("Final integrity check")
    with connect(autocommit=True) as c:
        bad = q1(c, "SELECT count(*) FROM wallet_reconciliation WHERE difference <> 0")
        total = q1(c, "SELECT COALESCE(sum(amount),0) FROM ledger_entries")
        say(f"wallets where cached balance differs from the ledger: {bad}; ledger grand total: {total}")


def main():
    with connect(autocommit=True) as c:
        say(f"Connected: {q1(c, 'SELECT version()')}")
        try:
            c.execute("SELECT p3_user('alice')")
        except psycopg.Error:
            sys.exit("Run 00_functions.sql and 01_test_fixtures.sql first.")
    x = Ctx()
    for scenario in (s1_atomic_and_rollback, s2_lost_update, s3_ledger_defence, s4_for_update, s5_optimistic,
                     s6_isolation, s7_write_skew, s8_deadlock, s9_idempotency):
        scenario(x)
    # leave the test wallets consistent
    x.reset("alice", 1000)
    x.reset("bob", 1000)
    final_integrity()


if __name__ == "__main__":
    main()
