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

Prerequisites: PostgreSQL loaded (Portfolio 1), a MongoDB server running on `localhost:27017` (I used MongoDB Community Server 9.0.4 as a Windows service), MongoDB Compass for the shell, and the Python venv active ([docs/SETUP_WINDOWS.md](../docs/SETUP_WINDOWS.md)).

| Step | Tool | What |
|---|---|---|
| 1 | Compass shell (`>_MONGOSH`) | paste `schema-validation.js`: collections, validators and five PASS lines |
| 2 | PowerShell | `python portfolio-4-nosql\seed_from_postgres.py --reset --also-jsonb`: loads the collections from PostgreSQL and the JSONB copy |
| 3 | Compass shell | paste `queries.js`: indexes, CRUD, aggregations, graph traversal and the TTL demo |
| 4 | Compass shell | after 90 seconds, `db.getSiblingDB('copay_docs').notifications.countDocuments({pg_id: -1})` returns 0 |
| 5 | Compass shell | paste `explain.js`: plans before and after indexing |
| 6 | pgAdmin | the statements from `jsonb_comparison.sql` one at a time (psql only commands removed) |
| 7 | Compass | browse the collections, the Indexes tab and the Validation tab for the screenshots |

The same scripts also run from a terminal with `mongosh "mongodb://localhost:27017" --file <script>` once the standalone `mongosh` is installed. If your MongoDB uses authentication, put the credentials in `MONGO_URI` and never commit them.

The TTL demo in `queries.js` inserts a notification that expires in 15 seconds. MongoDB checks TTL indexes about once a minute, so I waited 90 seconds before running the count.

## Tools used and why

MongoDB cannot be reached from pgAdmin, so the document database work used **MongoDB Compass**: its built in MongoDB shell ran the JavaScript scripts, and its collection views gave the screenshots of a nested document, the indexes and the validation rules. The Python seeder is a script and ran in **PowerShell**. The JSONB comparison is plain PostgreSQL, so I ran it in **pgAdmin**, one statement at a time, because the original file uses psql only commands and pgAdmin shows only the last result of a multi statement run. I did not install the standalone `mongosh` because Compass includes the same shell and disk space on my laptop was limited.

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

## Evidence

| File | Tool | Shows |
|---|---|---|
| `evidence/p4-01-validation.png` | Compass shell | four collections created and five invalid documents rejected (code 121) |
| `evidence/p4-02-seed.png` | PowerShell | notifications 22,178; trust edges 8,410; loan applications 6,004; activity events 80,419; JSONB copy 6,004 |
| `evidence/p4-03-queries-a.png` to `p4-03-queries-d.png` | Compass shell | indexes, CRUD, schema validation rejecting an update, events per user per day, monthly funnel, notification read rate, applicants by employment type, nested and array queries |
| `evidence/p4-04-graph.png` | Compass shell | `$graphLookup` from the most connected lender: 396, 493 and 313 edges at hops 0, 1 and 2 |
| `evidence/p4-05-ttl-1.png`, `p4-05-ttl-2.png` | Compass shell | the TTL demo document is present, then count 0 after the wait |
| `evidence/p4-05-collection-sizes.png` | Compass shell | document and index sizes per collection |
| `evidence/p4-06-explain-before.png`, `p4-06-explain-after.png` | Compass shell | COLLSCAN examining every document, then IXSCAN examining about as many as returned (events: 80,419 examined before, 20 after) |
| `evidence/p4-07-1-jsonb-table.png` to `p4-07-7-jsonb-no-validation.png` | pgAdmin | the same applications as JSONB: sequential scan against GIN bitmap scan, array containment, expression index, aggregation equal to MongoDB, and JSONB accepting an invalid document |
| `evidence/p4-08-compass.png` | Compass | one loan application with embedded applicant, guarantors, documents and device |
| `evidence/p4-09-indexes.png` | Compass | notifications indexes: TTL, partial and compound |
| `evidence/p4-10-validation-tab.png` | Compass | the JSON Schema validator on loan applications (error action, strict level) |

### Results worth noting

- **Indexes work as designed.** For a user's recent events, MongoDB examined 80,419 documents without an index and 20 with the compound index.
- **Both stores hold the same documents.** The average stated income per employment type from the MongoDB aggregation (SALARIED 671,089; SELF_EMPLOYED 774,908; STUDENT 27,995; CIVIL_SERVANT 285,422) is identical to the JSONB aggregation in PostgreSQL.
- **A GIN index is not always used.** The nested filter and the income range used the indexes (53.6 ms down to 3.1 ms for the nested filter), but the array containment query (`guarantors` with relationship `employer`, about 20 percent of the table) still used a sequential scan, because for a query that matches a fifth of a small table the planner judges a full scan cheaper.
- **JSONB has no schema validation.** The invalid document with employment type WIZARD and guarantors that is not an array was accepted, whereas MongoDB rejected the same kind of document in step 1.

## Testing

I ran every script myself against MongoDB Community Server 9.0.4 and PostgreSQL 18.1 on my laptop, and the screenshots above come from those runs. The validators rejected all five invalid documents, the seed loaded all four collections, the TTL document was removed by MongoDB after the wait, and `explain` showed collection scans turning into index scans.
