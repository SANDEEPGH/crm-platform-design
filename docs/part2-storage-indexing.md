# Part 2 – Storage & Indexing Strategy Across Multiple Engines

## 1. Source of Truth vs Derived Stores

### Storage Topology

```
    ┌─────────────────────────────────────────────────────────────┐
    │                      APPLICATION LAYER                      │
    │                                                             │
    │  Writes ──────► Postgres (Source of Truth)                  │
    │                      │                                      │
    │                      │  CDC (Debezium)                      │
    │                      ▼                                      │
    │                    Kafka                                    │
    │                   ╱      ╲                                  │
    │                  ╱        ╲                                 │
    │                 ▼          ▼                                │
    │         Elasticsearch    ClickHouse                         │
    │          (Search)        (Analytics)                        │
    │              ▲                ▲                             │
    │              │                │                             │
    │  UI Search ──┘   Dashboards ──┘                            │
    └─────────────────────────────────────────────────────────────┘
```

### What Lives Where

**PostgreSQL – Source of Truth**

All entity CRUD lives here. This is the only store that accepts writes, owned by the Core CRM Service. It is authoritative for: current record state, relationship graphs, custom object schemas, tenant configuration, and lifecycle state machines.

Key access patterns served directly by Postgres:
- Single-record reads (by primary key)
- Relationship traversal (get all contacts for a company)
- Transactional writes with referential integrity
- Automation trigger evaluation (via the `change_log` table)

**Elasticsearch – Search & Segmentation**

Denormalized, read-only documents optimized for the UI's filter/search/segment-building use cases. This store is authoritative for nothing — it is always rebuildable from Postgres.

Key access patterns:
- Full-text search across contact/company names and emails
- Multi-field filtering ("all contacts in CA with >3 open opportunities over $5,000")
- Segment building for messaging campaigns
- Faceted counts for UI filter panels

**ClickHouse – Analytics & Reporting**

Append-oriented, columnar store for dashboards, historical trend analysis, and cohort queries. Uses `ReplacingMergeTree` to deduplicate by record version.

Key access patterns:
- Aggregated dashboards (pipeline value by stage over time, win rate trends)
- Cohort analysis (contacts created in Q1 → how many converted by Q3)
- Funnel reporting (opportunity stage progression)
- AI/ML feature extraction (contact engagement scoring)

### Why Three Stores?

A single "all contacts in CA with >3 open opportunities over $5,000" query in Postgres requires a multi-table join with aggregation and a HAVING clause — workable for one user, but at 10,000 concurrent tenants it would saturate connection pools and blow through I/O budgets. Elasticsearch stores this answer pre-joined in a single document, turning it into a simple filtered query.

ClickHouse enters because Elasticsearch is not a good analytics engine: it lacks true columnar compression, its aggregation performance degrades at scale, and its retention/rollup story is weak. ClickHouse delivers sub-second dashboard queries over billions of rows with 10:1 compression.

### ClickHouse Table Schemas

ClickHouse mirrors the core CRM entities as flat, denormalized tables optimized for analytical queries. We use two ClickHouse table engines:

- **`ReplacingMergeTree`** — for entity tables (contacts, opportunities, activities). When the same record is updated multiple times, ClickHouse keeps only the latest version. It does this by periodically merging data files in the background and discarding older versions based on a `version` column. Until a merge happens, queries may briefly see duplicate rows — this is acceptable for dashboards that show trends, not real-time state.
- **`MergeTree`** — for append-only event streams (change_events). No deduplication needed; every event is a distinct historical record.

**crm_contacts**

```sql
CREATE TABLE crm_contacts
(
    tenant_id         String,
    id                String,
    email             String,
    first_name        String,
    last_name         String,
    lifecycle_stage   LowCardinality(String),
    lifecycle_status  LowCardinality(String),
    company_names     Array(String),
    opportunity_count UInt32,
    total_opportunity_value Decimal64(2),
    custom_score      Nullable(Float64) COMMENT 'Tenant-defined composite score, synced from Postgres',
    custom_fields     String COMMENT 'JSON-encoded custom field values',
    created_at        DateTime64(3),
    updated_at        DateTime64(3),
    version           UInt64
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(created_at)
ORDER BY (tenant_id, id)
SETTINGS index_granularity = 8192;
```

The `version` column (populated from the Postgres `xmin` transaction ID or a monotonic sequence) drives `ReplacingMergeTree` deduplication: when ClickHouse merges parts, it keeps only the row with the highest `version` for each `(tenant_id, id)` pair. Queries that need guaranteed dedup before a merge completes should use `FINAL`, but dashboard queries generally tolerate brief duplicates and avoid the performance cost. We partition by `created_at` (immutable) rather than `updated_at` because `ReplacingMergeTree` only deduplicates within the same partition during background merges. If we partitioned by `updated_at`, an updated record would land in a different partition than the original, and the old version would never be removed by background merges — causing unbounded storage growth and stale data in `FINAL` queries that must scan all partitions.

**crm_opportunities**

```sql
CREATE TABLE crm_opportunities
(
    tenant_id        String,
    id               String,
    pipeline_id      String,
    pipeline_name    LowCardinality(String),
    stage_id         String,
    stage_name       LowCardinality(String),
    amount           Decimal64(2),
    currency         LowCardinality(String),
    lifecycle_status LowCardinality(String),
    owner_id         String,
    custom_score     Nullable(Float64) COMMENT 'Tenant-defined composite score',
    expected_close   Nullable(Date),
    created_at       DateTime64(3),
    updated_at       DateTime64(3),
    won_at           Nullable(DateTime64(3)),
    lost_at          Nullable(DateTime64(3)),
    version          UInt64
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(created_at)
ORDER BY (tenant_id, pipeline_id, id)
SETTINGS index_granularity = 8192;
```

Ordering by `(tenant_id, pipeline_id, id)` places all opportunities within a pipeline adjacently on disk, which is the dominant access pattern for pipeline analytics (value by stage, win rate by pipeline, stage duration).

**crm_change_events**

```sql
CREATE TABLE crm_change_events
(
    tenant_id      String,
    entity_type    LowCardinality(String),
    entity_id      String,
    action         LowCardinality(String),
    changed_fields String COMMENT 'JSON-encoded map of field name → {old, new}',
    actor_id       String,
    created_at     DateTime64(3)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (tenant_id, entity_type, created_at)
TTL created_at + INTERVAL 2 YEAR
SETTINGS index_granularity = 8192;
```

This table is append-only (plain `MergeTree`, no dedup needed). The 2-year TTL automatically drops old partitions — change events beyond that window are available in Postgres's `change_log` table if needed for compliance queries. The `changed_fields` column stores a JSON string rather than a `Map` type because field names vary wildly across tenants and entity types.

**crm_activities**

```sql
CREATE TABLE crm_activities
(
    tenant_id      String,
    id             String,
    entity_type    LowCardinality(String),
    entity_id      String,
    activity_type  LowCardinality(String),
    subject        Nullable(String),
    status         LowCardinality(String),
    occurred_at    DateTime64(3),
    duration_secs  Nullable(UInt32),
    owner_id       String,
    details        String COMMENT 'JSON-encoded type-specific payload',
    created_at     DateTime64(3),
    updated_at     DateTime64(3),
    version        UInt64
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (tenant_id, entity_type, entity_id, occurred_at)
SETTINGS index_granularity = 8192;
```

Ordering by `(tenant_id, entity_type, entity_id, occurred_at)` places all activities for a given entity adjacently on disk — the dominant access pattern for timeline rendering and activity-based analytics (e.g., "average calls per contact before deal close"). Partitioned by `occurred_at` (user-supplied, immutable once written) rather than `created_at` to support historical activity imports without scattering data across partitions.

**Materialized View: Pipeline Value by Stage**

A common dashboard query — "show me total pipeline value grouped by stage for each tenant" — scans the full `crm_opportunities` table on every request. We precompute this with a materialized view that updates incrementally as new data lands:

```sql
CREATE MATERIALIZED VIEW mv_pipeline_value_by_stage
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(updated_at)
ORDER BY (tenant_id, pipeline_id, stage_id, updated_at)
AS
SELECT
    tenant_id,
    pipeline_id,
    stage_id,
    anyLast(stage_name)   AS stage_name,
    toStartOfDay(updated_at) AS updated_at,
    count()               AS opportunity_count,
    sum(amount)           AS total_value,
    sumIf(amount, lifecycle_status = 'won') AS won_value
FROM crm_opportunities
GROUP BY
    tenant_id,
    pipeline_id,
    stage_id,
    toStartOfDay(updated_at);
```

`SummingMergeTree` is a ClickHouse engine that automatically keeps running totals. When new opportunity data arrives, ClickHouse adds the new numbers to the existing totals for each tenant-pipeline-stage combination — instead of recounting from scratch. Dashboard queries read these pre-computed totals instead of scanning millions of opportunity rows, reducing query latency from seconds to low milliseconds.

---

## 2. Indexing & Denormalization

### Elasticsearch Index Template & Per-Partition Indexes

ES uses **one index per Postgres LIST partition**: `crm_contacts_p00` through `crm_contacts_p63`. This creates a 1:1 structural alignment — the same `partition_number` (assigned by the Tenant Service at onboarding based on capacity estimates, stored on the `tenants` table) determines both the Postgres partition and the ES index. The Search Service resolves the index name by calling the Tenant Service for `partition_number`, then computing `crm_contacts_p{partition_number:02d}`.

ES stores only fields needed for **filtering, sorting, and full-text search** — not display fields. On every list/search query, ES returns matching IDs only (`_source: false`). The Search Service then calls the Core CRM Service to batch-fetch full records from Postgres by PK, preserving ES sort order. This keeps ES documents small (~400-600 bytes vs ~2-3 KB), eliminates nested types entirely, and ensures display data is always fresh from the source of truth.

All 64 indexes share a single **index template** — the mapping and settings are defined once:

```json
PUT _index_template/crm_contacts_template
{
  "index_patterns": ["crm_contacts_p*"],
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1,
      "refresh_interval": "5s"
    },
    "analysis": {
      "analyzer": {
        "name_analyzer": {
          "type": "custom",
          "tokenizer": "standard",
          "filter": ["lowercase", "asciifolding"]
        }
      }
    }
  },
    "mappings": {
      "_source": { "enabled": false },
      "properties": {
        "id":               { "type": "keyword", "store": true },
        "tenant_id":        { "type": "keyword" },

        "full_name":        { "type": "text", "analyzer": "name_analyzer" },
        "email_domain":     { "type": "keyword" },
        "lifecycle_stage":  { "type": "keyword" },
        "lifecycle_status": { "type": "keyword" },
        "custom_score":     { "type": "double" },

        "company_names":      { "type": "keyword" },
        "company_industries": { "type": "keyword" },

        "opportunity_stats": {
          "properties": {
            "open_count":     { "type": "integer" },
            "open_value":     { "type": "double" },
            "won_count":      { "type": "integer" },
            "won_value":      { "type": "double" }
          }
        },

        "custom_fields":    { "type": "flattened" },

        "created_at":       { "type": "date" },
        "updated_at":       { "type": "date" }
      }
    }
  }
}
```

No `_routing` configuration — routing is implicit via the index name. The Search Service addresses `crm_contacts_p{partition_number}` directly (resolved via Tenant Service), so there's no possibility of accidentally querying the wrong partition. The `tenant_id` keyword filter is still mandatory on every query as a safety belt (multiple tenants can share the same partition).

**Key differences from a traditional fat-document approach:**

| Design Choice | Rationale |
|---|---|
| `_source: false` | Documents are never returned as-is. Only the `id` field (stored separately) is retrieved. Saves disk and speeds up queries. |
| `full_name` instead of separate `first_name`/`last_name` | Only used for text search, not display. Postgres returns the real name fields. |
| No `email`, `phone` fields | Display-only fields — not filtered on. Fetched fresh from Postgres. `email_domain` (keyword) is kept for domain-based filtering. |
| `company_names` / `company_industries` as flat keyword arrays | Replaces the `nested` type. `"company_industries": ["Technology", "Finance"]` enables `terms` queries without nested overhead. Each nested object in ES creates a hidden Lucene document — removing nested types reduces the Lucene doc count from ~14 per contact (1 + 3 companies + 10 opportunities) to exactly 1. |
| No `open_opportunities` nested array | Removed entirely. `opportunity_stats` (4 numbers) is sufficient for filtering ("contacts with 3+ open deals"). Opportunity details come from Postgres. |
| `custom_score` as `double` | Supports range queries (`gte`, `lte`) and sorting. The only custom data that ES range-queries — everything else in `custom_fields` is exact-match via `flattened`. |

**Document size:** ~400-600 bytes (down from ~2-3 KB). At 2B contacts: **~800 GB-1.2 TB** total ES storage (down from ~4-6 TB). This allows a smaller ES cluster — fewer shards, less heap, lower cost.

We use the ES `flattened` field type for `custom_fields` — a special ES field type that stores all key-value pairs inside a JSONB-like structure under a single mapping entry, regardless of how many different field names tenants create. This prevents "mapping explosion" (where each unique field name creates a separate mapping entry). With 50K tenants each defining their own custom fields, dynamic mapping would create millions of unique field paths, exceeding ES's default limit of 1,000 fields per index and causing mapping updates to become a cluster-wide bottleneck. The `flattened` type stores all custom fields as keyword-only values within a single field mapping, regardless of how many distinct field names tenants create.

**Custom fields are intentionally exact-match only.** The `flattened` type supports `eq`, `in`, and `prefix` queries — not range queries (`gt`, `lt`, `between`) or full-text search. We do not promote individual fields to typed ES mappings. This eliminates the need for a promotion detection pipeline, per-field background re-indexing, and `custom_fields_promoted.*` mapping sprawl. Range queries and sorting on tenant-defined data use the dedicated `custom_score` field (a single `double` in the ES mapping, synced from the Postgres `custom_score` column via CDC). Each tenant defines their own scoring formula in the `scoring_rules` table (managed by the Tenant Service); the Core CRM Service computes the score on every write using the cached rule.

### Elasticsearch Index: Opportunity Template (`crm_opportunities_p*`)

Same per-partition pattern. Template `crm_opportunities_template` with `index_patterns: ["crm_opportunities_p*"]`, 1 shard + 1 replica per index.

```json
{
  "mappings": {
    "_source": { "enabled": false },
    "properties": {
      "id":               { "type": "keyword", "store": true },
      "tenant_id":        { "type": "keyword" },

      "name":             { "type": "text",
                            "fields": { "keyword": { "type": "keyword" } } },
      "pipeline_id":      { "type": "keyword" },
      "stage_id":         { "type": "keyword" },
      "stage_name":       { "type": "keyword" },
      "amount":           { "type": "double" },
      "currency":         { "type": "keyword" },
      "expected_close":   { "type": "date" },
      "probability":      { "type": "short" },
      "lifecycle_status": { "type": "keyword" },
      "custom_score":     { "type": "double" },

      "primary_contact_name": { "type": "text" },
      "company_name":         { "type": "keyword" },
      "company_industry":     { "type": "keyword" },

      "custom_fields":    { "type": "flattened" },
      "created_at":       { "type": "date" },
      "updated_at":       { "type": "date" }
    }
  }
}
```

Nested objects for `primary_contact` and `company` are replaced by flat keyword/text fields. Full contact and company details are fetched from Postgres during enrichment. Custom fields are exact-match only; range queries and sorting use `custom_score`.

### What Gets Denormalized (and Why)

The Contact search document is **thin** — it stores only the fields needed for filtering, sorting, and text search. Display fields (email, phone, full association details) are fetched fresh from Postgres on every query via batch PK lookup.

| Embedded Data | Source | Why in ES | Why NOT in ES |
|---|---|---|---|
| `full_name` (text) | `contacts.first_name` + `last_name` | Full-text search ("find contacts matching 'jan'") | Individual `first_name`/`last_name` not needed — display comes from Postgres |
| `email_domain` (keyword) | Extracted from `contacts.email` | Domain-based filtering ("contacts at bigcorp.com") | Full `email` and `phone` are display-only — Postgres returns them |
| `company_names[]` (keyword array) | `companies.name` via `relationships` | Filter by company name | Full company objects (domain, industry, size) come from Postgres enrichment |
| `company_industries[]` (keyword array) | `companies.industry` via `relationships` | Filter by industry | |
| `opportunity_stats` (4 numbers) | Computed from `opportunities` via `relationships` | "Contacts with 3+ open deals" as a range filter | Full opportunity details (name, amount, stage) come from Postgres enrichment |
| `custom_fields` (flattened) | `contacts.custom_fields` | Exact-match filtering | |
| `custom_score` (double) | `contacts.custom_score` | Range queries and sorting | |

**No nested types.** Unlike a traditional fat-document approach, we use flat keyword arrays (`company_names`, `company_industries`) instead of nested objects. This reduces the Lucene document count from ~14 per contact (1 root + 3 company nested docs + 10 opportunity nested docs) to exactly **1 per contact**. No cardinality limits, no nested query overhead, no mapping complexity.

### ID-Only Search Pattern

Each ES index is a **thin, searchable mirror** of exactly one Postgres partition. The same `partition_number` routes to both:

```
partition_number = 7

┌─────────────────────────────────┐     ┌─────────────────────────────────┐
│ Postgres: contacts_p07          │     │ ES: crm_contacts_p07            │
│ Source of truth                 │────→│ Thin mirror (~400-600 bytes/doc)│
│ Full rows (all columns)         │ CDC │ Filterable fields only          │
│ PK + write indexes              │     │ Inverted index for search       │
└─────────────────────────────────┘     └─────────────────────────────────┘
```

Every list/filter/search query follows a five-step flow orchestrated by the **CRM Gateway**:

```
Step 1: CRM Gateway → Tenant Service
        Get partition_number for this tenant → 7
        Also get plan_tier (for ES query timeout: 5s/10s/15s)

Step 2: CRM Gateway → Search Service (pass partition_number + API-level filters)
        CRM Gateway passes API field names (e.g., "lifecycle_stage eq lead",
        "properties.email contains @acme.com", "custom_score gte 50").
        Search Service owns the TRANSLATION LAYER — converts API fields to
        ES-internal fields (e.g., email → email_domain, association count →
        opportunity_stats.open_count). CRM Gateway has no ES knowledge.
        Search Service queries ES index crm_contacts_p07 using translated query.
        Returns: sorted IDs only (_source: false)

Step 3: CRM Gateway → Core CRM Service (pass tenant_id + sorted IDs)
        Core CRM queries Postgres: SELECT * FROM contacts
          WHERE tenant_id = $1 AND id = ANY($2)
        Postgres auto-routes to contacts_p07 (same partition as the ES index)
        Returns: full rows from the source of truth

Step 4: CRM Gateway → Post-filter (in-memory, no DB call)
        Scans the Postgres rows and removes records that shouldn't be returned:
        • tenant_id mismatch (ES eventual consistency guard)
        • lifecycle_status = 'deleted' or 'merged' (deleted after ES indexed it)
        • unauthorized records (if intra-tenant RBAC is enforced)
        In practice, < 0.1% of results are removed.

Step 5: CRM Gateway → Return only verified, fresh records to client
```

**Both steps 2 and 3 hit the same partition** — step 2 searches the ES mirror (`crm_contacts_p07`), step 3 enriches from the Postgres source (`contacts_p07`). The data is structurally aligned because both are keyed by the same `partition_number`. This is not a coincidence — it's the core design invariant.

The ~5ms ES query + ~3ms Postgres PK lookup + in-memory post-filter gives a total of ~8-10ms for the full read path. The CRM Gateway adds negligible overhead (request routing, no data processing).

### Keeping the ES Mirror in Sync (CDC Pipeline)

The CDC pipeline keeps each ES index in sync with its corresponding Postgres partition:

```
Postgres partition contacts_p07
    → WAL change captured by Debezium
    → Published to Kafka topic cdc.crm.contacts
    → ES Index Worker consumes event
    → Calls Tenant Service → partition_number = 7
    → Upserts thin doc to ES index crm_contacts_p07

Same partition on both sides. The ES index is always a mirror of its Postgres partition.
```

**Direct changes** (e.g., a contact's `lifecycle_stage` changes):
1. Debezium captures the `contacts` row change from Postgres partition `contacts_p07` → publishes to Kafka topic `cdc.crm.contacts`.
2. The ES Index Worker (owned by the Search Service) consumes the event, calls the Tenant Service for `partition_number = 7`, and determines the target ES index: `crm_contacts_p07` — the mirror of the same Postgres partition the change came from.
3. It extracts thin-document fields from the CDC event payload, queries related companies and opportunity stats from Postgres, and upserts the thin document to the target index.

**Cascading changes** (e.g., a Company renames):
1. Debezium captures the `companies` row change → topic `cdc.crm.companies`.
2. The **Cascade Worker** queries `relationships` for all contacts linked to that company.
3. For each affected contact, it looks up `partition_number` and issues a **partial update** to the correct per-partition index:
   ```json
   POST crm_contacts_p07/_update/019abc01-...-1001
   { "doc": { "company_names": ["BigCorp Technologies"], "company_industries": ["Technology"] } }
   ```
4. Partial updates are batched via the ES `_bulk` API (500 per request). All documents within a batch may target different partition indexes — the `_bulk` API supports mixed-index operations.

**Why partial updates are better with thin documents:** In a fat-document approach, a company rename requires rebuilding the entire `companies` object for each linked contact (re-reading all company data from Postgres). With thin documents, we update only the flat `company_names` keyword array — a ~100-byte partial update instead of a ~2 KB full rebuild. One company rename that affects 5,000 contacts writes ~500 KB of ES data instead of ~10 MB. That's a ~20x reduction in the amount of writing caused by a single change (sometimes called "write amplification").

**Fan-out control** (one change affecting many documents)**:** A single company update can touch up to ~100K contact documents. The Cascade Worker processes updates in batches and slows down if ES can't keep up — if the batch queue grows beyond a threshold, the worker pauses before sending more. If a single cascade would affect more than 50K documents, the job is routed to a low-priority queue so it doesn't slow down normal real-time indexing.

### Kafka Topic Design

The CDC pipeline relies on Kafka as the backbone for event distribution. Topic design directly affects ordering guarantees, parallelism, and operational simplicity.

**Topic naming:** Topics follow the convention `cdc.crm.{table_name}` — e.g., `cdc.crm.contacts`, `cdc.crm.companies`, `cdc.crm.opportunities`, `cdc.crm.relationships`, `cdc.crm.activities`, `cdc.crm.change_log`. The `cdc.crm.` prefix groups all CRM CDC topics under a single namespace, making ACL management and monitoring straightforward.

**Partition count:** 32 partitions per topic. This balances parallelism (up to 32 concurrent consumers per group) with the overhead of partition metadata and rebalancing. At our projected throughput (~50k events/sec peak across all tenants), 32 partitions keep per-partition throughput well within Kafka's comfort zone (~1,500 events/sec per partition). We can increase partitions later without data loss, but prefer to start with enough to avoid early rebalancing.

**Partition key:** `tenant_id + entity_id` (concatenated and hashed). This ensures all events for a given entity within a tenant land on the same partition, preserving per-entity ordering. A contact's create, update, and delete events always arrive in order to consumers. We include `tenant_id` in the key to prevent a single large tenant's entities from concentrating on one partition.

**Retention:** 7 days for CDC topics. Events are replayable from the Postgres WAL (via Debezium snapshots) if needed beyond that window, so long retention on Kafka is unnecessary cost. The 7-day window provides enough buffer for consumer outages, deployments, and catch-up scenarios.

**Consumer groups:** Three independent consumer groups process CDC events:
- `es-indexer` — Builds and updates Elasticsearch documents. This is the latency-sensitive path (target: <5s end-to-end).
- `ch-loader` — Loads denormalized rows into ClickHouse via batch inserts. Runs with higher batching (1,000 events or 5 seconds, whichever comes first) since analytics tolerates minutes of lag.
- `automation-trigger-evaluator` — Evaluates automation rules against change events (e.g., "when lifecycle_stage changes to SQL, create a task") **and activity events** (e.g., "when an email is logged on a contact, update lead score"; "when a meeting is completed for an opportunity, create a follow-up task"). Latency-sensitive (~2s target). For field-change triggers, it processes only the `changed_fields` payload. For activity triggers, it evaluates the `activity_type`, `status`, and `details` payload against the tenant's activity-based rules — no Postgres re-read needed in either case.

Each group consumes independently, so a slow ClickHouse load does not block search indexing or automation evaluation.

**Dead-letter topic:** `cdc.crm.dlq` receives events that fail processing after 3 retries (with exponential backoff: 1s, 5s, 30s). DLQ events include the original event payload, the consumer group that failed, the error message, and a retry count. A separate DLQ processor alerts on-call and attempts reprocessing with extended timeouts during off-peak hours.

**Schema:** Events are serialized with Avro and registered in a Confluent-compatible schema registry. Avro's forward and backward compatibility rules allow us to add new fields to CDC events (e.g., a new column on `contacts`) without breaking existing consumers. Consumers that do not understand a new field simply ignore it. The schema registry rejects incompatible changes at deploy time, preventing accidental breakage.

**Compaction:** Disabled on CDC topics. CDC events are append-only change records, not key-value state updates. Each event represents a point-in-time change (with before/after values), so compaction would incorrectly discard intermediate state transitions that automation triggers and analytics depend on.

### Caching Layer

Multiple microservices need tenant metadata on every request — partition_number, scoring_rules, field_schema, plan_tier. The Tenant Service owns this data and exposes it via an internal API backed by a two-tier cache (Redis shared cache + local in-memory per service instance) that absorbs this read amplification.

**Redis (cluster mode) — Shared Application Cache:**

Redis serves as the shared, cross-instance cache for data that changes infrequently but is read on nearly every request:

- **Tenant metadata** (plan tier, feature flags, rate limit config): TTL 5 minutes. Every API request checks the tenant's plan tier for feature gating and rate limits. Reading this from Postgres on every request would add ~2ms of latency and unnecessary load. Cache is warmed on first access and invalidated via write-through: any update to the `tenants` table writes to both Postgres and Redis atomically (Postgres first, Redis immediately after on commit).
- **Custom object type field schemas** (`field_schema` for each custom object type): TTL 60 seconds, invalidated on write via Redis pub/sub. When a tenant modifies a custom object schema (adding/removing a field), the writing service publishes an invalidation message on a `cache:invalidate:field_schema` channel. All application instances subscribe and evict the affected key. The short TTL acts as a safety net if pub/sub delivery fails.
- **Pipeline stage definitions** (stage ordering, names, probabilities per pipeline): TTL 60 seconds, invalidated on write via the same pub/sub mechanism. Pipeline definitions are read on every opportunity list/filter request and change rarely (a few times per month at most).
- **Rate limit counters**: Sliding window counters per tenant, implemented with Redis sorted sets (ZRANGEBYSCORE to count requests in the window, ZADD to record new requests, ZREMRANGEBYSCORE to expire old entries). These counters are consumed by the API gateway to enforce per-tenant rate limits before requests reach any downstream microservice.

**Local In-Memory Cache — Per Application Instance:**

Some data is so stable and so frequently accessed that even a Redis round-trip (~0.5ms) is unnecessary overhead:

- **Type registry** (core object type to Postgres table mapping, e.g., "contact" maps to `contacts`, "deal" maps to `opportunities`): This is static configuration that only changes on deploy. Loaded once at startup, refreshed on deploy via a rolling restart.
- **Scoring rules per tenant**: TTL 30 seconds. Each tenant has at most one scoring rule per entity type (contact, company, opportunity). Loaded from `scoring_rules` table on cache miss. Used by the Core CRM Service to compute `custom_score` on every write. Since score computation happens on every single create/update (potentially thousands per second), it must not require a database query — the cached rule in local memory is used instead.
- **Automation trigger rules per tenant**: TTL 30 seconds. Part 4 describes the automation system evaluating trigger rules on every CDC event, but never specifies where those rules are sourced. The answer is here: trigger rules are loaded from Postgres into local memory with a 30-second TTL, keeping the hot path (CDC event evaluation) free of network calls. A stale rule for up to 30 seconds is acceptable — automation triggers are already eventual-consistency tolerant. Rules cover both field-change triggers (e.g., "lifecycle_stage changed to SQL") and activity triggers (e.g., "email logged on contact", "meeting completed for opportunity"). Both rule types live in the same rules table and are cached together.

**Cache Stampede Prevention:**

When a popular cache key expires, hundreds of concurrent requests may simultaneously attempt to refill it from Postgres, causing a thundering herd. We mitigate this with two complementary techniques:

1. **Probabilistic early expiry (jittered TTL):** Instead of setting a fixed TTL of 60 seconds, we set `TTL = 60 + random(-10, 0)` seconds. This staggers expiry across instances, so not all instances attempt a refill at the same moment.
2. **Single-flight pattern** (only one request fetches, the rest wait and share the result)**:** When a cache key expires, hundreds of concurrent requests may try to fetch the same data from Postgres simultaneously. Instead, only one request actually executes the Postgres query. All other requests for the same key wait for that one to finish, then share the result. This turns 100 simultaneous cache misses into 1 database query.

**Cache Invalidation Strategy:**

- **Write-through** for tenant metadata: the Tenant Service writes to Postgres and Redis in sequence within the same request. If the Redis write fails, the key is deleted (forcing a re-read from Postgres on next access) rather than leaving stale data.
- **Event-driven** for field schemas and pipeline definitions: a Kafka consumer on the `cdc.crm.custom_object_types` and `cdc.crm.pipelines` topics publishes Redis pub/sub invalidation messages. This ensures that even schema changes made by background jobs (not just API requests) trigger cache eviction.

---

## 3. Consistency & Latency Trade-Offs

### Consistency Requirements by Store

| Operation | Consistency | Acceptable Lag | Rationale |
|---|---|---|---|
| CRUD on Postgres | **Strong** (read-after-write) | 0 ms | User saves a contact and immediately re-reads it. Must see the update. |
| Search/filter in ES | **Eventual** | ≤ 5s (P95), ≤ 15s (P99) | User creates a contact, then searches. A brief delay is acceptable; UI shows "recently created" items from the write response. |
| Dashboards (ClickHouse) | **Eventual** | ≤ 5 min | Dashboards show trends, not real-time state. "Data as of a few minutes ago" is expected. |
| Automation triggers | **Eventual** (ordered) | ≤ 2s (P95) | "When opportunity moves to WON" must fire promptly. CDC events are ordered per-partition (by entity ID), so triggers see changes in order. |
| Campaign segmentation | **Eventual** | ≤ 30s | Segment recalculation runs against ES. Slightly stale data is acceptable for batch sends. |

### Read-After-Write UX Pattern

When a user creates or updates a record through the UI:
1. The API returns the saved record directly from Postgres.
2. The frontend optimistically inserts/updates the record in local state.
3. If the user immediately searches, the UI merges locally-known records with ES results, ensuring the just-saved record appears even before ES is updated.

This eliminates the perception of lag without requiring strong consistency from ES.

### Drift Detection & Repair

Even with a well-designed CDC pipeline, drift can occur (missed events, consumer crashes, ES mapping conflicts). We handle this at three levels:

**Level 1 – Continuous Reconciliation:**
A background job selects a random sample of ~10,000 records per hour from Postgres, computes their expected ES document hash, and compares with the actual ES document. Mismatches trigger a re-index of the affected records. This catches slow drift within hours.

**Level 2 – Watermark Monitoring:**
Each index worker publishes a "last processed WAL position" metric. If the lag between the current WAL position and the last-processed position exceeds a threshold (e.g., 30 seconds), an alert fires. Persistent lag triggers automatic scaling of consumer instances.

**Level 3 – Full Rebuild:**
For catastrophic drift or major schema changes, we support a full re-index from Postgres. The pipeline creates a new ES index (e.g., `contacts_v2`), backfills it in parallel using a cursor-based scan ordered by `(tenant_id, updated_at)`, and atomically swaps the alias (`contacts` → `contacts_v2`) when backfill is complete. Zero downtime — reads continue against the old index until the swap.

### Index Lifecycle Management (ILM — Automated Rules for Aging ES Data)

Elasticsearch indices grow continuously as tenants add data. Without lifecycle management, index performance degrades and storage costs climb. We use a hot-warm-cold architecture with automated rollover and deletion policies.

**Hot-Warm-Cold Architecture:**

- **Hot tier (NVMe SSDs):** Active write indices and recent data. All indexing operations and the majority of search queries hit this tier. Indices remain hot for their first 30 days.
- **Warm tier (HDDs):** Indices older than 30 days are relocated to warm nodes. These indices are still searchable but no longer receive writes. Shard allocation filtering moves them automatically. We reduce the replica count from 1 to 0 on warm (the data is rebuildable from Postgres, so a replica is unnecessary storage cost).
- **Cold tier (HDDs, read-only):** Indices older than 90 days are force-merged to 1 segment per shard and marked read-only. The single-segment merge eliminates the overhead of segment-level merging and dramatically improves read performance for the occasional historical query.

**Rollover Policy:** Active indices roll over to a new index when either condition is met: the index reaches 50GB or 30 days have elapsed, whichever comes first. Rollover keeps shard sizes predictable and prevents any single index from becoming unwieldy.

**Deletion Policy:** Indices older than 1 year are deleted. Postgres is the source of truth, and ES is always rebuildable — retaining more than a year of search indices provides diminishing value relative to storage cost. Tenants needing historical search beyond 1 year can trigger an on-demand re-index from Postgres for the desired time range.

**Example ILM Policy:**

```json
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_size": "50gb",
            "max_age": "30d"
          },
          "set_priority": {
            "priority": 100
          }
        }
      },
      "warm": {
        "min_age": "30d",
        "actions": {
          "allocate": {
            "require": { "data": "warm" },
            "number_of_replicas": 0
          },
          "set_priority": {
            "priority": 50
          }
        }
      },
      "cold": {
        "min_age": "90d",
        "actions": {
          "allocate": {
            "require": { "data": "cold" }
          },
          "forcemerge": {
            "max_num_segments": 1
          },
          "set_priority": {
            "priority": 0
          }
        }
      },
      "delete": {
        "min_age": "365d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

This policy is attached to the per-partition index templates (`crm_contacts_template`, `crm_opportunities_template`). For most partitions, the index stays in the hot tier indefinitely (at ~15 GB, rollover never triggers). Only whale-heavy partitions that exceed 30 GB roll over, creating versioned indexes (e.g., `crm_contacts_p07-000001`, `crm_contacts_p07-000002`) behind a read alias.

---

## 4. Indexing Patterns & Performance

### Multi-Tenant Search: Per-Partition Indexes

We use **one ES index per Postgres LIST partition** — `crm_contacts_p00` through `crm_contacts_p63`. This structurally aligns ES with Postgres: the same `partition_number` (assigned by the Tenant Service at onboarding based on capacity estimates, stored on the `tenants` table) determines both the Postgres partition and the ES index. Every data row carries `partition_number` as a column, and Postgres routes to the matching partition via `PARTITION BY LIST (partition_number)`.

**Why not one shared index with routing?**
A shared index with `_routing` works, but has operational weaknesses: forgetting the `?routing=` parameter on a query silently scans all shards (data leak risk), reindexing requires processing all 2B documents at once, and a corrupt index segment affects all tenants. Per-partition indexes solve all three — the index name IS the routing, reindexing is scoped to one partition (~31M docs), and failures affect only 1/64th of tenants.

**Why not one index per tenant?**
With 10,000+ tenants, per-tenant indexes create 20,000+ shards (with replicas) — well beyond ES best practices of < 1,000 shards per node. Per-partition indexes give us 128 indexes (64 per entity type) × 2 shards each (primary + replica) = **256 total shards** on a 3-node cluster, which is ~85 shards per node — very comfortable.

**Our approach:**
- Application resolves: `tenant.partition_number` → `crm_contacts_p{partition_number:02d}`
- Each index starts with **1 primary shard + 1 replica**. At ~31M contacts per partition × 500 bytes/doc = ~15 GB per index — well within the 30 GB per-shard guideline.
- Every query includes a mandatory `tenant_id` filter (enforced at the API gateway). Multiple tenants share a partition, so the filter is a safety belt.
- No `_routing` configuration needed — the index name provides structural isolation.

**Sizing math:**

| | Contacts | Opportunities |
|---|----------|---------------|
| Total docs | 2B       | 500M          |
| Per partition | ~31M     | ~7.8M         |
| Doc size (thin) | ~1 kb    | ~1 kb         |
| Per-index size | ~30 GB   | ~8 GB         |
| Shards per index | 1        | 1             |
| Total indexes | 64       | 64            |
| Total shards (with replicas) | 128      | 128           |

**Per-partition reshard procedure:**

When a partition's index crosses 30 GB (due to a whale tenant), reshard only that index:

1. **Monitor:** Alert fires when shard size exceeds 25 GB (Prometheus: `elasticsearch_index_shard_stats_store_size_bytes`).
2. **Create new index:** `PUT crm_contacts_p07_v2` with `number_of_shards: 2` (mapping inherited from template).
3. **Backfill from Postgres:** Read all contacts from Postgres partition 7, build thin docs, bulk-index into `crm_contacts_p07_v2`. ~31M docs at 400K docs/min (8 workers) = ~78 minutes.
4. **Dual-write during backfill:** CDC writes to both old and new index. Old index serves reads.
5. **Swap alias:** Atomic alias swap: `crm_contacts_p07` → `crm_contacts_p07_v2`. Zero downtime.
6. **Cleanup:** Delete old index after 24-hour soak period.

Impact: **only tenants in partition 7 are affected.** Other 63 partitions serve normally throughout. Application code is unchanged — it addresses the index by alias, not by version name.

**Decision table for shard count:**

| Index size | Shards | Trigger |
|---|---|---|
| < 30 GB | 1 | Default (most partitions stay here forever) |
| 30-60 GB | 2 | Reshard when alert fires |
| 60-90 GB | 3 | Reshard again |
| > 90 GB | Consider dedicated cell | Tenant is too large for shared infrastructure |

**Noisy neighbor protection:**

Per-partition indexes provide structural isolation, but tenants sharing a partition can still compete for shard resources. Additional protection:

1. **Per-tenant query timeout:** Standard tier: 5s. Professional: 10s. Enterprise: 15s. Queries exceeding the timeout return partial results with `"timed_out": true`.
2. **Rate limiting at API gateway:** Search ops/sec limits by plan tier (standard: 20, professional: 100, enterprise: 500). Enforced before requests reach ES.
3. **Node role separation:** Search queries go to search-role data nodes. CDC bulk indexing goes to ingest-role nodes. Heavy indexing from bulk imports cannot starve search queries.

### Relational DB Indexing Strategy

Every index in Postgres is led by `tenant_id` to match the query patterns:

```
Core indexes (all tables):
  (tenant_id, id)                      -- PK lookups
  (tenant_id, updated_at)              -- CDC catchup, incremental sync
  (tenant_id, lifecycle_status)        -- active-record filtering

Contact-specific:
  (tenant_id, lower(email))            -- email lookup / dedup
  GIN (custom_fields jsonb_path_ops)   -- custom field queries

Opportunity-specific:
  (tenant_id, pipeline_id, stage_id)   -- pipeline views
  (tenant_id, expected_close)          -- close-date forecasting
  (tenant_id, amount) WHERE active     -- partial index for revenue queries

Relationship-specific:
  (tenant_id, source_type, source_id)  -- "get all relations FROM this entity"
  (tenant_id, target_type, target_id)  -- "get all relations TO this entity"

Change Log:
  (tenant_id, entity_type, entity_id, created_at)  -- audit trail per entity
  (tenant_id, created_at)                           -- time-range scans for automation replay
```

### Partitioning Strategy

| Table | Partition Scheme | Key | Rationale |
|---|---|---|---|
| `contacts` | LIST (64 partitions) | `partition_number` | Tenant Service assigns partitions based on capacity. 0-59 shared, 60-63 dedicated for whales. Enables live migration between partitions. |
| `companies` | LIST (64 partitions) | `partition_number` | Same scheme — 1:1 alignment with contacts partition |
| `opportunities` | LIST (64 partitions) | `partition_number` | Same scheme |
| `custom_object_records` | LIST (64 partitions) | `partition_number` | Same scheme |
| `activities` | LIST (64 partitions) | `partition_number` | Same scheme |
| `relationships` | LIST (64 partitions) | `partition_number` | Same scheme |
| `change_log` | Range (monthly) | `created_at` | Append-only table; old partitions can be archived to cold storage. Time-range queries are the primary access pattern. |
| `companies`, `pipelines` | None | — | Lower volume; don't benefit enough from partitioning overhead |

**Why LIST by `partition_number` (not HASH by `tenant_id`)?** Hash partitioning is automatic but gives zero control — you can't choose which tenants share a partition, can't isolate a whale, and can't rebalance without a full table rewrite. LIST partitioning by an application-assigned `partition_number` gives the Tenant Service full control: new tenants are assigned to the least-loaded partition, whale tenants get dedicated partitions (60-63), and live migration between partitions is possible without downtime (see Part 4, Section 4: Tenant Onboarding & Live Partition Migration). The cost is a `SMALLINT` (2 bytes) `partition_number` column on every row in every partitioned table — negligible at ~34 GB total across 20B+ rows.
