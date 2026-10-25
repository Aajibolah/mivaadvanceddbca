# Copay entity relationship diagram

Source text (Mermaid). To produce `er-diagram.png`, paste the block into https://mermaid.live and export PNG, or run `npx @mermaid-js/mermaid-cli -i er-diagram.md -o er-diagram.png` (needs Node.js). Save the PNG in this folder.

```mermaid
erDiagram
    USERS ||--o| KYC_PROFILES : "has"
    USERS ||--o| WALLETS : "owns (kind=USER)"
    USERS ||--o{ BANK_ACCOUNTS : "registers"
    USERS ||--o{ LOAN_REQUESTS : "borrows via"
    USERS ||--o{ LOAN_FUNDINGS : "lends via"
    LOAN_REQUESTS ||--o{ LOAN_FUNDINGS : "funded by"
    LOAN_REQUESTS ||--o| LOANS : "becomes"
    USERS ||--o{ LOANS : "borrower of"
    LOANS ||--|{ REPAYMENT_SCHEDULES : "has instalments"
    REPAYMENT_SCHEDULES ||--o{ REPAYMENTS : "paid by"
    LOANS ||--o{ REPAYMENTS : "receives"
    USERS ||--o{ REPAYMENTS : "pays"
    LOANS ||--o{ FEES : "charges"
    LOANS ||--o{ DISPUTES : "subject of"
    USERS ||--o{ DISPUTES : "raises"
    USERS ||--o| TRUST_SCORES : "scored by"
    USERS ||--o{ NOTIFICATIONS : "receives"
    USERS ||--o{ AUDIT_LOGS : "acts in"
    LEDGER_TRANSACTIONS ||--|{ LEDGER_ENTRIES : "balanced set of"
    WALLETS ||--o{ LEDGER_ENTRIES : "debited or credited by"
    LEDGER_TRANSACTIONS ||--o| LOAN_FUNDINGS : "records"
    LEDGER_TRANSACTIONS ||--o| REPAYMENTS : "records"
    LEDGER_TRANSACTIONS ||--o{ FEES : "records"

    USERS {
        bigint id PK
        text email UK
        text phone UK
        text full_name
        user_role role
        user_status status
        timestamptz created_at
        timestamptz deleted_at
    }
    KYC_PROFILES {
        bigint user_id PK, FK
        kyc_status status
        smallint level
        text bvn_hash
        timestamptz verified_at
    }
    WALLETS {
        bigint id PK
        bigint user_id FK "NULL for system wallets"
        wallet_kind kind
        numeric balance "cached, CHECK >= 0"
        int version
    }
    BANK_ACCOUNTS {
        bigint id PK
        bigint user_id FK
        char bank_code
        char account_number
    }
    LOAN_REQUESTS {
        bigint id PK
        bigint borrower_id FK
        numeric amount
        smallint tenor_weeks
        numeric interest_rate_pct
        request_status status
        numeric funded_amount
        timestamptz expires_at
    }
    LOAN_FUNDINGS {
        bigint id PK
        bigint loan_request_id FK
        bigint lender_id FK
        numeric amount
        text idempotency_key UK
        bigint ledger_txn_id FK, UK
    }
    LOANS {
        bigint id PK
        bigint loan_request_id FK, UK
        bigint borrower_id FK
        numeric principal
        numeric platform_fee
        loan_status status
        timestamptz disbursed_at
    }
    REPAYMENT_SCHEDULES {
        bigint id PK
        bigint loan_id FK
        smallint instalment_no "UK with loan_id"
        date due_date
        numeric amount_due
        numeric amount_paid
        instalment_status status
    }
    REPAYMENTS {
        bigint id PK
        bigint loan_id FK
        bigint schedule_id FK
        bigint payer_id FK
        numeric amount
        text idempotency_key UK
        bigint ledger_txn_id FK, UK
    }
    LEDGER_TRANSACTIONS {
        bigint id PK
        txn_type txn_type
        text reference UK
        text idempotency_key UK
        timestamptz created_at
    }
    LEDGER_ENTRIES {
        bigint id PK
        bigint txn_id FK
        bigint wallet_id FK
        numeric amount "signed, never 0"
        timestamptz created_at
    }
    FEES {
        bigint id PK
        bigint loan_id FK
        bigint ledger_txn_id FK
        numeric amount
    }
    TRUST_SCORES {
        bigint user_id PK, FK
        smallint score
        numeric on_time_rate
    }
    DISPUTES {
        bigint id PK
        bigint loan_id FK
        bigint raised_by FK
        dispute_status status
    }
    NOTIFICATIONS {
        bigint id PK
        bigint user_id FK
        notification_type type
        timestamptz read_at
    }
    AUDIT_LOGS {
        bigint id PK
        bigint actor_user_id FK
        text action
        jsonb details
    }
```

## Reading the diagram

- **Money flows only through the ledger.** `LEDGER_TRANSACTIONS` is the header and `LEDGER_ENTRIES` are the signed legs. `LOAN_FUNDINGS`, `REPAYMENTS` and `FEES` point at the ledger transaction that moved the money, so a business event can always be traced to its accounting record.
- **System wallets.** `WALLETS.user_id` is NULL for the three system wallets (EXTERNAL, ESCROW, FEES). They give every movement a counterparty, which is what makes double entry possible.
- **One request, one loan.** `LOANS.loan_request_id` is unique, so a request becomes at most one loan, created only after it is fully funded.
