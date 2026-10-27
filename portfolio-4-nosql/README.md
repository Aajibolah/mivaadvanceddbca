# Portfolio 4: NoSQL and Advanced Data Models (Copay)

**Engine:** MongoDB (document model). **Case study:** the same Copay platform as Portfolios 1 to 3. PostgreSQL stays the system of record for money; MongoDB takes the data that suits documents.

## Why these data fit a document database (and what stays relational)

| Data | Where | Why |
|---|---|---|
| Wallet balances, ledger, loans, repayments | PostgreSQL | Money needs ACID transactions, constraints, double entry and reconciliation. A document store would weaken all of these. |
| Activity events (logins, browsing, searches) | MongoDB `activity_events` | Very high write volume, append only, and every event type has a different payload. A relational design would need either many sparse columns or a table per event type. |
| Notifications | MongoDB `notifications` | Read as a list per user, self contained, short lived (TTL expiry), delivery channels vary. |
| Loan application forms and KYC style payloads | MongoDB `loan_applications` | The shape depends on who applies: a salaried person has an employer, a trader has a business, a student has a school. Guarantors and documents belong to the application and are always read with it. |
| Who funded whom | MongoDB `trust_graph_edges` | A simple graph kept as edge documents, traversed with `$graphLookup`. |

### Relational against document, entity by entity

| Entity | Relational (PostgreSQL) | Document (MongoDB) | Decision |
|---|---|---|---|
| User account, KYC status | normalised tables, unique email and phone, FKs | possible but identity needs strict uniqueness and joins | stays relational |
| Wallet and ledger | double entry, CHECK, append only trigger | multi document transactions exist but no constraints equivalent | stays relational |
| Loan request, loan, schedule | FK chain, state machine triggers | would duplicate or lose integrity | stays relational |
| Loan application payload | wide nullable columns or EAV | one document per application, sub documents only where relevant | **document** |
| Activity event | one table with a JSON column, or many tables | one collection, flexible `data` object | **document** |
| Notification | simple table, works fine | list per user, TTL index removes old ones | **document** (also fine relationally) |
| Funding relationships | edge table plus recursive CTE | edge collection plus `$graphLookup` | **document** for exploration, PostgreSQL remains the truth |

## Embedding against referencing

| Relationship | Choice | Reason |
|---|---|---|
| application to guarantors | **embed** (array, max 3) | always read together, bounded size, never queried alone |
| application to documents (uploaded files metadata) | **embed** | same reasons |
| application to employer, business, school | **embed**, only the one that applies | exact shape depends on employment type |
| application to borrower and loan request | **reference** by `borrower_id` and `request_id` | these live in PostgreSQL, which owns them. Copying the user would let the copies drift |
| event to user | **reference** by `user_id` | events grow without bound; embedding them in a user document would hit the 16 MB limit |
| notification to user | **reference** | same reason |
| edge to lender and borrower | **reference** | graph nodes are users |

## Files

| File | Purpose |
|---|---|
| [schema-validation.js](schema-validation.js) | Creates the four collections with JSON Schema validators and proves they reject bad documents |
| [seed_from_postgres.py](seed_from_postgres.py) | Builds the collections from the PostgreSQL data so both databases describe the same users and requests |
| [queries.js](queries.js) | Indexes, CRUD, aggregation pipelines, `$graphLookup`, TTL demo |
| [explain.js](explain.js) | `explain("executionStats")` before and after indexing |
| [jsonb_comparison.sql](jsonb_comparison.sql) | The same documents in PostgreSQL `JSONB` with a GIN index, and the comparison |
| `evidence/` | Your screenshots and logs |

## How to run

Prerequisites: PostgreSQL loaded (Portfolio 1), MongoDB Community Server and `mongosh` installed ([docs/SETUP_WINDOWS.md](../docs/SETUP_WINDOWS.md)), the Python venv active.

```powershell
cd portfolio-4-nosql
mongosh "mongodb://localhost:27017" --file schema-validation.js       # collections + validators + 5 PASS lines
python seed_from_postgres.py --reset --also-jsonb                       # row counts printed
mongosh "mongodb://localhost:27017" --file queries.js                   # CRUD, aggregations, graph, TTL
mongosh "mongodb://localhost:27017" --file explain.js                   # before/after plans
psql -f jsonb_comparison.sql                                            # PostgreSQL JSONB comparison
```

If your MongoDB uses authentication, put the credentials in the URI (`mongodb://user:pass@localhost:27017/?authSource=admin`) and set `MONGO_URI` for the Python script. Never commit credentials.

The TTL demo in `queries.js` inserts a notification that expires in 15 seconds. MongoDB checks TTL indexes about once a minute, so wait 60 to 90 seconds and run `db.getSiblingDB('copay_docs').notifications.countDocuments({pg_id: -1})`. It should return 0.

## Design points to explain

- **Schema validation.** MongoDB is schema flexible, not schema free. Validators require the core fields (user, type, timestamp), restrict values to known enums, store money as `Decimal128` (a double would reject the insert) and limit guarantors to three, while still letting each event type or employment type carry its own extra fields.
- **Indexes.** Compound `(user_id, ts desc)` serves "a user's recent events" with no separate sort. A partial index on unread notifications is small because most notifications are read. A multikey index covers the guarantor array. A unique index mirrors the one application per request rule. A TTL index expires notifications after their `expire_at`.
- **Explain.** `explain.js` prints the winning plan and `totalDocsExamined` against `nReturned`. A collection scan examines every document; a good index makes the two numbers nearly equal.
- **Aggregation.** The pipelines compute events per user per day, a monthly funnel, notification read rate, and income by employment type. The last one gives the same figures as the JSONB query in PostgreSQL, a useful cross check that both databases hold the same data.
- **Graph.** `trust_graph_edges` plus `$graphLookup` expands the funding network around the most connected lender by hops. For serious graph work (shortest path, community detection) a graph database such as Neo4j would be the better tool, which is why it was considered and not adopted.

## Same document in PostgreSQL JSONB

`seed_from_postgres.py --also-jsonb` stores the identical 6,000 documents in `loan_applications_jsonb` with a GIN index (`jsonb_path_ops`) and an expression index for the hot field.

| Aspect | MongoDB | PostgreSQL JSONB |
|---|---|---|
| Schema enforcement | built in `$jsonSchema` validator | none by default; needs CHECK constraints |
| Query nested data | `{ "applicant.employment_type": "X" }` | `doc @> '{"applicant":{...}}'` or `#>>` paths |
| Indexing | indexes on any path, multikey for arrays | GIN for containment; expression indexes for specific paths |
| Updating part of a document | `$set`, `$push` (atomic, in place) | `jsonb_set` rewrites the whole value |
| Joins with relational data | `$lookup`, limited | full SQL joins, foreign keys to users and loan_requests |
| Transactions | multi document ACID, but not the strong suit | full ACID with the rest of the data |
| Money type | `Decimal128` | stored as string or number inside JSON (no numeric guarantee) |
| Operations | another system to run, back up and secure | nothing extra |

Conclusion: at Copay's current size JSONB alone would work and is simpler to operate. MongoDB is justified for the high volume event stream and when the application payloads grow and change quickly. Having both here lets the trade off be shown rather than only described. The ledger stays in PostgreSQL in either case.

## Considered but not implemented

| Model | Possible use at Copay | Why not built |
|---|---|---|
| Key value (Redis) | Idempotency keys with expiry, rate limiting, session cache, marketplace listing cache | The idempotency key is already stored durably in PostgreSQL with a unique constraint, which is safer for money. Redis would be added only as a fast first check or cache in front. |
| Graph (Neo4j) | Fraud rings, lender and borrower trust network, multi hop recommendations | Edge documents and `$graphLookup` cover the demonstration. A dedicated graph engine only pays off for deep traversals at scale. |
| Wide column (Cassandra) | Very high volume event or message history across regions | Volume is far below the point where it is needed; MongoDB covers the event log. |

## CAP, consistency and availability notes (MongoDB)

- A MongoDB replica set has one primary; writes go to it and are replicated to secondaries. In CAP terms it favours **consistency over availability** for writes: during a partition the side without a majority cannot elect a primary and stops accepting writes.
- Consistency is tunable per operation. Write concern `w: "majority"` makes a write durable on most nodes before it is acknowledged; read concern `"majority"` returns only data that cannot be rolled back; reading from secondaries gives faster, possibly stale reads (eventual consistency).
- For Copay: activity events and notifications tolerate eventual consistency and use default or `w:1` writes for speed. Anything involving money does not live here.
- This local setup is a single node, so these are discussion points only. Replication and failover are demonstrated for PostgreSQL in Portfolio 5.

## Evidence to capture

| File | Command | Show |
|---|---|---|
| `evidence/p4-01-validation.png` | `schema-validation.js` | collections and five PASS lines |
| `evidence/p4-02-seed.png` | `seed_from_postgres.py` | document counts |
| `evidence/p4-03-queries.png` | `queries.js` | CRUD and aggregation output |
| `evidence/p4-04-graph.png` | section 7 of `queries.js` | hops, edges, distinct borrowers |
| `evidence/p4-05-ttl.png` | TTL check after 90 seconds | count 0 |
| `evidence/p4-06-explain.png` | `explain.js` | docsExamined before and after |
| `evidence/p4-07-jsonb.png` | `jsonb_comparison.sql` | Bitmap Index Scan on the GIN index |
| `evidence/p4-08-compass.png` (optional) | MongoDB Compass | a loan application document with embedded parts |

## Testing

All scripts were run end to end on a temporary MongoDB 7.0 instance and a temporary PostgreSQL 18 instance during development (validators rejecting bad documents, seed, queries, explain, TTL deletion, and the JSONB comparison). Those runs are not evidence. Run them yourself and capture your own output.
