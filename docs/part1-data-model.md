# Part 1 – Canonical CRM Data Model & Multi-Tenant Schema

## 1. Logical Data Model

### Entity Overview

The platform models six core entity families. Every entity carries a `tenant_id` as the top-level partition key — no row exists without one.

**Tenant** – The isolation boundary. Represents an account, agency, or workspace. All downstream entities are scoped to exactly one tenant.

**Contact** – A person known to the tenant. Carries standard CRM fields (email, phone, name) plus arbitrary custom fields. Contacts participate in relationships with Companies, Opportunities, and Custom Object Records.

**Company** – An organization. Has a name, domain, industry, and size. Contacts are linked to Companies via a many-to-many relationship (a person may consult for multiple companies; a company has many contacts).

**Pipeline** – A sales process template belonging to a tenant. Contains an ordered set of stages (e.g., "Qualified → Proposal → Negotiation → Won → Lost"). Pipelines are structural metadata, not transactional records.

**Opportunity (Deal)** – A revenue event moving through a Pipeline. Linked to exactly one Pipeline and one or more Contacts/Companies. Carries an amount, currency, expected close date, and a current stage reference.

**CustomObjectType** – A tenant-defined entity schema (e.g., "Policy", "Vehicle", "Subscription"). Describes the shape of records: field names, types, required flags, and display metadata. This is the "class" to CustomObjectRecord's "instance".

**CustomObjectRecord** – An instance of a CustomObjectType. Stores its data in a JSONB column keyed by the field definitions in its type. Participates in the same relationship system as core objects.

**Activity** – A polymorphic timeline entry representing an interaction or event attached to any CRM entity (core or custom). Uses the same type-discriminated pattern as Relationship: `entity_type` + `entity_id` identify the parent record, and `activity_type` discriminates the kind of activity (email, call, meeting, note, task, custom). Type-specific payload lives in a JSONB `details` column. Activities are the primary driver for timeline views in the UI and a first-class trigger source for automations — "when an email is logged on a contact" or "when a meeting is completed for an opportunity" fire rules the same way field changes do.

**Relationship** – A polymorphic edge connecting any two entity records (core or custom). Typed (e.g., "primary_contact", "associated_company") and always scoped to a single tenant.

**ScoringRule** – Defines how `custom_score` is computed for each entity type per tenant. Each tenant has at most one scoring rule per entity type (contact, company, opportunity). Supports weighted-sum, max-of, and conditional formula types. The Core CRM Service computes the score on every write using the rule cached from the Tenant Service; a background job recomputes all scores when the rule changes.

**AutomationRule** – A tenant-defined trigger-action pair. Specifies what event to watch (`trigger_source`: field change or activity; `trigger_event`: create, update, or delete), what conditions to match (`trigger_conditions` JSONB), and what action to execute (`action` + `action_params`). Rules are versioned by `updated_at` and cached in-memory by the trigger evaluator (30s TTL).

**WebhookSubscription** – A tenant-registered HTTP endpoint that receives event notifications. Carries a signing secret (HMAC-SHA256), subscribed event types, version, and circuit breaker state. The delivery service consults this table to determine where and how to deliver each event.

---

### Key Fields Per Entity

```
Tenant
  id              UUID, PK (v7)
  name            TEXT NOT NULL
  slug            TEXT UNIQUE NOT NULL
  partition_number SMALLINT NOT NULL                 -- assigned by Tenant Service at onboarding based on capacity estimate.
                                                     -- 0-59 = shared partitions, 60-63 = dedicated for whale tenants.
                                                     -- Determines which Postgres LIST partition AND ES index this tenant uses.
  estimated_weight BIGINT DEFAULT 0                  -- capacity estimate at signup (weight units)
  actual_weight    BIGINT DEFAULT 0                  -- updated nightly from real row counts
  plan_tier       TEXT DEFAULT 'standard'        -- standard | professional | enterprise
  settings        JSONB DEFAULT '{}'
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ

Contact
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL     (partition key)
  external_id     TEXT, UNIQUE(tenant_id, external_id)  -- caller-supplied ID for migration/sync (e.g. Salesforce ID)
  email           TEXT
  first_name      TEXT
  last_name       TEXT
  phone           TEXT
  lifecycle_stage TEXT DEFAULT 'subscriber'        -- subscriber | lead | mql | sql | customer | evangelist
  custom_fields   JSONB DEFAULT '{}'
  custom_score    NUMERIC(15,4)                     -- tenant-defined composite score (computed by app from scoring_rules)
  lifecycle_status TEXT DEFAULT 'active'            -- active | archived | deleted | merged
  merged_into_id  UUID, FK → Contact, NULLABLE
  created_by      UUID                              -- user/agent within the tenant (no FK to auth)
  updated_by      UUID
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ
  archived_at     TIMESTAMPTZ
  deleted_at      TIMESTAMPTZ

Company
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL
  external_id     TEXT, UNIQUE(tenant_id, external_id)  -- caller-supplied ID for migration/sync
  name            TEXT NOT NULL
  domain          TEXT
  industry        TEXT
  employee_count  INT
  annual_revenue  NUMERIC(15,2)
  custom_fields   JSONB DEFAULT '{}'
  custom_score    NUMERIC(15,4)                     -- tenant-defined composite score
  lifecycle_status TEXT DEFAULT 'active'
  created_by      UUID                              -- user/agent within the tenant (no FK to auth)
  updated_by      UUID
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ
  archived_at     TIMESTAMPTZ
  deleted_at      TIMESTAMPTZ

Pipeline
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL
  name            TEXT NOT NULL
  stages          JSONB NOT NULL                   -- ordered array of {id, name, position, type}
  is_default      BOOLEAN DEFAULT false
  lifecycle_status TEXT DEFAULT 'active'
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ

Opportunity
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL
  external_id     TEXT, UNIQUE(tenant_id, external_id)  -- caller-supplied ID for migration/sync
  pipeline_id     UUID, FK → Pipeline, NOT NULL
  stage_id        TEXT NOT NULL                    -- references a stage.id within pipeline.stages
  name            TEXT NOT NULL
  amount          NUMERIC(15,2)
  currency        TEXT DEFAULT 'USD'
  expected_close  DATE
  probability     SMALLINT                         -- 0–100
  owner_id        UUID                             -- reference to a user/agent within the tenant
  custom_fields   JSONB DEFAULT '{}'
  custom_score    NUMERIC(15,4)                     -- tenant-defined composite score
  lifecycle_status TEXT DEFAULT 'active'            -- active | won | lost | deleted
  won_at          TIMESTAMPTZ
  lost_at         TIMESTAMPTZ
  created_by      UUID                              -- user/agent within the tenant (no FK to auth)
  updated_by      UUID
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ
  deleted_at      TIMESTAMPTZ

CustomObjectType
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL
  slug            TEXT NOT NULL                    -- e.g., 'policy', 'vehicle'
  display_name    TEXT NOT NULL
  description     TEXT
  field_schema    JSONB NOT NULL                   -- array of field definitions
  icon            TEXT
  schema_version  INT DEFAULT 1                    -- incremented on field_schema changes
  lifecycle_status TEXT DEFAULT 'active'
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ
  UNIQUE(tenant_id, slug)

CustomObjectRecord
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL
  object_type_id  UUID, FK → CustomObjectType, NOT NULL
  display_name    TEXT                             -- computed or user-set label
  data            JSONB NOT NULL DEFAULT '{}'
  lifecycle_status TEXT DEFAULT 'active'
  created_by      UUID                              -- user/agent within the tenant (no FK to auth)
  updated_by      UUID
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ
  archived_at     TIMESTAMPTZ
  deleted_at      TIMESTAMPTZ

Relationship
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL
  source_type     TEXT NOT NULL                    -- 'contact', 'company', 'opportunity', 'custom:{slug}'
  source_id       UUID NOT NULL
  target_type     TEXT NOT NULL
  target_id       UUID NOT NULL
  relation_kind   TEXT NOT NULL                    -- 'primary_contact', 'associated', 'parent', etc.
  ordinal         INT DEFAULT 0                    -- for ordering within a relation kind
  metadata        JSONB DEFAULT '{}'
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ

Activity
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL     (partition key)
  entity_type     TEXT NOT NULL                    -- 'contact', 'company', 'opportunity', 'custom:{slug}'
  entity_id       UUID NOT NULL                   -- polymorphic FK to any entity (same pattern as Relationship)
  activity_type   TEXT NOT NULL                    -- 'email', 'call', 'meeting', 'note', 'task', 'custom'
  subject         TEXT                             -- short summary ("Follow-up call with Jane")
  body            TEXT                             -- rich text / markdown body (notes, email body)
  details         JSONB DEFAULT '{}'               -- type-specific payload (see detail schema below)
  status          TEXT DEFAULT 'completed'         -- open | completed | canceled  (relevant for task/meeting)
  occurred_at     TIMESTAMPTZ NOT NULL             -- when the activity happened (user-supplied, not created_at)
  duration_secs   INT                              -- call/meeting duration in seconds
  owner_id        UUID                             -- user/agent who performed the activity
  created_by      UUID
  updated_by      UUID
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ

AutomationRule
  id                  UUID, PK (v7)
  tenant_id           UUID, FK → Tenant, NOT NULL
  name                TEXT NOT NULL
  description         TEXT
  trigger_source      TEXT NOT NULL                -- 'field_change' | 'activity'
  trigger_event       TEXT NOT NULL                -- 'create' | 'update' | 'delete'
  entity_type         TEXT NOT NULL                -- which object type this rule watches
  trigger_conditions  JSONB NOT NULL               -- matching criteria (field values, activity type, details)
  action              TEXT NOT NULL                -- 'update_field' | 'create_activity' | 'send_email' | 'call_webhook'
  action_params       JSONB NOT NULL               -- action-specific configuration
  is_enabled          BOOLEAN DEFAULT true
  execution_order     INT DEFAULT 0                -- lower = earlier; resolves rule priority
  created_by          UUID
  updated_by          UUID
  created_at          TIMESTAMPTZ
  updated_at          TIMESTAMPTZ

WebhookSubscription
  id              UUID, PK (v7)
  tenant_id       UUID, FK → Tenant, NOT NULL
  url             TEXT NOT NULL                    -- HTTPS endpoint URL
  events          TEXT[] NOT NULL                  -- subscribed event types ['contact.created', ...]
  webhook_version TEXT DEFAULT '2026-04-01'
  secret          TEXT NOT NULL                    -- HMAC-SHA256 signing secret (encrypted at rest)
  is_enabled      BOOLEAN DEFAULT true
  status          TEXT DEFAULT 'active'            -- active | degraded | suspended
  circuit_state   TEXT DEFAULT 'closed'            -- closed | open | half_open
  circuit_opened_at TIMESTAMPTZ
  max_rate_per_sec INT DEFAULT 100
  created_by      UUID
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ

ScoringRule
  tenant_id       UUID, FK → Tenant, NOT NULL      -- composite PK with entity_type
  entity_type     TEXT NOT NULL                     -- 'contact', 'company', 'opportunity'
  label           TEXT NOT NULL                     -- display name: "Lead Score", "Deal Priority"
  formula_type    TEXT DEFAULT 'weighted_sum'       -- weighted_sum | max_of | conditional
  formula_config  JSONB NOT NULL                    -- formula definition (weights, conditions, etc.)
  default_value   NUMERIC(15,4) DEFAULT 0
  is_enabled      BOOLEAN DEFAULT true
  updated_by      UUID
  created_at      TIMESTAMPTZ
  updated_at      TIMESTAMPTZ
  PRIMARY KEY (tenant_id, entity_type)             -- exactly one rule per entity type per tenant
```

### Field Schema Format (CustomObjectType.field_schema)

```json
[
  {
    "key": "policy_number",
    "label": "Policy Number",
    "type": "text",
    "required": true,
    "unique_per_tenant": true,
    "indexed": true
  },
  {
    "key": "premium",
    "label": "Annual Premium",
    "type": "currency",
    "required": false,
    "default_value": null
  },
  {
    "key": "renewal_date",
    "label": "Renewal Date",
    "type": "date",
    "required": false
  },
  {
    "key": "coverage_type",
    "label": "Coverage Type",
    "type": "enum",
    "options": ["auto", "home", "life", "health"],
    "required": true
  }
]
```

Supported field types: `text`, `number`, `currency`, `date`, `datetime`, `boolean`, `enum`, `multi_enum`, `url`, `email`, `phone`, `reference` (FK to another object type).

### Activity Detail Schema (Activity.details)

The `details` JSONB column carries type-specific metadata. The schema is discriminated by `activity_type`:

```json
// activity_type: "email"
{
  "from": "rep@acme.com",
  "to": ["jane@client.com"],
  "cc": [],
  "thread_id": "msg_abc123",
  "direction": "outbound",       // inbound | outbound
  "tracking": { "opened": true, "opened_at": "2026-04-10T15:00:00Z", "clicked": false }
}

// activity_type: "call"
{
  "direction": "outbound",
  "disposition": "connected",    // connected | voicemail | no_answer | busy
  "recording_url": "https://...",
  "phone_number": "+1-555-0100"
}

// activity_type: "meeting"
{
  "location": "Zoom",
  "meeting_url": "https://zoom.us/j/...",
  "attendees": ["cont_jane456", "cont_bob789"],
  "outcome": "next_steps_agreed"  // freeform or enum per tenant config
}

// activity_type: "note"
{}  // body field carries the note content; details is empty or has tags

// activity_type: "task"
{
  "due_date": "2026-04-15",
  "priority": "high",            // low | medium | high
  "task_type": "follow_up"       // follow_up | to_do | reminder
}
```

Validation of `details` is application-enforced using a per-`activity_type` JSON Schema — the same pattern as custom object field validation but with a fixed set of schemas (one per activity type).

---

## 2. Physical Schema (Relational – PostgreSQL)

### Multi-Tenant Isolation Strategy

I use **shared-schema, shared-table** multi-tenancy with `tenant_id` as the leading column in every composite primary key and every index. This is reinforced by three mechanisms:

1. **Postgres Row-Level Security (RLS)** – a database-level feature where Postgres itself automatically filters every query to only return rows belonging to the current tenant. Every table has an RLS policy that filters on `tenant_id = current_setting('app.current_tenant')::uuid`. The Core CRM Service sets this variable (called a GUC — Grand Unified Configuration setting) at the start of every transaction. Even if service code has a bug and forgets a `WHERE tenant_id = ...` clause, RLS ensures no cross-tenant data is returned.

2. **Composite indexes led by `tenant_id`** – Every query plan naturally prunes to a single tenant's data first.

3. **Declarative LIST partitioning (for high-volume tables)** – `contacts`, `companies`, `opportunities`, `custom_object_records`, `activities`, and `relationships` are list-partitioned by `partition_number` (64 partitions). Each row carries a `partition_number SMALLINT` column copied from the tenant's assignment. The Tenant Service assigns partition numbers at onboarding based on capacity estimates — partitions 0-59 are shared (multiple tenants), partitions 60-63 are dedicated (one whale tenant per partition). This gives full control over which tenants share infrastructure, enables live tenant migration between partitions, and keeps vacuum/index builds scoped and parallelizable. Each Postgres partition has a 1:1 mirror ES index (`crm_contacts_pNN`).

### DDL

#### UUID v7 for Primary Keys

All primary keys use UUID v7 instead of the more common UUID v4 (`gen_random_uuid()`). UUID v4 generates completely random IDs — they look like `a3f2b1c4-d5e6-4a7b-8c9d-0e1f2a3b4c5d` with no order or pattern. UUID v7 is different: it embeds the current time (millisecond precision) in the first part of the ID, so newer IDs are always "greater than" older ones. This gives us three concrete advantages at scale:

1. **Time-ordered** — UUIDs sort chronologically. This makes `ORDER BY id` equivalent to `ORDER BY created_at` for most practical purposes, and range scans on the PK index become time-range scans for free.
2. **Better B-tree locality** — New inserts always land at the right edge of the index, reducing random I/O. With UUID v4, every insert touches a random leaf page, causing heavy page splits and buffer churn once the index exceeds shared_buffers.
3. **Reduced page splits at billion-row scale** — Because inserts are append-only in the index, B-tree pages fill sequentially and split far less often. This matters when a single tenant's `custom_object_records` table holds hundreds of millions of rows.

The helper function:

```sql
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
```

**A note on `created_by` / `updated_by`:** These columns appear on contacts, companies, opportunities, and custom_object_records. They reference users or automation agents within the tenant, but we intentionally do not enforce a foreign key to a users table. The auth/user system is a separate bounded context (often a third-party identity provider), and coupling the core CRM schema to it via FKs would create deployment-order dependencies and cross-service migration headaches. The Core CRM Service validates these IDs at write time; the DB treats them as opaque UUIDs.

```sql
-- ===========================================================
-- TENANTS
-- ===========================================================
CREATE TABLE tenants (
    id              UUID PRIMARY KEY DEFAULT uuidv7(),
    name            TEXT NOT NULL,
    slug            TEXT NOT NULL UNIQUE,
    plan_tier       TEXT NOT NULL DEFAULT 'standard'
                    CHECK (plan_tier IN ('standard','professional','enterprise')),
    settings        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===========================================================
-- CONTACTS  (list-partitioned by partition_number, assigned by Tenant Service)
-- ===========================================================
CREATE TABLE contacts (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    partition_number  SMALLINT NOT NULL,  -- assigned by Tenant Service, LIST partition key
    email             TEXT,
    first_name        TEXT,
    last_name         TEXT,
    phone             TEXT,
    lifecycle_stage   TEXT NOT NULL DEFAULT 'subscriber'
                      CHECK (lifecycle_stage IN (
                        'subscriber','lead','mql','sql','customer','evangelist'
                      )),
    custom_fields     JSONB NOT NULL DEFAULT '{}',
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived','deleted','merged')),
    merged_into_id    UUID,
    created_by        UUID,              -- user/agent who created this record (no FK — decoupled from auth schema)
    updated_by        UUID,              -- user/agent who last modified this record
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at       TIMESTAMPTZ,
    deleted_at        TIMESTAMPTZ,

    -- Merge invariant: merged records must point to a survivor
    CHECK (lifecycle_status != 'merged' OR merged_into_id IS NOT NULL),

    PRIMARY KEY (tenant_id, id)
) PARTITION BY LIST (partition_number);

-- Generate 64 hash partitions (via migration script):
-- CREATE TABLE contacts_p00 PARTITION OF contacts FOR VALUES IN (0);
-- CREATE TABLE contacts_p01 PARTITION OF contacts FOR VALUES IN (1);
-- ... through contacts_p63

CREATE INDEX idx_contacts_email       ON contacts (tenant_id, lower(email));
CREATE INDEX idx_contacts_status      ON contacts (tenant_id, lifecycle_status, updated_at);
CREATE INDEX idx_contacts_updated     ON contacts (tenant_id, updated_at);
CREATE INDEX idx_contacts_custom      ON contacts USING GIN (custom_fields jsonb_path_ops);

-- ===========================================================
-- COMPANIES
-- ===========================================================
CREATE TABLE companies (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    partition_number  SMALLINT NOT NULL,
    name              TEXT NOT NULL,
    domain            TEXT,
    industry          TEXT,
    employee_count    INT,
    annual_revenue    NUMERIC(15,2),
    custom_fields     JSONB NOT NULL DEFAULT '{}',
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived','deleted')),
    created_by        UUID,              -- user/agent who created this record (no FK — decoupled from auth schema)
    updated_by        UUID,              -- user/agent who last modified this record
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at       TIMESTAMPTZ,
    deleted_at        TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, id)
) PARTITION BY LIST (partition_number);

CREATE INDEX idx_companies_domain     ON companies (tenant_id, lower(domain));
CREATE INDEX idx_companies_custom     ON companies USING GIN (custom_fields jsonb_path_ops);
-- NOTE: No idx_companies_name or idx_companies_status — ES handles name search
-- and status filtering via per-partition indexes. Postgres serves PK lookups + writes.

-- ===========================================================
-- PIPELINES
-- ===========================================================
CREATE TABLE pipelines (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    name              TEXT NOT NULL,
    stages            JSONB NOT NULL,       -- [{id, name, position, type: "open"|"won"|"lost"}]
    is_default        BOOLEAN NOT NULL DEFAULT false,
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
);

-- At most one default pipeline per tenant
CREATE UNIQUE INDEX idx_pipelines_default
    ON pipelines (tenant_id) WHERE is_default = true AND lifecycle_status = 'active';

-- -----------------------------------------------------------
-- Design Note: Stages as JSONB vs Separate Table
-- -----------------------------------------------------------
-- We store pipeline stages as a JSONB array inside the pipelines table
-- rather than in a dedicated `pipeline_stages` table. This is a deliberate
-- trade-off:
--
-- UPSIDE:
--   - Atomic pipeline reads: one SELECT returns the pipeline and all its
--     stages. No N+1 queries, no joins.
--   - Stage ordering is trivial — it's just the array index. No "position"
--     column to maintain with gapped sequences and rebalancing logic.
--   - Pipeline creation/update is a single row write.
--
-- DOWNSIDE:
--   - There is no FK from opportunity.stage_id to a stages table. Stage ID
--     validation is application-enforced: the write path loads the pipeline's
--     stages array and checks that the target stage_id exists before accepting
--     an opportunity write.
--   - Stage renames require care. If stage_id is mutable, renaming a stage
--     means scanning all opportunities referencing that stage_id. Our
--     recommendation: treat stage_id as an immutable internal identifier
--     (e.g., a short UUID or slug set at creation time). The stage "name" is
--     display-only and can change freely without touching any opportunity rows.
--
-- This is why the composite FK (tenant_id, pipeline_id) exists on the
-- opportunities table to guarantee tenant-pipeline consistency at the DB
-- level, while stage_id validation lives in the Core CRM Service where it can
-- check against the JSONB array without contorting Postgres constraints.

-- ===========================================================
-- OPPORTUNITIES
-- ===========================================================
CREATE TABLE opportunities (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    partition_number  SMALLINT NOT NULL,
    pipeline_id       UUID NOT NULL,
    stage_id          TEXT NOT NULL,
    name              TEXT NOT NULL,
    amount            NUMERIC(15,2),
    currency          TEXT NOT NULL DEFAULT 'USD',
    expected_close    DATE,
    probability       SMALLINT CHECK (probability BETWEEN 0 AND 100),
    owner_id          UUID,
    custom_fields     JSONB NOT NULL DEFAULT '{}',
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','won','lost','deleted')),
    won_at            TIMESTAMPTZ,
    lost_at           TIMESTAMPTZ,
    created_by        UUID,              -- user/agent who created this record (no FK — decoupled from auth schema)
    updated_by        UUID,              -- user/agent who last modified this record
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, pipeline_id) REFERENCES pipelines(tenant_id, id)
) PARTITION BY LIST (partition_number);

CREATE INDEX idx_opps_pipeline       ON opportunities (tenant_id, pipeline_id, stage_id);
CREATE INDEX idx_opps_owner          ON opportunities (tenant_id, owner_id);
-- NOTE: idx_opps_close, idx_opps_status, idx_opps_amount removed — ES handles all
-- list/filter/sort queries via per-partition indexes. Postgres keeps pipeline index
-- (write-path validation) and owner index (degraded-mode fallback: "show my deals").

-- ===========================================================
-- CUSTOM OBJECT TYPES  (schema definitions)
-- ===========================================================
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

-- ===========================================================
-- CUSTOM OBJECT TYPE VERSIONS  (schema change history)
-- ===========================================================
CREATE TABLE custom_object_type_versions (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    object_type_id  UUID NOT NULL,
    version         INT NOT NULL,
    field_schema    JSONB NOT NULL,
    migration_ops   JSONB,              -- [{op: "add_field", key: "color", ...}, {op: "rename_field", ...}]
    created_by      UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, object_type_id) REFERENCES custom_object_types(tenant_id, id),
    UNIQUE (tenant_id, object_type_id, version)
);

-- ===========================================================
-- CUSTOM OBJECT RECORDS  (instances of custom types)
-- ===========================================================
CREATE TABLE custom_object_records (
    id                UUID NOT NULL DEFAULT uuidv7(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id),
    partition_number  SMALLINT NOT NULL,
    object_type_id    UUID NOT NULL,
    display_name      TEXT,
    data              JSONB NOT NULL DEFAULT '{}',
    lifecycle_status  TEXT NOT NULL DEFAULT 'active'
                      CHECK (lifecycle_status IN ('active','archived','deleted')),
    created_by        UUID,              -- user/agent who created this record (no FK — decoupled from auth schema)
    updated_by        UUID,              -- user/agent who last modified this record
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at       TIMESTAMPTZ,
    deleted_at        TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, object_type_id) REFERENCES custom_object_types(tenant_id, id)
) PARTITION BY LIST (partition_number);

CREATE INDEX idx_cor_type            ON custom_object_records (tenant_id, object_type_id);
CREATE INDEX idx_cor_status          ON custom_object_records (tenant_id, lifecycle_status);
CREATE INDEX idx_cor_data            ON custom_object_records USING GIN (data jsonb_path_ops);
CREATE INDEX idx_cor_updated         ON custom_object_records (tenant_id, updated_at);

-- ===========================================================
-- RELATIONSHIPS  (polymorphic edges between any two entities)
-- ===========================================================
CREATE TABLE relationships (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    partition_number SMALLINT NOT NULL,
    source_type     TEXT NOT NULL,     -- 'contact','company','opportunity','custom:policy'
    source_id       UUID NOT NULL,
    target_type     TEXT NOT NULL,
    target_id       UUID NOT NULL,
    relation_kind   TEXT NOT NULL,     -- 'primary_contact','associated','parent','child'
    ordinal         INT NOT NULL DEFAULT 0,
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
) PARTITION BY LIST (partition_number);

-- Find all relationships FROM a given entity
CREATE INDEX idx_rel_source ON relationships (tenant_id, source_type, source_id);
-- Find all relationships TO a given entity
CREATE INDEX idx_rel_target ON relationships (tenant_id, target_type, target_id);
-- Prevent duplicate edges
CREATE UNIQUE INDEX idx_rel_unique_edge
    ON relationships (tenant_id, source_type, source_id, target_type, target_id, relation_kind);

-- ===========================================================
-- ACTIVITIES  (polymorphic timeline, list-partitioned by partition_number)
-- ===========================================================
-- Activities use the same polymorphic pattern as Relationships:
-- entity_type + entity_id identify the parent record. No DB-level
-- FK — Core CRM Service validates existence, async scanner catches drift.
CREATE TABLE activities (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    partition_number SMALLINT NOT NULL,
    entity_type     TEXT NOT NULL,     -- 'contact','company','opportunity','custom:policy'
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
    PRIMARY KEY (tenant_id, id)
) PARTITION BY LIST (partition_number);

-- Timeline queries: "show all activities for this contact, newest first"
CREATE INDEX idx_activities_entity    ON activities (tenant_id, entity_type, entity_id, occurred_at DESC);
-- Filter by type: "show all calls for this tenant"
CREATE INDEX idx_activities_type      ON activities (tenant_id, activity_type, occurred_at DESC);
-- Automation evaluation: CDC catchup / incremental sync
CREATE INDEX idx_activities_updated   ON activities (tenant_id, updated_at);
-- Task-specific: "show open tasks for this owner"
CREATE INDEX idx_activities_open_tasks ON activities (tenant_id, owner_id, status)
    WHERE activity_type = 'task' AND status = 'open';
-- GIN index on details for type-specific queries
CREATE INDEX idx_activities_details   ON activities USING GIN (details jsonb_path_ops);

CREATE TRIGGER trg_activities_updated_at
    BEFORE UPDATE ON activities FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ===========================================================
-- CHANGE LOG  (for automation triggers & audit)
-- ===========================================================
CREATE TABLE change_log (
    id              BIGINT GENERATED ALWAYS AS IDENTITY,
    tenant_id       UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    action          TEXT NOT NULL,     -- 'create','update','delete','merge','stage_change'
    changed_fields  JSONB,             -- {field: {old, new}}
    actor_id        UUID,              -- who made the change
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id, created_at)
) PARTITION BY RANGE (created_at);

-- Monthly partitions, auto-created by pg_partman or similar
-- CREATE TABLE change_log_2026_01 PARTITION OF change_log
--     FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

CREATE INDEX idx_changelog_entity ON change_log (tenant_id, entity_type, entity_id, created_at);
CREATE INDEX idx_changelog_time   ON change_log (tenant_id, created_at);

-- ===========================================================
-- PARTITIONING STRATEGY
-- ===========================================================
-- All high-volume tables use PARTITION BY LIST (partition_number)
-- with 64 partitions (0-63). The Tenant Service assigns each tenant
-- a partition_number at onboarding based on capacity estimates:
--   0-59  = shared partitions (multiple tenants)
--   60-63 = dedicated partitions (one whale tenant each)
--
-- Every data row carries partition_number as a SMALLINT column (2 bytes).
-- Postgres routes INSERTs to the correct partition via the LIST value.
-- Each partition has a 1:1 mirror ES index (crm_contacts_pNN).
--
-- LIVE TENANT MIGRATION between partitions:
--   When a partition becomes too hot, a tenant can be moved to a
--   less-loaded partition with ~2-5 seconds of read pause:
--   1. Enable dual-write (write to both old + new partition)
--   2. Backfill historical data to new partition (batched, throttled)
--   3. Brief cutover: switch partition_number, invalidate cache
--   4. Cleanup old partition data after 7-day soak
--   See Part 4, Section 4 for the full 12-step runbook.
--
-- ADDING MORE PARTITIONS (64 → 128):
--   With LIST partitioning, adding partition 64 is just:
--   CREATE TABLE contacts_p64 PARTITION OF contacts FOR VALUES IN (64);
--   No data migration for existing partitions. New tenants can be
--   assigned to the new partition immediately. Existing tenants can be
--   live-migrated to the new partition using the same runbook.

-- ===========================================================
-- ROW-LEVEL SECURITY  (applied to ALL tenant-scoped tables)
-- ===========================================================
ALTER TABLE contacts              ENABLE ROW LEVEL SECURITY;
ALTER TABLE companies             ENABLE ROW LEVEL SECURITY;
ALTER TABLE pipelines             ENABLE ROW LEVEL SECURITY;
ALTER TABLE opportunities         ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_object_types   ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_object_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE relationships         ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities            ENABLE ROW LEVEL SECURITY;
ALTER TABLE change_log            ENABLE ROW LEVEL SECURITY;

-- Example policy (repeated for each table):
CREATE POLICY tenant_isolation ON contacts
    USING  (tenant_id = current_setting('app.current_tenant')::uuid)
    WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);

CREATE POLICY tenant_isolation ON companies
    USING  (tenant_id = current_setting('app.current_tenant')::uuid)
    WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid);

-- ... repeated for pipelines, opportunities, custom_object_types,
--     custom_object_records, relationships, change_log

-- ===========================================================
-- AUTO-UPDATED TIMESTAMPS
-- ===========================================================
-- Every table with an updated_at column should have it set automatically
-- on UPDATE. This is cheaper and more reliable than relying on every
-- service code path to remember SET updated_at = now().

CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_contacts_updated_at
    BEFORE UPDATE ON contacts FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_companies_updated_at
    BEFORE UPDATE ON companies FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_pipelines_updated_at
    BEFORE UPDATE ON pipelines FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_opportunities_updated_at
    BEFORE UPDATE ON opportunities FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_custom_object_types_updated_at
    BEFORE UPDATE ON custom_object_types FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_custom_object_records_updated_at
    BEFORE UPDATE ON custom_object_records FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_relationships_updated_at
    BEFORE UPDATE ON relationships FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
```

---

### Custom Field Strategy: Why JSONB Over Pure EAV

| Approach | Read Speed | Write Speed | Query Flexibility | Schema Evolution | Operational Complexity |
|---|---|---|---|---|---|
| **EAV tables** | Slow (pivot joins) | Fast | High (per-value indexing) | Easy | High (complex queries) |
| **JSONB column** | Fast (single row read) | Fast | Good (GIN, `@>`, `->>`) | Easy (metadata-only) | Low |
| **Wide tables (column-per-field)** | Fastest | Slow (DDL locks) | Highest | Hard (ALTER TABLE at scale) | Medium |

**Choice: JSONB with GIN indexing (exact match only).** This gives us single-row reads (no joins), good query support for exact-match lookups (e.g., `custom_fields @> '{"region": "Northeast"}'` — which checks "does this JSONB contain this key-value pair?"), and zero-downtime schema evolution (adding a field is a metadata-only change to `field_schema`). The GIN index (Generalized Inverted Index — a Postgres index type that indexes the contents of a JSONB column, not just a single value) makes these exact-match queries fast even at millions of rows. The trade-off is that per-field type enforcement happens at the service layer (Core CRM Service) rather than via column constraints — we mitigate this with a validation layer that checks `custom_fields`/`data` against the tenant's `field_schema` on every write.

**Custom field queries are exact match only.** The GIN index supports containment (`custom_fields @> '{"region": "Northeast"}'`) but not range queries (`lead_score > 80`). We intentionally do not promote JSONB fields to generated columns or expression indexes — this avoids column sprawl, DDL-at-runtime, and index proliferation. Range queries and sorting on tenant-defined data use the dedicated `custom_score` column instead, which is a single NUMERIC column per entity computed from tenant-defined scoring rules (see `scoring_rules` table). This covers the primary use case — "rank contacts by some metric" — without per-field infrastructure.

**Scoring computation.** The Core CRM Service computes `custom_score` on every write using the tenant's scoring formula (fetched from the Tenant Service, cached in memory, 30s TTL). When a tenant changes their scoring rule, a background job recomputes all existing scores in batches. The `custom_score` value is synced to Elasticsearch via CDC, where it supports range filters and sorting. Postgres stores it as source of truth but does not index it for sorting — ES handles all list/sort queries.

---

### Relationship Modelling: Polymorphic Edges

The `relationships` table can connect **any entity to any other entity** using a single table. Instead of separate tables for contact-company links, contact-opportunity links, etc., we use one table with two pairs of columns: `source_type` + `source_id` (what kind of entity, and which one) and `target_type` + `target_id` (same for the other end). The type columns hold strings like `'contact'`, `'company'`, `'opportunity'`, or `'custom:policy'`, and the ID columns hold UUIDs. This is sometimes called a "polymorphic" pattern — one table shape that adapts to multiple entity types.

**Why not dedicated junction tables?** (e.g., `contact_companies`, `contact_opportunities`)
Dedicated junctions don't scale to arbitrary custom objects — we'd need a new table per custom type pair, which breaks the extensibility requirement. With the polymorphic approach, when a tenant creates a "Vehicle" custom object, relationships between Vehicles and Contacts work immediately without any DDL.

**Why not a single FK?**
Cross-table foreign keys can't be enforced natively in Postgres for polymorphic columns. We accept service-level referential integrity (enforced by the Core CRM Service) and compensate with:
- The unique edge constraint (`idx_rel_unique_edge`) prevents duplicate relationships at the DB level.
- The write path performs an existence check within the same transaction.
- An async integrity checker runs hourly, flagging dangling references.

The `relation_kind` column types the edge semantically (e.g., "primary_contact", "associated", "parent"), enabling queries like "find all primary contacts for this opportunity" without scanning unrelated edges.

---

## 3. Entity-Relationship Diagram

> See `diagrams/erd.mermaid` for the machine-readable version. ASCII summary below:

```
┌─────────────┐
│   TENANT    │
│─────────────│
│ id (PK)     │
│ name        │
│ slug (UQ)   │
│ plan_tier   │
└──────┬──────┘
       │ 1:N (every entity below belongs to one tenant)
       │
       ├─────────────────┬─────────────────┬────────────────────┐
       │                 │                 │                    │
┌──────┴──────┐   ┌──────┴──────┐   ┌─────┴───────┐   ┌───────┴──────────┐
│  CONTACT    │   │   COMPANY   │   │  PIPELINE   │   │CUSTOM_OBJECT_TYPE│
│─────────────│   │─────────────│   │─────────────│   │──────────────────│
│ tenant_id*  │   │ tenant_id*  │   │ tenant_id*  │   │ tenant_id*       │
│ id (PK)     │   │ id (PK)     │   │ id (PK)     │   │ id (PK)          │
│ email       │   │ name        │   │ name        │   │ slug (UQ/tenant) │
│ first_name  │   │ domain      │   │ stages[]    │   │ display_name     │
│ last_name   │   │ industry    │   │ is_default  │   │ field_schema[]   │
│ custom_flds │   │ custom_flds │   └──────┬──────┘   └────────┬─────────┘
│ lifecycle   │   │ lifecycle   │          │ 1:N               │ 1:N
└──────┬──────┘   └──────┬──────┘   ┌──────┴──────┐   ┌───────┴──────────┐
       │                 │          │ OPPORTUNITY │   │CUSTOM_OBJ_RECORD │
       │                 │          │─────────────│   │──────────────────│
       │                 │          │ tenant_id*  │   │ tenant_id*       │
       │                 │          │ id (PK)     │   │ id (PK)          │
       │                 │          │ pipeline_id │   │ object_type_id   │
       │                 │          │ stage_id    │   │ data (JSONB)     │
       │                 │          │ amount      │   │ lifecycle        │
       │                 │          │ lifecycle   │   └────────┬─────────┘
       │                 │          └──────┬──────┘            │
       │                 │                 │                   │
       ▼                 ▼                 ▼                   ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                      RELATIONSHIPS                           │
  │  (polymorphic junction – any entity ↔ any entity)            │
  │──────────────────────────────────────────────────────────────│
  │  tenant_id*, id (PK)                                         │
  │  source_type + source_id  ──→  target_type + target_id       │
  │  relation_kind ('primary_contact', 'associated', 'parent')   │
  └──────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │                      ACTIVITIES                              │
  │  (polymorphic timeline – any activity on any entity)         │
  │──────────────────────────────────────────────────────────────│
  │  tenant_id*, id (PK)                                         │
  │  entity_type + entity_id  ──→  parent record                 │
  │  activity_type ('email', 'call', 'meeting', 'note', 'task') │
  │  subject, body, details (JSONB), occurred_at                 │
  └──────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │                      CHANGE_LOG                              │
  │  (append-only audit trail, partitioned by created_at)        │
  │──────────────────────────────────────────────────────────────│
  │  tenant_id*, id (PK)                                         │
  │  entity_type + entity_id, action, changed_fields             │
  └──────────────────────────────────────────────────────────────┘
```

---

## 4. Invariants & Rules

### Invariant 1: Tenant Scoping

**Rule:** Every non-tenant row must belong to exactly one tenant. No row may exist with a NULL `tenant_id`, and no query may return rows from a different tenant.

**Enforcement:**
- `NOT NULL` constraint on `tenant_id` in every table.
- Postgres RLS policy on every table: `USING (tenant_id = current_setting('app.current_tenant')::uuid)`.
- Application middleware sets `app.current_tenant` at connection acquisition from the authenticated JWT.
- Integration test suite that attempts cross-tenant reads/writes and asserts they fail.

### Invariant 2: Pipeline-Tenant Consistency

**Rule:** An Opportunity's `pipeline_id` must reference a Pipeline belonging to the same tenant. A stage change must reference a `stage_id` that exists within that Pipeline's `stages` JSONB array.

**Enforcement:**
- **DB-level:** Composite foreign key `FOREIGN KEY (tenant_id, pipeline_id) REFERENCES pipelines(tenant_id, id)` guarantees tenant consistency.
- **Application-level:** The write path loads `pipelines.stages` (cached per tenant) and validates that the target `stage_id` exists within the array before accepting the write. This is application-enforced because checking inside a JSONB array via a CHECK constraint is fragile and hard to maintain.

### Invariant 3: Lifecycle State Machine

**Rule:** Lifecycle transitions must follow allowed paths:
- `active → archived → active` (re-activation)
- `active → deleted` (soft-delete)
- `active → merged` (contacts only, must set `merged_into_id`)
- `archived → deleted` (permanent removal of archived records)
- `deleted` records are hard-purged after 90 days.
- `archived`/`deleted` records are excluded from default search and list queries.

**Enforcement:**
- Core CRM Service enforces a state machine with a `validateTransition(from, to)` function and an allowed-transitions map. The `archived → deleted` transition is validated by the same function. Rejects invalid transitions before the query is executed.
- DB CHECK constraint ensures the column is always one of the allowed states.
- DB CHECK constraint ensures `lifecycle_status != 'merged' OR merged_into_id IS NOT NULL`.
- Default query scopes append `WHERE lifecycle_status = 'active'` unless the caller explicitly opts in to see archived/deleted records (admin-only permission).
- A scheduled job hard-deletes records where `deleted_at < now() - interval '90 days'`, processing in tenant-partitioned batches.

### Invariant 4: Relationship Referential Integrity

**Rule:** Both endpoints of a Relationship must reference existing, non-deleted records of the declared types within the same tenant. No duplicate edges (same source, target, and kind) are allowed.

**Enforcement:**
- The unique index `idx_rel_unique_edge` prevents duplicates at the DB level.
- Since polymorphic FKs can't use native Postgres constraints, the Core CRM Service performs an existence check within the same transaction:
  ```sql
  SELECT 1 FROM {resolved_table}
  WHERE tenant_id = $1 AND id = $2 AND lifecycle_status != 'deleted'
  ```
- An **async integrity checker** runs hourly, scanning relationships and flagging any that point to non-existent or deleted records. Flagged edges are soft-removed and an operational alert fires.

### Invariant 5: Custom Field Schema Conformance

**Rule:** The `data` column of a `custom_object_record` (and `custom_fields` on core objects) must conform to the relevant `field_schema`. Required fields must be present. Values must match declared types. Enum values must be within the declared option set.

**Enforcement:**
- The Core CRM Service validates on every write: it loads the cached `field_schema` (from the Tenant Service cache) for the record's type and validates the payload against it using a JSON Schema validator.
- Type coercion is explicit — the API rejects a string where a number is expected rather than silently converting.
- A background audit job periodically samples records and re-validates them against current schema, catching drift from bugs or direct DB edits.

### Invariant 6: Merge Consistency (Contacts)

**Rule:** When two Contacts are merged, the surviving record absorbs all relationships from the defunct record. The defunct record's status becomes `'merged'` with `merged_into_id` pointing to the survivor. No new relationships may be created to a merged record.

**Enforcement:**
- The merge operation runs in a single transaction:
  1. Re-point all relationships where the defunct contact is a source or target.
  2. Set `lifecycle_status = 'merged'` and `merged_into_id` on the defunct contact.
  3. Write a `change_log` entry recording the merge.
- The CHECK constraint `(lifecycle_status != 'merged' OR merged_into_id IS NOT NULL)` enforces data consistency.
- The relationship write path rejects any edge pointing to a record with `lifecycle_status = 'merged'`, returning a redirect to the surviving record ID.

### Invariant 7: Activity Entity Integrity

**Rule:** An Activity's `entity_type` + `entity_id` must reference an existing, non-deleted record of the declared type within the same tenant. The `activity_type` must be one of the allowed discriminator values, and `details` must conform to the per-type JSON Schema. Activities with `activity_type = 'task'` must have a valid `status` transition (`open → completed`, `open → canceled`); activities of other types default to `completed` and are immutable in status.

**Enforcement:**
- Same polymorphic integrity pattern as Relationships: the Core CRM Service performs an existence check in the write path, the Dedup Service's async integrity scanner catches drift hourly.
- The CHECK constraint ensures `activity_type` is always a valid discriminator and `status` is one of `open`, `completed`, `canceled`.
- The `details` column is validated by the Core CRM Service against a per-`activity_type` JSON Schema on every write. Unknown `activity_type` values (for extensibility via `'custom'`) require the tenant to register a detail schema via the Tenant Service first.
- Activities participate in the CDC pipeline: every create/update emits a change event to `cdc.crm.activities`, enabling automations to trigger on activity events (not just field changes).
- **Activities are NOT cascade-deleted** when the parent entity is deleted. Activities represent real-world interactions (calls, emails, meetings) and serve as audit evidence. When a contact is soft-deleted, their timeline remains intact but inaccessible via the normal API. On GDPR hard-purge, `body` and `details` are scrubbed to NULL, but metadata (`activity_type`, `occurred_at`, `duration_secs`) is retained for aggregate analytics.

---

## 5. Contact Deduplication Strategy

Duplicate contacts are inevitable in any CRM that accepts data from multiple sources (form submissions, CSV imports, API integrations, manual entry). We handle deduplication as a detection-and-suggest pipeline rather than auto-merging, because false positives in merges destroy data and erode user trust.

### Detection

An async deduplication job computes similarity scores across three signals:

1. **Normalized email** — `lower(trim(email))`. Exact match on normalized email within the same tenant is a high-confidence duplicate signal.
2. **Phone normalization (E.164)** — Raw phone strings are normalized to E.164 format before comparison. Matching E.164 values within the same tenant are flagged.
3. **Fuzzy name matching** — Trigram similarity via `pg_trgm`. We compute `similarity(lower(first_name || ' ' || last_name), ...)` and flag pairs above a configurable threshold (default: 0.6). Name-only matches are low confidence and always require a second signal (matching email domain, matching company, etc.) to surface as a suggestion.

The index supporting dedup queries:

```sql
CREATE INDEX idx_contacts_dedup
    ON contacts USING GIN (lower(email) gin_trgm_ops)
    WHERE lifecycle_status = 'active';
```

### When Detection Runs

- **On ingestion:** Every newly created contact is checked against existing active contacts in the same tenant. This runs synchronously in a background job triggered by the contact creation event, not in the request path — the API returns immediately.
- **Periodic full-tenant scan:** A weekly job scans all active contacts per tenant, computing pairwise similarity in batches. This catches duplicates that were missed at ingestion time (e.g., when two contacts were imported simultaneously in a bulk operation).

### Merge Suggestions

Detected duplicates are surfaced to users as merge suggestions, not auto-merged. Suggestions are stored in a dedicated table:

```sql
CREATE TABLE merge_suggestions (
    id              UUID NOT NULL DEFAULT uuidv7(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    contact_id_a    UUID NOT NULL,
    contact_id_b    UUID NOT NULL,
    confidence      NUMERIC(3,2) NOT NULL,   -- 0.00 to 1.00
    signals         JSONB NOT NULL,           -- [{type: "email_exact", score: 1.0}, {type: "name_trigram", score: 0.72}]
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','accepted','dismissed')),
    resolved_by     UUID,
    resolved_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
);

CREATE INDEX idx_merge_suggestions_pending
    ON merge_suggestions (tenant_id, status)
    WHERE status = 'pending';
```

Users review suggestions in the UI and choose to merge or dismiss. The merge operation itself follows the procedure described in Invariant 6 — re-pointing relationships, setting `lifecycle_status = 'merged'`, and recording the event in `change_log`.
