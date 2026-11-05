-- Loan Application Processing: PostgreSQL schema (owned by foundation / system API)
-- Idempotent where practical. Loaded automatically by docker-compose on first start.

CREATE SEQUENCE IF NOT EXISTS application_seq START 1;

-- ---------------------------------------------------------------- reference data
CREATE TABLE IF NOT EXISTS products (
    code                    VARCHAR(10) PRIMARY KEY,
    name                    VARCHAR(100)  NOT NULL,
    min_amount              NUMERIC(14,2) NOT NULL,
    max_amount              NUMERIC(14,2) NOT NULL,
    min_tenure_months       INT           NOT NULL,
    max_tenure_months       INT           NOT NULL,
    annual_rate_pct         NUMERIC(5,2)  NOT NULL,
    min_age_at_application  INT           NOT NULL,
    max_age_at_application  INT           NOT NULL,
    max_age_at_maturity     INT           NOT NULL,
    emi_ceiling_pct         NUMERIC(5,2)  NOT NULL,   -- max EMI as % of net income
    amount_step             NUMERIC(10,2) NOT NULL DEFAULT 1000,
    active                  BOOLEAN       NOT NULL DEFAULT TRUE
);

-- Checklist per product. Editing rows here changes the checklist with no redeploy (FR 5).
CREATE TABLE IF NOT EXISTS product_document_rules (
    id                  SERIAL PRIMARY KEY,
    product_code        VARCHAR(10) NOT NULL REFERENCES products(code),
    doc_type            VARCHAR(40) NOT NULL,
    description         VARCHAR(200) NOT NULL,         -- plain-language text used in emails
    required_count      INT         NOT NULL CHECK (required_count > 0),
    max_size_bytes      BIGINT      NOT NULL CHECK (max_size_bytes > 0),
    allowed_extensions  TEXT[]      NOT NULL,          -- lowercase, no dot
    allowed_mime_types  TEXT[]      NOT NULL,
    UNIQUE (product_code, doc_type)
);

CREATE TABLE IF NOT EXISTS scorecard_versions (
    version             VARCHAR(20) PRIMARY KEY,
    approve_min_score   NUMERIC(5,2) NOT NULL,   -- score >= this: APPROVED
    refer_min_score     NUMERIC(5,2) NOT NULL,   -- score >= this (and < approve): REFERRED, else DECLINED
    offer_validity_days INT          NOT NULL,
    active              BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS scorecard_config (
    version         VARCHAR(20) NOT NULL REFERENCES scorecard_versions(version),
    factor          VARCHAR(40) NOT NULL,
    weight          NUMERIC(5,2) NOT NULL,
    zero_points_at  NUMERIC(14,4) NOT NULL,   -- value giving 0 points
    full_points_at  NUMERIC(14,4) NOT NULL,   -- value giving 100 points (linear in between)
    PRIMARY KEY (version, factor)
);

-- Mock credit bureau and applicant history (read by the bureau mock in the system API).
CREATE TABLE IF NOT EXISTS applicant_history (
    identity_ref         VARCHAR(20) PRIMARY KEY,
    bureau_score         INT     NOT NULL,
    missed_payments_24m  INT     NOT NULL DEFAULT 0,
    active_default       BOOLEAN NOT NULL DEFAULT FALSE
);

-- Runtime switches, e.g. bureau_enabled = 'false' to demo DATA_UNAVAILABLE (AC 11).
CREATE TABLE IF NOT EXISTS system_flags (
    flag_key    VARCHAR(60) PRIMARY KEY,
    flag_value  VARCHAR(200) NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- transactional data
CREATE TABLE IF NOT EXISTS applications (
    application_id        VARCHAR(20) PRIMARY KEY
                          DEFAULT ('APP-' || to_char(now(),'YYYY') || '-' || lpad(nextval('application_seq')::text, 6, '0')),
    request_id            VARCHAR(80)  NOT NULL UNIQUE,          -- client idempotency key (FR 3)
    payload_hash          VARCHAR(64)  NOT NULL,              -- SHA-256 of canonical payload; same id + other hash = 409
    correlation_id        UUID         NOT NULL,
    product_code          VARCHAR(10)  NOT NULL REFERENCES products(code),
    requested_amount      NUMERIC(14,2) NOT NULL,
    requested_tenure      INT          NOT NULL,
    applicant_name        VARCHAR(120) NOT NULL,
    date_of_birth         DATE         NOT NULL,
    identity_ref          VARCHAR(20)  NOT NULL,
    email                 VARCHAR(160) NOT NULL,
    monthly_income        NUMERIC(14,2) NOT NULL,
    monthly_obligations   NUMERIC(14,2) NOT NULL DEFAULT 0,
    employment_months     INT          NOT NULL DEFAULT 0,
    manifest              JSONB        NOT NULL,                 -- {folder, documentCount, documents:[{fileName,type,sha256?}]}
    stage                 VARCHAR(30)  NOT NULL DEFAULT 'RECEIVED'
                          CHECK (stage IN ('RECEIVED','VERIFYING','DOCUMENTS_INCOMPLETE','VERIFIED',
                                           'SCORING','APPROVED','DECLINED','REFERRED')),
    stage_reason          VARCHAR(60),                           -- e.g. MANIFEST_MISMATCH, DATA_UNAVAILABLE
    verification_round    INT          NOT NULL DEFAULT 1,       -- bumped on each resubmit
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_applications_stage ON applications(stage);

CREATE TABLE IF NOT EXISTS outbox (
    id              UUID PRIMARY KEY,                 -- = messageId in the envelope
    queue_name      VARCHAR(60) NOT NULL,
    payload         JSONB       NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT')),
    attempts        INT         NOT NULL DEFAULT 0,
    last_error      VARCHAR(300),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at         TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(created_at) WHERE status = 'PENDING';

CREATE TABLE IF NOT EXISTS application_documents (
    id              BIGSERIAL PRIMARY KEY,
    application_id  VARCHAR(20) NOT NULL REFERENCES applications(application_id),
    doc_type        VARCHAR(40),                       -- null for unexpected files
    file_name       VARCHAR(255) NOT NULL,
    status          VARCHAR(15) NOT NULL CHECK (status IN ('ACCEPTED','QUARANTINED','UNEXPECTED','DUPLICATE')),
    reason          VARCHAR(40),                       -- FILE_TOO_LARGE, UNSUPPORTED_TYPE, EMPTY_OR_UNREADABLE, DUPLICATE_CONTENT
    size_bytes      BIGINT,
    sha256          VARCHAR(64),
    source_path     VARCHAR(500) NOT NULL,
    stored_path     VARCHAR(500),                      -- verified/ or quarantine/ location
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (application_id, source_path)               -- safe upsert on re-verification
);
-- Same content counted once per application (scenario 16)
CREATE UNIQUE INDEX IF NOT EXISTS uq_app_doc_digest
    ON application_documents(application_id, sha256) WHERE status = 'ACCEPTED';

CREATE TABLE IF NOT EXISTS credit_decisions (
    application_id      VARCHAR(20) PRIMARY KEY REFERENCES applications(application_id),  -- one decision per application
    decision            VARCHAR(10) NOT NULL CHECK (decision IN ('APPROVED','DECLINED','REFERRED')),
    score               NUMERIC(6,2),
    scorecard_version   VARCHAR(20) NOT NULL,
    deciding_rule       VARCHAR(40),                  -- e.g. HP-02, DATA_UNAVAILABLE, BAND
    reason_codes        TEXT[]      NOT NULL DEFAULT '{}',
    requested_amount    NUMERIC(14,2) NOT NULL,
    approved_amount     NUMERIC(14,2),
    approved_tenure     INT,
    approved_rate_pct   NUMERIC(5,2),
    instalment          NUMERIC(14,2),
    affordability_ratio NUMERIC(6,4),
    reduction_reason    VARCHAR(40),
    offer_expires_at    TIMESTAMPTZ,
    decided_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS decision_rule_hits (
    id              BIGSERIAL PRIMARY KEY,
    application_id  VARCHAR(20) NOT NULL REFERENCES applications(application_id),
    rule_code       VARCHAR(40) NOT NULL,            -- factor name or HP-01..HP-03
    rule_type       VARCHAR(10) NOT NULL CHECK (rule_type IN ('FACTOR','HARD_RULE')),
    input_value     NUMERIC(14,4),
    weight          NUMERIC(5,2),
    points          NUMERIC(6,2),
    contribution    NUMERIC(6,2),
    triggered       BOOLEAN,                         -- hard rules only
    UNIQUE (application_id, rule_code)
);

CREATE TABLE IF NOT EXISTS decision_audit (
    id              BIGSERIAL PRIMARY KEY,
    application_id  VARCHAR(20) NOT NULL,
    correlation_id  UUID        NOT NULL,
    event           VARCHAR(40) NOT NULL,            -- RECEIVED, VERIFYING, ..., NOTIFIED
    from_stage      VARCHAR(30),
    to_stage        VARCHAR(30),
    source_app      VARCHAR(40) NOT NULL,
    detail          JSONB       NOT NULL DEFAULT '{}',   -- no identity numbers or income here
    created_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS idx_audit_app ON decision_audit(application_id, id);

-- Append-only: block UPDATE and DELETE at the database level (FR 18)
CREATE OR REPLACE FUNCTION decision_audit_immutable() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'decision_audit is append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_decision_audit_immutable ON decision_audit;
CREATE TRIGGER trg_decision_audit_immutable
    BEFORE UPDATE OR DELETE ON decision_audit
    FOR EACH ROW EXECUTE FUNCTION decision_audit_immutable();

-- One email per application, template and verification round (a resubmit may need a new DOCUMENTS_MISSING email)
CREATE TABLE IF NOT EXISTS notifications (
    id              BIGSERIAL PRIMARY KEY,
    application_id  VARCHAR(20) NOT NULL REFERENCES applications(application_id),
    template        VARCHAR(20) NOT NULL CHECK (template IN ('APPROVED','DECLINED','REFERRED','DOCUMENTS_MISSING')),
    round           INT         NOT NULL DEFAULT 1,
    status          VARCHAR(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RETRYING','SENT','FAILED')),
    attempts        INT         NOT NULL DEFAULT 0,
    last_error      VARCHAR(300),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at         TIMESTAMPTZ,
    UNIQUE (application_id, template, round)
);

CREATE TABLE IF NOT EXISTS processed_messages (
    consumer        VARCHAR(40) NOT NULL,
    message_id      UUID        NOT NULL,
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer, message_id)
);
