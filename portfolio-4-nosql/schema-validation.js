// =============================================================================
// Portfolio 4: MongoDB collections with JSON Schema validation (Copay)
// Run:  mongosh "mongodb://localhost:27017" --file schema-validation.js
// (add credentials to the URI if your MongoDB requires them)
//
// The document database is deliberately NOT the system of record for money.
// Balances, the ledger and loans stay in PostgreSQL where ACID transactions and
// constraints protect them. MongoDB holds data that is high volume, append heavy
// or variable in shape. Validators keep that flexible data honest: required core
// fields are enforced, optional parts may vary.
// WARNING: this script DROPS and recreates the four collections.
// =============================================================================
const dbName = "copay_docs";
const d = db.getSiblingDB(dbName);
["activity_events", "notifications", "loan_applications", "trust_graph_edges"].forEach(c => d[c].drop());

// ---- 1. activity_events: high write event log, payload differs by event type ----
d.createCollection("activity_events", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["user_id", "type", "ts", "source"],
    properties: {
      user_id: { bsonType: ["int", "long"], minimum: 1 },
      type: { enum: ["LOGIN", "VIEW_MARKETPLACE", "VIEW_LOAN", "SEARCH", "WALLET_VIEW",
                     "USER_REGISTERED", "KYC_VERIFIED", "LOAN_REQUEST_CREATED", "LOAN_REQUEST_FUNDED"] },
      ts: { bsonType: "date" },
      source: { enum: ["mobile", "web", "system"] },
      session_id: { bsonType: "string" },
      data: { bsonType: "object" }            // free form: each event type has its own shape
    }
  } },
  validationLevel: "strict", validationAction: "error"
});

// ---- 2. notifications: one document per message, channels embedded ----
d.createCollection("notifications", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["pg_id", "user_id", "type", "title", "body", "created_at"],
    properties: {
      pg_id: { bsonType: ["int", "long"] },   // id of the row in PostgreSQL notifications
      user_id: { bsonType: ["int", "long"] },
      type: { enum: ["LOAN_FUNDED", "REPAYMENT_RECEIVED", "REPAYMENT_DUE", "KYC_UPDATE", "SYSTEM"] },
      title: { bsonType: "string" },
      body: { bsonType: "string" },
      created_at: { bsonType: "date" },
      read_at: { bsonType: ["date", "null"] },
      channels: { bsonType: "array", items: { enum: ["push", "sms", "email", "in_app"] } },
      expire_at: { bsonType: "date" }         // TTL: document removed by MongoDB after this time
    }
  } },
  validationLevel: "strict", validationAction: "error"
});

// ---- 3. loan_applications: flexible nested payload, embedded sub documents ----
d.createCollection("loan_applications", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["request_id", "borrower_id", "submitted_at", "requested_amount", "applicant"],
    properties: {
      request_id: { bsonType: ["int", "long"] },        // reference to PostgreSQL loan_requests.id
      borrower_id: { bsonType: ["int", "long"] },       // reference to PostgreSQL users.id
      submitted_at: { bsonType: "date" },
      requested_amount: { bsonType: "decimal" },        // money as Decimal128, never double
      applicant: {
        bsonType: "object",
        required: ["employment_type"],
        properties: {
          employment_type: { enum: ["SALARIED", "SELF_EMPLOYED", "STUDENT", "CIVIL_SERVANT"] },
          monthly_income_ngn: { bsonType: ["int", "long"], minimum: 0 }
          // employer / business / school sub documents exist only for the matching type
        }
      },
      guarantors: {
        bsonType: "array", maxItems: 3,
        items: { bsonType: "object", required: ["name", "phone", "relationship"] }
      },
      documents: {
        bsonType: "array",
        items: { bsonType: "object", required: ["type", "uploaded_at", "verified"],
                 properties: { verified: { bsonType: "bool" } } }
      }
    }
  } },
  validationLevel: "strict", validationAction: "error"
});

// ---- 4. trust_graph_edges: who has funded whom (graph in documents) ----
d.createCollection("trust_graph_edges", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["lender_id", "borrower_id", "fundings", "total_amount"],
    properties: {
      lender_id: { bsonType: ["int", "long"] },
      borrower_id: { bsonType: ["int", "long"] },
      fundings: { bsonType: ["int", "long"], minimum: 1 },
      total_amount: { bsonType: "decimal" },
      first_at: { bsonType: "date" },
      last_at: { bsonType: "date" }
    }
  } },
  validationLevel: "strict", validationAction: "error"
});

print("Collections in " + dbName + ": " + d.getCollectionNames().join(", "));

// ---- Proof that the validators work (each insert below must be REJECTED) ----
function expectReject(label, coll, doc) {
  try { d[coll].insertOne(doc); print("FAIL  " + label + " (accepted)"); d[coll].deleteOne({ _id: doc._id }); }
  catch (e) { print("PASS  " + label + "  [" + (e.codeName || e.code) + "]"); }
}
expectReject("event without a type", "activity_events", { user_id: NumberInt(1), ts: new Date(), source: "web" });
expectReject("event with an unknown type", "activity_events", { user_id: NumberInt(1), type: "HACK", ts: new Date(), source: "web" });
expectReject("notification with wrong type", "notifications",
  { pg_id: NumberInt(1), user_id: NumberInt(1), type: "SPAM", title: "t", body: "b", created_at: new Date() });
expectReject("application amount stored as a double", "loan_applications",
  { request_id: NumberInt(1), borrower_id: NumberInt(1), submitted_at: new Date(), requested_amount: 50000.5,
    applicant: { employment_type: "SALARIED" } });
expectReject("application with 4 guarantors", "loan_applications",
  { request_id: NumberInt(1), borrower_id: NumberInt(1), submitted_at: new Date(), requested_amount: NumberDecimal("50000.00"),
    applicant: { employment_type: "SALARIED" },
    guarantors: [1, 2, 3, 4].map(i => ({ name: "g" + i, phone: "+2348000000000", relationship: "friend" })) });
