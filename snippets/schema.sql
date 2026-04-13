-- =============================================================================
-- CRM Platform – Complete DDL (PostgreSQL 15+)
-- =============================================================================
-- Run as a superuser or a role with CREATE privileges.
-- Uses uuidv7() for time-sortable primary keys.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------
-- UUID v7 helper – time-sortable UUIDs
-- -----------------------------------------------------------
CREATE OR REPLACE FUNCTION uuidv7() RETURNS uuid AS $$
  SELECT encode(
    set_bit(
      set_bit(
        overlay(
          uuid_send(gen_random_uuid())
          placing substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) from 3)
          from 1 for 6
        ),
        52, 1
      ),
      53, 1
    ),
    'hex'
  )::uuid;
$$ LANGUAGE sql VOLATILE;

-- -----------------------------------------------------------
-- EXTENSIONS
-- -----------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- -----------------------------------------------------------
-- TENANTS
-- -----------------------------------------------------------
CREATE TABLE tenants (
    id              UUID PRIMARY KEY DEFAULT uuidv7(),
    name            TEXT NOT NULL,
    slug            TEXT NOT NULL UNIQUE,
    plan_tier       TEXT NOT NULL DEFAULT 'standard'
                    CHECK (plan_tier IN ('standard','professional','enterprise')),
    partition_number SMALLINT NOT NULL,  -- assigned by Tenant Service at onboarding based on capacity.
                                         -- 0-59 = shared partitions, 60-63 = dedicated for whales.
                                         -- Determines which Postgres partition AND ES index this tenant uses.
    estimated_weight BIGINT NOT NULL DEFAULT 0,  -- capacity estimate at signup (weight units)
    actual_weight    BIGINT NOT NULL DEFAULT 0,  -- updated nightly from real row counts
    settings        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------
-- TENANT MIGRATIONS  (live partition-to-partition moves)
-- -----------------------------------------------------------
CREATE TABLE tenant_migrations (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    source_partition  SMALLINT NOT NULL,
    target_partition  SMALLINT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','dual_writing','backfilling',
                                        'cutting_over','completed','rolled_back')),
    rows_backfilled   BIGINT DEFAULT 0,
    rows_total        BIGINT DEFAULT 0,
    started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at      TIMESTAMPTZ,
    PRIMARY KEY (id)
);

CREATE INDEX idx_tenant_migrations_active
    ON tenant_migrations (tenant_id)
    WHERE status NOT IN ('completed', 'rolled_back');

-- -----------------------------------------------------------
-- CONTACTS  (list-partitioned by partition_number, 64 partitions)
-- -----------------------------------------------------------
CREATE TABLE contacts (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    partition_number  SMALLINT NOT NULL,  -- assigned by Tenant Service, copied from tenants.partition_number
    external_id       TEXT,           -- caller-supplied ID for CRM migration / sync (e.g. Salesforce ID)
    email             TEXT,
    first_name        TEXT,
    last_name         TEXT,
    phone             TEXT,
    lifecycle_stage   TEXT NOT NULL DEFAULT 'subscriber'
                      CHECK (lifecycle_stage IN (
                        'subscriber','lead','mql','sql','customer','evangelist'
                      )),
    custom_fields     JSONB NOT NULL DEFAULT '{}',
    custom_score      NUMERIC(15,4),      -- tenant-defined composite score (ES sorts/ranges on this, not Postgres)
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived','deleted','merged')),
    merged_into_id    UUID,
    created_by        UUID,   -- user/agent within tenant (intentionally no FK to auth)
    updated_by        UUID,   -- user/agent within tenant (intentionally no FK to auth)
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at       TIMESTAMPTZ,
    deleted_at        TIMESTAMPTZ,
    CHECK (lifecycle_status != 'merged' OR merged_into_id IS NOT NULL),
    PRIMARY KEY (partition_number, tenant_id, id)
) PARTITION BY LIST (partition_number);

-- Generate 64 list partitions (0-59 shared, 60-63 dedicated for whales)
DO $$
BEGIN
  FOR i IN 0..63 LOOP
    EXECUTE format(
      'CREATE TABLE contacts_p%s PARTITION OF contacts FOR VALUES IN (%s)',
      lpad(i::text, 2, '0'), i
    );
  END LOOP;
END $$;

CREATE UNIQUE INDEX idx_contacts_external_id ON contacts (tenant_id, external_id) WHERE external_id IS NOT NULL;
CREATE INDEX idx_contacts_email       ON contacts (tenant_id, lower(email));
CREATE INDEX idx_contacts_status      ON contacts (tenant_id, lifecycle_status, updated_at);
CREATE INDEX idx_contacts_updated     ON contacts (tenant_id, updated_at);
CREATE INDEX idx_contacts_custom      ON contacts USING GIN (custom_fields jsonb_path_ops);
CREATE INDEX idx_contacts_dedup       ON contacts USING GIN (lower(email) gin_trgm_ops) WHERE lifecycle_status = 'active';

-- -----------------------------------------------------------
-- COMPANIES  (list-partitioned by partition_number, 64 partitions)
-- -----------------------------------------------------------
CREATE TABLE companies (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    partition_number  SMALLINT NOT NULL,
    external_id       TEXT,           -- caller-supplied ID for CRM migration / sync
    name              TEXT NOT NULL,
    domain            TEXT,
    industry          TEXT,
    employee_count    INT,
    annual_revenue    NUMERIC(15,2),
    custom_fields     JSONB NOT NULL DEFAULT '{}',
    custom_score      NUMERIC(15,4),      -- tenant-defined composite score
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived','deleted')),
    created_by        UUID,   -- user/agent within tenant (intentionally no FK to auth)
    updated_by        UUID,   -- user/agent within tenant (intentionally no FK to auth)
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at       TIMESTAMPTZ,
    deleted_at        TIMESTAMPTZ,
    PRIMARY KEY (partition_number, tenant_id, id)
) PARTITION BY LIST (partition_number);

DO $$
BEGIN
  FOR i IN 0..63 LOOP
    EXECUTE format(
      'CREATE TABLE companies_p%s PARTITION OF companies FOR VALUES IN (%s)',
      lpad(i::text, 2, '0'), i
    );
  END LOOP;
END $$;

CREATE UNIQUE INDEX idx_companies_external_id ON companies (tenant_id, external_id) WHERE external_id IS NOT NULL;
CREATE INDEX idx_companies_domain     ON companies (tenant_id, lower(domain));
CREATE INDEX idx_companies_custom     ON companies USING GIN (custom_fields jsonb_path_ops);
-- NOTE: idx_companies_name and idx_companies_status removed — ES handles
-- name search and status filtering. Postgres is PK-lookup + writes only.

-- -----------------------------------------------------------
-- PIPELINES
-- -----------------------------------------------------------
CREATE TABLE pipelines (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    name              TEXT NOT NULL,
    stages            JSONB NOT NULL,
    is_default        BOOLEAN NOT NULL DEFAULT false,
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
);

CREATE UNIQUE INDEX idx_pipelines_default
    ON pipelines (tenant_id) WHERE is_default = true AND lifecycle_status = 'active';

-- -----------------------------------------------------------
-- OPPORTUNITIES  (list-partitioned by partition_number, 64 partitions)
-- -----------------------------------------------------------
CREATE TABLE opportunities (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    partition_number  SMALLINT NOT NULL,
    external_id       TEXT,           -- caller-supplied ID for CRM migration / sync
    pipeline_id       UUID NOT NULL,
    stage_id          TEXT NOT NULL,
    name              TEXT NOT NULL,
    amount            NUMERIC(15,2),
    currency          TEXT NOT NULL DEFAULT 'USD',
    expected_close    DATE,
    probability       SMALLINT CHECK (probability BETWEEN 0 AND 100),
    owner_id          UUID,
    custom_fields     JSONB NOT NULL DEFAULT '{}',
    custom_score      NUMERIC(15,4),      -- tenant-defined composite score
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','won','lost','deleted')),
    won_at            TIMESTAMPTZ,
    lost_at           TIMESTAMPTZ,
    created_by        UUID,   -- user/agent within tenant (intentionally no FK to auth)
    updated_by        UUID,   -- user/agent within tenant (intentionally no FK to auth)
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    PRIMARY KEY (partition_number, tenant_id, id),
    FOREIGN KEY (tenant_id, pipeline_id) REFERENCES pipelines(tenant_id, id)
) PARTITION BY LIST (partition_number);

DO $$
BEGIN
  FOR i IN 0..63 LOOP
    EXECUTE format(
      'CREATE TABLE opportunities_p%s PARTITION OF opportunities FOR VALUES IN (%s)',
      lpad(i::text, 2, '0'), i
    );
  END LOOP;
END $$;

CREATE UNIQUE INDEX idx_opps_external_id ON opportunities (tenant_id, external_id) WHERE external_id IS NOT NULL;
CREATE INDEX idx_opps_pipeline       ON opportunities (tenant_id, pipeline_id, stage_id);
CREATE INDEX idx_opps_owner          ON opportunities (tenant_id, owner_id);
-- NOTE: idx_opps_close, idx_opps_status, idx_opps_amount removed — ES handles
-- all list/filter/sort queries. Postgres keeps pipeline index (write-path
-- validation) and owner index (degraded-mode fallback: "show my deals").

-- -----------------------------------------------------------
-- CUSTOM OBJECT TYPES
-- -----------------------------------------------------------
CREATE TABLE custom_object_types (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    slug              TEXT NOT NULL,
    display_name      TEXT NOT NULL,
    description       TEXT,
    field_schema      JSONB NOT NULL DEFAULT '[]',
    icon              TEXT,
    schema_version    INT NOT NULL DEFAULT 1,
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, slug)
);

-- -----------------------------------------------------------
-- CUSTOM OBJECT TYPE VERSIONS  (schema evolution history)
-- -----------------------------------------------------------
CREATE TABLE custom_object_type_versions (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    object_type_id  UUID NOT NULL,
    version         INT NOT NULL,
    field_schema    JSONB NOT NULL,
    migration_ops   JSONB,
    created_by      UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, object_type_id) REFERENCES custom_object_types(tenant_id, id),
    UNIQUE (tenant_id, object_type_id, version)
);

-- -----------------------------------------------------------
-- CUSTOM OBJECT RECORDS  (list-partitioned by partition_number, 64 partitions)
-- -----------------------------------------------------------
CREATE TABLE custom_object_records (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    partition_number  SMALLINT NOT NULL,
    object_type_id    UUID NOT NULL,
    display_name      TEXT,
    data              JSONB NOT NULL DEFAULT '{}',
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived','deleted')),
    created_by        UUID,   -- user/agent within tenant (intentionally no FK to auth)
    updated_by        UUID,   -- user/agent within tenant (intentionally no FK to auth)
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at       TIMESTAMPTZ,
    deleted_at        TIMESTAMPTZ,
    PRIMARY KEY (partition_number, tenant_id, id),
    FOREIGN KEY (tenant_id, object_type_id) REFERENCES custom_object_types(tenant_id, id)
) PARTITION BY LIST (partition_number);

DO $$
BEGIN
  FOR i IN 0..63 LOOP
    EXECUTE format(
      'CREATE TABLE custom_object_records_p%s PARTITION OF custom_object_records FOR VALUES IN (%s)',
      lpad(i::text, 2, '0'), i
    );
  END LOOP;
END $$;

CREATE INDEX idx_cor_type            ON custom_object_records (tenant_id, object_type_id);
CREATE INDEX idx_cor_status          ON custom_object_records (tenant_id, lifecycle_status);
CREATE INDEX idx_cor_data            ON custom_object_records USING GIN (data jsonb_path_ops);
CREATE INDEX idx_cor_updated         ON custom_object_records (tenant_id, updated_at);

-- -----------------------------------------------------------
-- ACTIVITIES  (polymorphic timeline, list-partitioned by partition_number)
-- -----------------------------------------------------------
-- Same polymorphic pattern as relationships: entity_type +
-- entity_id identify the parent record. No DB-level FK on the
-- polymorphic target — app validates, async scanner catches drift.
CREATE TABLE activities (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    partition_number SMALLINT NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    activity_type   TEXT NOT NULL
                    CHECK (activity_type IN ('email','call','meeting','note','task','custom')),
    subject         TEXT,
    body            TEXT,
    details         JSONB NOT NULL DEFAULT '{}',
    status          TEXT NOT NULL DEFAULT 'completed'
                    CHECK (status IN ('open','completed','canceled')),
    occurred_at     TIMESTAMPTZ NOT NULL,
    duration_secs   INT,
    owner_id        UUID,
    created_by      UUID,
    updated_by      UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (partition_number, tenant_id, id)
) PARTITION BY LIST (partition_number);

DO $$
BEGIN
  FOR i IN 0..63 LOOP
    EXECUTE format(
      'CREATE TABLE activities_p%s PARTITION OF activities FOR VALUES IN (%s)',
      lpad(i::text, 2, '0'), i
    );
  END LOOP;
END $$;

CREATE INDEX idx_activities_entity     ON activities (tenant_id, entity_type, entity_id, occurred_at DESC);
CREATE INDEX idx_activities_type       ON activities (tenant_id, activity_type, occurred_at DESC);
CREATE INDEX idx_activities_updated    ON activities (tenant_id, updated_at);
CREATE INDEX idx_activities_open_tasks ON activities (tenant_id, owner_id, status)
    WHERE activity_type = 'task' AND status = 'open';
CREATE INDEX idx_activities_details    ON activities USING GIN (details jsonb_path_ops);

-- -----------------------------------------------------------
-- RELATIONSHIPS  (polymorphic edges, list-partitioned by partition_number)
-- -----------------------------------------------------------
CREATE TABLE relationships (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    partition_number SMALLINT NOT NULL,
    source_type     TEXT NOT NULL,
    source_id       UUID NOT NULL,
    target_type     TEXT NOT NULL,
    target_id       UUID NOT NULL,
    relation_kind   TEXT NOT NULL,
    ordinal         INT NOT NULL DEFAULT 0,
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (partition_number, tenant_id, id)
) PARTITION BY LIST (partition_number);

DO $$
BEGIN
  FOR i IN 0..63 LOOP
    EXECUTE format(
      'CREATE TABLE relationships_p%s PARTITION OF relationships FOR VALUES IN (%s)',
      lpad(i::text, 2, '0'), i
    );
  END LOOP;
END $$;

CREATE INDEX idx_rel_source ON relationships (tenant_id, source_type, source_id);
CREATE INDEX idx_rel_target ON relationships (tenant_id, target_type, target_id);
CREATE UNIQUE INDEX idx_rel_unique_edge
    ON relationships (tenant_id, source_type, source_id, target_type, target_id, relation_kind);

-- -----------------------------------------------------------
-- MERGE SUGGESTIONS  (contact deduplication)
-- -----------------------------------------------------------
CREATE TABLE merge_suggestions (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    contact_id_a    UUID NOT NULL,
    contact_id_b    UUID NOT NULL,
    confidence      NUMERIC(3,2) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    match_signals   JSONB NOT NULL DEFAULT '{}',
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','accepted','dismissed')),
    resolved_by     UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at     TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, id)
);

CREATE UNIQUE INDEX idx_merge_suggestions_pair
    ON merge_suggestions (tenant_id, LEAST(contact_id_a, contact_id_b), GREATEST(contact_id_a, contact_id_b))
    WHERE status = 'pending';

-- -----------------------------------------------------------
-- CHANGE LOG  (append-only, range-partitioned by month)
-- -----------------------------------------------------------
CREATE TABLE change_log (
    id              BIGINT GENERATED ALWAYS AS IDENTITY,
    tenant_id       UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    action          TEXT NOT NULL
                    CHECK (action IN ('create','update','delete','merge','stage_change','archive','restore')),
    changed_fields  JSONB,
    actor_id        UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id, created_at)
) PARTITION BY RANGE (created_at);

-- Create partitions for the next 12 months (extend via cron / pg_partman)
DO $$
DECLARE
  start_date DATE := date_trunc('month', now());
  m INT;
BEGIN
  FOR m IN 0..11 LOOP
    EXECUTE format(
      'CREATE TABLE change_log_%s PARTITION OF change_log FOR VALUES FROM (%L) TO (%L)',
      to_char(start_date + (m || ' months')::interval, 'YYYY_MM'),
      start_date + (m || ' months')::interval,
      start_date + ((m + 1) || ' months')::interval
    );
  END LOOP;
END $$;

CREATE INDEX idx_changelog_entity ON change_log (tenant_id, entity_type, entity_id, created_at);
CREATE INDEX idx_changelog_time   ON change_log (tenant_id, created_at);

-- -----------------------------------------------------------
-- SCORING RULES  (one per tenant per entity type)
-- -----------------------------------------------------------
-- Defines how custom_score is computed for each entity type.
-- Application computes the score on every write using cached rules.
-- Background job recomputes all scores when a rule changes.
CREATE TABLE scoring_rules (
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    entity_type     TEXT NOT NULL,            -- 'contact', 'company', 'opportunity'
    label           TEXT NOT NULL,            -- display name: "Lead Score", "Deal Priority"
    formula_type    TEXT NOT NULL DEFAULT 'weighted_sum'
                    CHECK (formula_type IN ('weighted_sum','max_of','conditional')),
    formula_config  JSONB NOT NULL,           -- formula definition (see examples below)
    default_value   NUMERIC(15,4) NOT NULL DEFAULT 0,
    is_enabled      BOOLEAN NOT NULL DEFAULT true,
    updated_by      UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, entity_type)      -- exactly one rule per entity type per tenant
);

-- -----------------------------------------------------------
-- AUTOMATION RULES
-- -----------------------------------------------------------
CREATE TABLE automation_rules (
    id                  UUID NOT NULL DEFAULT uuidv7(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    name                TEXT NOT NULL,
    description         TEXT,
    trigger_source      TEXT NOT NULL
                        CHECK (trigger_source IN ('field_change','activity')),
    trigger_event       TEXT NOT NULL
                        CHECK (trigger_event IN ('create','update','delete')),
    entity_type         TEXT NOT NULL,           -- 'contact','company','opportunity','custom:policy', etc.
    trigger_conditions  JSONB NOT NULL,          -- e.g. {"field":"lifecycle_stage","op":"eq","value":"sql"}
    action              TEXT NOT NULL,           -- 'update_field','create_activity','send_email','call_webhook'
    action_params       JSONB NOT NULL,          -- action-specific config
    is_enabled          BOOLEAN NOT NULL DEFAULT true,
    execution_order     INT NOT NULL DEFAULT 0,  -- lower = earlier; resolves conflicts between rules
    created_by          UUID,
    updated_by          UUID,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
);

CREATE INDEX idx_automation_rules_lookup
    ON automation_rules (tenant_id, entity_type, trigger_source, is_enabled);

-- -----------------------------------------------------------
-- AUTOMATION EXECUTION LOG  (idempotency + audit)
-- -----------------------------------------------------------
-- Every time a rule fires, we write an execution record BEFORE
-- enqueuing the action. The execution_key is a deterministic hash
-- of (tenant_id, rule_id, entity_id, cdc_event_id). On CDC retry,
-- the evaluator checks this table — if the execution_key exists,
-- the action is skipped. This prevents duplicate emails, tasks, etc.
CREATE TABLE automation_execution_log (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL,
    rule_id         UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    cdc_event_id    TEXT NOT NULL,               -- Kafka offset or Debezium LSN
    execution_key   TEXT NOT NULL,               -- hash(tenant_id + rule_id + entity_id + cdc_event_id)
    action          TEXT NOT NULL,
    action_params   JSONB NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','succeeded','failed','skipped')),
    error_message   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, id, created_at)
) PARTITION BY RANGE (created_at);

-- Monthly partitions, same pattern as change_log
-- Old partitions can be archived after 90 days (execution log is operational, not compliance)
DO $$
DECLARE
  start_date DATE := date_trunc('month', now());
  m INT;
BEGIN
  FOR m IN 0..11 LOOP
    EXECUTE format(
      'CREATE TABLE automation_execution_log_%s PARTITION OF automation_execution_log FOR VALUES FROM (%L) TO (%L)',
      to_char(start_date + (m || ' months')::interval, 'YYYY_MM'),
      start_date + (m || ' months')::interval,
      start_date + ((m + 1) || ' months')::interval
    );
  END LOOP;
END $$;

-- Idempotency check: "has this exact rule+entity+event already been executed?"
CREATE UNIQUE INDEX idx_automation_exec_key
    ON automation_execution_log (tenant_id, execution_key);
-- Debugging: "show all executions for this entity"
CREATE INDEX idx_automation_exec_entity
    ON automation_execution_log (tenant_id, entity_type, entity_id, created_at DESC);
-- Monitoring: "find failed executions for retry"
CREATE INDEX idx_automation_exec_failed
    ON automation_execution_log (tenant_id, status, created_at)
    WHERE status = 'failed';

-- -----------------------------------------------------------
-- WEBHOOK SUBSCRIPTIONS
-- -----------------------------------------------------------
CREATE TABLE webhook_subscriptions (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    url             TEXT NOT NULL,                -- endpoint URL (HTTPS required)
    events          TEXT[] NOT NULL,              -- e.g. {'contact.created','contact.updated','opportunity.won'}
    webhook_version TEXT NOT NULL DEFAULT '2026-04-01',
    secret          TEXT NOT NULL,                -- HMAC-SHA256 signing secret (encrypted at rest)
    is_enabled      BOOLEAN NOT NULL DEFAULT true,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','degraded','suspended')),
    -- Circuit breaker state
    failure_count   INT NOT NULL DEFAULT 0,
    circuit_state   TEXT NOT NULL DEFAULT 'closed'
                    CHECK (circuit_state IN ('closed','open','half_open')),
    circuit_opened_at TIMESTAMPTZ,
    -- Rate limiting
    max_rate_per_sec INT NOT NULL DEFAULT 100,
    created_by      UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
);

CREATE INDEX idx_webhook_subs_events
    ON webhook_subscriptions USING GIN (events)
    WHERE is_enabled = true AND status != 'suspended';

-- -----------------------------------------------------------
-- WEBHOOK DELIVERY LOG  (append-only, range-partitioned)
-- -----------------------------------------------------------
CREATE TABLE webhook_delivery_log (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL,
    subscription_id   UUID NOT NULL,
    event_id          TEXT NOT NULL,              -- unique event ID included in payload
    event_type        TEXT NOT NULL,              -- e.g. 'contact.updated'
    payload_hash      TEXT NOT NULL,              -- SHA-256 of payload (no PII in log)
    http_status       INT,                        -- response status code (null if timeout)
    attempt           INT NOT NULL DEFAULT 1,     -- retry attempt number (1-5)
    status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','delivered','failed','dead_lettered')),
    error_message     TEXT,
    latency_ms        INT,                        -- round-trip time
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id, created_at)
) PARTITION BY RANGE (created_at);

DO $$
DECLARE
  start_date DATE := date_trunc('month', now());
  m INT;
BEGIN
  FOR m IN 0..11 LOOP
    EXECUTE format(
      'CREATE TABLE webhook_delivery_log_%s PARTITION OF webhook_delivery_log FOR VALUES FROM (%L) TO (%L)',
      to_char(start_date + (m || ' months')::interval, 'YYYY_MM'),
      start_date + (m || ' months')::interval,
      start_date + ((m + 1) || ' months')::interval
    );
  END LOOP;
END $$;

-- "Show delivery history for this subscription"
CREATE INDEX idx_webhook_delivery_sub
    ON webhook_delivery_log (tenant_id, subscription_id, created_at DESC);
-- "Find failed deliveries for retry"
CREATE INDEX idx_webhook_delivery_failed
    ON webhook_delivery_log (tenant_id, status, created_at)
    WHERE status = 'failed';
-- Idempotency: prevent duplicate deliveries of the same event
CREATE UNIQUE INDEX idx_webhook_delivery_event
    ON webhook_delivery_log (tenant_id, subscription_id, event_id, attempt);

-- -----------------------------------------------------------
-- TRIGGER: auto-set updated_at on every UPDATE
-- -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_contacts_updated_at        BEFORE UPDATE ON contacts              FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_companies_updated_at       BEFORE UPDATE ON companies             FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_pipelines_updated_at       BEFORE UPDATE ON pipelines             FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_opportunities_updated_at   BEFORE UPDATE ON opportunities         FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_cot_updated_at             BEFORE UPDATE ON custom_object_types   FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_cor_updated_at             BEFORE UPDATE ON custom_object_records FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_activities_updated_at      BEFORE UPDATE ON activities            FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_relationships_updated_at   BEFORE UPDATE ON relationships         FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_scoring_rules_updated_at   BEFORE UPDATE ON scoring_rules        FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_automation_rules_updated_at BEFORE UPDATE ON automation_rules     FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_webhook_subs_updated_at    BEFORE UPDATE ON webhook_subscriptions FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------
-- ROW-LEVEL SECURITY
-- -----------------------------------------------------------
ALTER TABLE contacts                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE companies                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE pipelines                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE opportunities             ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_object_types       ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_object_type_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_object_records     ENABLE ROW LEVEL SECURITY;
ALTER TABLE relationships             ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities                ENABLE ROW LEVEL SECURITY;
ALTER TABLE scoring_rules             ENABLE ROW LEVEL SECURITY;
ALTER TABLE automation_rules          ENABLE ROW LEVEL SECURITY;
ALTER TABLE automation_execution_log  ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_subscriptions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_delivery_log      ENABLE ROW LEVEL SECURITY;
ALTER TABLE merge_suggestions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE change_log                ENABLE ROW LEVEL SECURITY;

-- Tenant isolation policies (one per table)
CREATE POLICY tenant_iso_contacts   ON contacts              USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_companies  ON companies             USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_pipelines  ON pipelines             USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_opps       ON opportunities         USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_cot        ON custom_object_types   USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_cotv       ON custom_object_type_versions USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_cor        ON custom_object_records USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_rels       ON relationships         USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_activities ON activities             USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_scoring    ON scoring_rules         USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_auto_rules ON automation_rules      USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_auto_exec  ON automation_execution_log USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_wh_subs    ON webhook_subscriptions USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_wh_delivery ON webhook_delivery_log USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_merge      ON merge_suggestions     USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);
CREATE POLICY tenant_iso_changelog  ON change_log            USING (tenant_id = current_setting('app.current_tenant')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);

-- -----------------------------------------------------------
-- HELPER: set tenant context (call at connection start)
-- -----------------------------------------------------------
-- Usage: SELECT set_config('app.current_tenant', 'your-tenant-uuid', false);

COMMIT;
