// =============================================================================
// Portfolio 4: MongoDB operations for Copay: CRUD, aggregation pipelines,
// indexes (compound, unique, partial, multikey, TTL) and a graph traversal.
// Run:  mongosh "mongodb://localhost:27017" --file queries.js
// Prerequisite: schema-validation.js and seed_from_postgres.py
// =============================================================================
const d = db.getSiblingDB("copay_docs");
function section(t) { print("\n=== " + t + " ==="); }
function show(x) { printjson(x); }

// -----------------------------------------------------------------------------
section("0. Indexes (created before the queries so every access path is covered)");
// Compound: the access pattern is "a user's recent events", equality then sort.
d.activity_events.createIndex({ user_id: 1, ts: -1 }, { name: "ix_events_user_ts" });
// Compound for analytics by type and time.
d.activity_events.createIndex({ type: 1, ts: -1 }, { name: "ix_events_type_ts" });
// Unique: one application per loan request (mirrors loan_requests.id in PostgreSQL).
d.loan_applications.createIndex({ request_id: 1 }, { unique: true, name: "ux_app_request" });
d.loan_applications.createIndex({ borrower_id: 1, submitted_at: -1 }, { name: "ix_app_borrower" });
// Multikey: indexes every element of the guarantors array.
d.loan_applications.createIndex({ "guarantors.relationship": 1 }, { name: "ix_app_guarantor_rel" });
// Compound on a nested field.
d.loan_applications.createIndex({ "applicant.employment_type": 1, "applicant.monthly_income_ngn": -1 }, { name: "ix_app_emp_income" });
// Partial: only UNREAD notifications are looked up by user, and they are a minority.
d.notifications.createIndex({ user_id: 1, created_at: -1 },
  { name: "ix_notif_unread", partialFilterExpression: { read_at: null } });
d.notifications.createIndex({ user_id: 1, created_at: -1 }, { name: "ix_notif_user" });
// TTL: MongoDB deletes a notification once its expire_at time has passed (checked about every 60 seconds).
d.notifications.createIndex({ expire_at: 1 }, { expireAfterSeconds: 0, name: "ttl_notif_expire" });
// Graph edges: both directions.
d.trust_graph_edges.createIndex({ lender_id: 1, borrower_id: 1 }, { unique: true, name: "ux_edge_pair" });
d.trust_graph_edges.createIndex({ borrower_id: 1 }, { name: "ix_edge_borrower" });
print("Indexes created.");

// -----------------------------------------------------------------------------
section("1. CRUD");
// Create
const ins = d.activity_events.insertOne({ user_id: NumberInt(4), type: "LOGIN", ts: new Date(), source: "mobile",
  session_id: "demo", data: { method: "biometric", success: true, device: { os: "android", app_version: "2.4.1" } } });
print("insertOne acknowledged: " + ins.acknowledged);
// Read with projection and sort
show(d.activity_events.find({ user_id: 4 }, { _id: 0, type: 1, ts: 1, source: 1 }).sort({ ts: -1 }).limit(3).toArray());
// Update: set a field on one document
d.activity_events.updateOne({ _id: ins.insertedId }, { $set: { "data.success": false } });
// Update: push into an array (add a guarantor) on one application
const app = d.loan_applications.findOne({ "guarantors.0": { $exists: true } }, { request_id: 1 });
d.loan_applications.updateOne({ request_id: app.request_id },
  { $push: { guarantors: { name: "Test Guarantor", phone: "+2348000000000", relationship: "friend" } } });
// Update many: mark all unread notifications older than 2 years as expired later (example, nothing matches by design)
print("updateMany matched: " + d.notifications.updateMany({ created_at: { $lt: new Date("2000-01-01") } }, { $set: { channels: [] } }).matchedCount);
// Delete
print("deleteOne deleted: " + d.activity_events.deleteOne({ _id: ins.insertedId }).deletedCount);
// Validation in action: this update would break the schema (4th guarantor) and is rejected.
try {
  d.loan_applications.updateOne({ request_id: app.request_id }, { $push: { guarantors: { $each: [1, 2, 3].map(i => ({ name: "x", phone: "y", relationship: "z" })) } } });
  print("UNEXPECTED: schema violation accepted");
} catch (e) { print("PASS  schema validation rejected the update [" + (e.codeName || e.code) + "]"); }

// -----------------------------------------------------------------------------
section("2. Aggregation: events per user per day (top 5 busiest user days)");
show(d.activity_events.aggregate([
  { $match: { source: { $ne: "system" } } },
  { $group: { _id: { user_id: "$user_id", day: { $dateToString: { format: "%Y-%m-%d", date: "$ts" } } }, events: { $sum: 1 } } },
  { $sort: { events: -1 } }, { $limit: 5 }
]).toArray());

section("3. Aggregation: event mix per month (conversion style funnel)");
show(d.activity_events.aggregate([
  { $match: { type: { $in: ["VIEW_MARKETPLACE", "VIEW_LOAN", "LOAN_REQUEST_CREATED"] } } },
  { $group: { _id: { month: { $dateToString: { format: "%Y-%m", date: "$ts" } }, type: "$type" }, n: { $sum: 1 } } },
  { $group: { _id: "$_id.month", counts: { $push: { type: "$_id.type", n: "$n" } }, total: { $sum: "$n" } } },
  { $sort: { _id: -1 } }, { $limit: 3 }
]).toArray());

section("4. Aggregation: notification read rate by type");
show(d.notifications.aggregate([
  { $group: { _id: "$type", sent: { $sum: 1 }, read: { $sum: { $cond: [{ $ne: ["$read_at", null] }, 1, 0] } } } },
  { $project: { type: "$_id", _id: 0, sent: 1, read: 1, read_rate_pct: { $round: [{ $multiply: [{ $divide: ["$read", "$sent"] }, 100] }, 1] } } },
  { $sort: { read_rate_pct: -1 } }
]).toArray());

section("5. Aggregation: applicants by employment type (average stated income, with Decimal128 amounts)");
show(d.loan_applications.aggregate([
  { $group: { _id: "$applicant.employment_type", applications: { $sum: 1 },
              avg_income_ngn: { $avg: "$applicant.monthly_income_ngn" },
              avg_requested: { $avg: "$requested_amount" },
              avg_guarantors: { $avg: { $size: "$guarantors" } } } },
  { $project: { applications: 1, avg_income_ngn: { $round: ["$avg_income_ngn", 0] },
                avg_requested: { $round: ["$avg_requested", 2] }, avg_guarantors: { $round: ["$avg_guarantors", 2] } } },
  { $sort: { applications: -1 } }
]).toArray());

section("6. Query nested fields and arrays");
print("Self employed, registered business, income over 500,000: " +
  d.loan_applications.countDocuments({ "applicant.employment_type": "SELF_EMPLOYED", "applicant.business.cac_registered": true,
                                       "applicant.monthly_income_ngn": { $gt: 500000 } }));
print("Applications with a 'colleague' guarantor and an unverified document: " +
  d.loan_applications.countDocuments({ "guarantors.relationship": "colleague", documents: { $elemMatch: { verified: false } } }));

section("7. Graph traversal ($graphLookup): who is reachable through the funding network from one lender?");
// Edge direction: lender -> borrower. A borrower who is also a lender continues the path.
const hub = d.trust_graph_edges.aggregate([{ $group: { _id: "$lender_id", n: { $sum: 1 } } }, { $sort: { n: -1 } }, { $limit: 1 }]).toArray()[0];
print("Most connected lender: " + hub._id + " (" + hub.n + " borrowers)");
// hops 0 = the lender's own borrowers, hop 1 = people those borrowers lent to, hop 2 = the next ring.
show(d.trust_graph_edges.aggregate([
  { $match: { lender_id: hub._id } },
  { $limit: 1 },
  { $graphLookup: { from: "trust_graph_edges", startWith: "$lender_id", connectFromField: "borrower_id",
                    connectToField: "lender_id", as: "network", maxDepth: 2, depthField: "hops" } },
  { $unwind: "$network" },
  { $group: { _id: "$network.hops", edges: { $sum: 1 }, distinct_borrowers: { $addToSet: "$network.borrower_id" } } },
  { $project: { _id: 0, hops: "$_id", edges: 1, distinct_borrowers: { $size: "$distinct_borrowers" } } },
  { $sort: { hops: 1 } }
]).toArray());

// -----------------------------------------------------------------------------
section("8. TTL demo: a notification that expires in 15 seconds");
const ttlDoc = d.notifications.insertOne({ pg_id: NumberInt(-1), user_id: NumberInt(4), type: "SYSTEM", title: "TTL demo",
  body: "This message deletes itself", created_at: new Date(), read_at: new Date(), channels: ["in_app"],
  expire_at: new Date(Date.now() + 15000) });
print("inserted TTL demo document; present now: " + d.notifications.countDocuments({ pg_id: -1 }));
print("Wait about 60 to 90 seconds (the TTL monitor runs every 60 s), then run:");
print("   db.getSiblingDB('copay_docs').notifications.countDocuments({pg_id: -1})   // expect 0");

section("9. Collection sizes");
show(["activity_events", "notifications", "loan_applications", "trust_graph_edges"].map(c => {
  const s = d[c].stats(); return { collection: c, docs: s.count, dataMB: +(s.size / 1048576).toFixed(2), indexMB: +(s.totalIndexSize / 1048576).toFixed(2) };
}));
