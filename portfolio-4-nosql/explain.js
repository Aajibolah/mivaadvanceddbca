// =============================================================================
// Portfolio 4: explain("executionStats") evidence, before and after an index.
// Run:  mongosh "mongodb://localhost:27017" --file explain.js
// Prints the winning plan stage, documents examined against returned, and time.
// A good index makes totalDocsExamined close to nReturned.
// =============================================================================
const d = db.getSiblingDB("copay_docs");

function summary(label, cursorOrExplain) {
  const e = cursorOrExplain.executionStats ? cursorOrExplain : cursorOrExplain.explain("executionStats");
  const stages = [];
  (function walk(s) { if (!s) return; stages.push(s.stage + (s.indexName ? "(" + s.indexName + ")" : ""));
    walk(s.inputStage); (s.inputStages || []).forEach(walk); })(e.queryPlanner.winningPlan.queryPlan || e.queryPlanner.winningPlan);
  const x = e.executionStats;
  print(label.padEnd(44) + " plan=" + stages.join(" > ") + " | returned=" + x.nReturned +
        " | docsExamined=" + x.totalDocsExamined + " | keysExamined=" + x.totalKeysExamined +
        " | " + x.executionTimeMillis + " ms");
}

const user = d.activity_events.aggregate([{ $group: { _id: "$user_id", n: { $sum: 1 } } }, { $sort: { n: -1 } }, { $limit: 1 }]).toArray()[0]._id;
const q = {
  events:  () => d.activity_events.find({ user_id: user }).sort({ ts: -1 }).limit(20),
  byType:  () => d.activity_events.find({ type: "LOGIN", ts: { $gte: new Date("2026-09-01") } }),
  unread:  () => d.notifications.find({ user_id: user, read_at: null }).sort({ created_at: -1 }),
  nested:  () => d.loan_applications.find({ "applicant.employment_type": "SELF_EMPLOYED", "applicant.monthly_income_ngn": { $gt: 800000 } }),
  guarant: () => d.loan_applications.find({ "guarantors.relationship": "employer" }),
  appById: () => d.loan_applications.find({ request_id: 1234 }),
};

function drop(c, n) { try { d[c].dropIndex(n); } catch (e) { /* not present */ } }

print("\n##### BEFORE: indexes removed (only _id remains) #####");
drop("activity_events", "ix_events_user_ts"); drop("activity_events", "ix_events_type_ts");
drop("notifications", "ix_notif_unread"); drop("notifications", "ix_notif_user");
drop("loan_applications", "ix_app_emp_income"); drop("loan_applications", "ix_app_guarantor_rel"); drop("loan_applications", "ux_app_request");
Object.keys(q).forEach(k => summary("before  " + k, q[k]()));

print("\n##### AFTER: indexes from queries.js #####");
d.activity_events.createIndex({ user_id: 1, ts: -1 }, { name: "ix_events_user_ts" });
d.activity_events.createIndex({ type: 1, ts: -1 }, { name: "ix_events_type_ts" });
d.notifications.createIndex({ user_id: 1, created_at: -1 }, { name: "ix_notif_unread", partialFilterExpression: { read_at: null } });
d.notifications.createIndex({ user_id: 1, created_at: -1 }, { name: "ix_notif_user" });
d.loan_applications.createIndex({ "applicant.employment_type": 1, "applicant.monthly_income_ngn": -1 }, { name: "ix_app_emp_income" });
d.loan_applications.createIndex({ "guarantors.relationship": 1 }, { name: "ix_app_guarantor_rel" });
d.loan_applications.createIndex({ request_id: 1 }, { unique: true, name: "ux_app_request" });
Object.keys(q).forEach(k => summary("after   " + k, q[k]()));
print("\nRun queries.js again if you want the full index set restored (this script recreates all that it removed).");
