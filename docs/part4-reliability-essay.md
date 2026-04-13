
# Part 4 – Reliability, Isolation & Safety at Scale

## 1. Reliability & Performance Budgets

### Defining the Budgets

A CRM platform's credibility rests on the reliability of its data operations. Users making sales calls, running campaigns, or reviewing dashboards cannot tolerate unpredictable latency. We define performance budgets as SLOs that flow backward into every architectural decision:

| Operation | P50 Target | P95 Target | P99 Target | Hard Timeout |
|---|---|---|---|---|
| **Single record CRUD** (create, read, update) | ≤ 15 ms | ≤ 50 ms | ≤ 150 ms | 2s |
| **List/search with filters** (≤1000 results) | ≤ 50 ms | ≤ 200 ms | ≤ 500 ms | 5s |
| **Complex segment query** (associations, aggregations) | ≤ 200 ms | ≤ 800 ms | ≤ 2s | 10s |
| **Dashboard render** (aggregated reports) | ≤ 500 ms | ≤ 2s | ≤ 5s | 30s |
| **Automation trigger delivery** (CDC → action, field changes + activities) | ≤ 500 ms | ≤ 2s | ≤ 5s | 30s |

These budgets are not aspirational numbers filed in a wiki — they are encoded as SLO checks in the CI pipeline. Every PR that touches a query path runs against a benchmark dataset, and regressions beyond the budget are flagged before merge.

### How Budgets Shape Architecture

**Indexing strategy.** The 200ms P95 target for search means we cannot afford multi-table JOINs with aggregation at query time. This is the primary driver for denormalizing contact documents in Elasticsearch — the `opportunity_stats.open_count` field exists so that "contacts with >3 open deals" resolves to a simple range filter, not a subquery. Every piece of denormalized data in ES exists because a specific query pattern would otherwise breach its budget.

**Denormalization choices.** We embed Company name and industry into the Contact search document. This means a Company rename triggers a fan-out re-index across all linked contacts. We accept this write-amplification because Company renames are rare (< 0.01% of writes) while Contact-by-company-name searches happen on every list view (> 80% of reads). The budget math is clear: optimize the hot read path, pay the cost on the cold write path.

**Background job design.** The 2-second P95 target for automation triggers means the CDC pipeline must have sub-second latency for the common case. We achieve this by:
- Running Debezium with a 100ms polling interval.
- Partitioning Kafka topics by `tenant_id` so per-tenant ordering is guaranteed without cross-partition coordination.
- Keeping automation evaluation logic stateless — each event (whether a field change or an activity creation) is evaluated independently against the tenant's trigger rules (cached in memory, refreshed every 30s). Activity-based triggers follow the same hot path as field-change triggers: the evaluator reads `activity_type`, `status`, and `details` from the CDC event payload and matches against rules where `trigger_source = 'activity'`.
- Offloading expensive actions (send email, call webhook, create follow-up activity) to a separate action queue, so trigger evaluation latency is decoupled from action execution latency.

### Monitoring and Enforcement

Every API response includes server-timing headers:

```
Server-Timing: db;dur=12.3, es;dur=45.6, total;dur=62.1
```

These are collected into a time-series database (Prometheus/Datadog) and dashboarded per tenant tier. When a tenant's P95 approaches 80% of the budget, a pre-emptive alert fires so the team can investigate before the SLO is breached — we don't want to discover problems from customer complaints.

---

## 2. Multi-Tenant Isolation & Failure Containment

### The Noisy Neighbor Problem

In a shared-infrastructure CRM, a single tenant running a poorly-constructed segment query across 50 million contacts can saturate ES shard threads, spike Postgres CPU, or exhaust connection pool slots — degrading service for every other tenant on the same infrastructure. This is the defining operational risk of multi-tenancy.

### Defense in Depth

We apply isolation at four layers:

**Layer 1: Request-Level Throttling (API Gateway)**

Every tenant has rate limits based on their plan tier:

| Tier | CRUD ops/sec | Search ops/sec | Bulk ops/sec |
|---|---|---|---|
| Standard | 50 | 20 | 5 |
| Professional | 200 | 100 | 20 |
| Enterprise | 1000 | 500 | 100 |

Rate limits are enforced at the API gateway using a sliding-window counter (Redis-backed). Exceeding the limit returns `429 Too Many Requests` with a `Retry-After` header. Crucially, the limits are per-tenant, not per-user — a tenant with 100 users shares the same pool.

**Layer 2: Query Complexity Limits (Application)**

Before any query reaches a storage engine, the Search Service (for ES queries) or Core CRM Service (for Postgres queries) evaluates its complexity:
- Number of filter clauses (max 20).
- Depth of nested association filters (max 2 levels).
- Estimated result set size (if a query would scan >100,000 records, it's rejected with a suggestion to narrow the filter or use the bulk export API).
- ES query timeout is set per-tenant (default 10s, reduced to 5s for standard-tier tenants).

**Layer 3: Connection and Resource Isolation (Infrastructure)**

Postgres connections are pooled per-tenant-tier using PgBouncer:
- Standard tenants share a pool of 100 connections.
- Enterprise tenants get a dedicated pool of 50 connections.
- A single tenant cannot hold more than 10 concurrent connections (enforced by the Core CRM Service's connection checkout logic).

**RLS compatibility with connection pooling.** Part 1 describes setting `app.current_tenant` via Postgres GUC for Row-Level Security. In PgBouncer's transaction pooling mode (which we use for connection efficiency), `SET` commands do not persist across transactions — they are reset when the connection returns to the pool. We use `SET LOCAL` instead, which scopes the setting to the current transaction:

```sql
BEGIN;
SET LOCAL app.current_tenant = 'tenant-uuid-here';
-- All subsequent queries in this transaction are RLS-filtered
SELECT * FROM contacts WHERE ...;
COMMIT;  -- setting is automatically discarded
```

This means **all tenant-scoped queries must run within an explicit transaction block** — the Core CRM Service's data access layer enforces this by wrapping every request in a transaction and calling `SET LOCAL` as the first statement. This is a strict requirement: a query outside a transaction block would not have `app.current_tenant` set and would be rejected by the RLS policy (the GUC defaults to an empty string, which doesn't match any tenant).

For Elasticsearch, we use **per-partition indexes** (1 ES index per Postgres hash partition — `crm_contacts_p00` through `crm_contacts_p63`). Each index has 1 primary shard (~15 GB for typical partitions). The Search Service (for reads) and ES Index Worker (for writes) target the correct index by name using the tenant's `partition_number` (fetched from the Tenant Service). This provides structural isolation — a query against `crm_contacts_p07` cannot touch shards belonging to other partitions. If a partition's index grows beyond 30 GB (whale tenant), it is resharded independently without affecting other partitions. Per-tenant query timeouts (standard: 5s, professional: 10s, enterprise: 15s) and API gateway rate limits provide additional protection against noisy neighbors within a shared partition.

**Layer 4: Cell-Based Architecture (Long-Term)**

For the largest deployments, we partition tenants into **cells** — independent infrastructure stacks (Postgres cluster + ES cluster + Kafka cluster + app servers) serving a subset of tenants.

```
Cell A: tenants 1–5000      (standard tier)
Cell B: tenants 5001–10000  (standard tier)
Cell C: MegaCorp tenant     (dedicated enterprise cell)
Cell D: BigInsurance tenant  (dedicated enterprise cell)
```

The **cell router** (a lightweight reverse proxy) maps `tenant_id` to a cell. Tenant assignment is stored in a global routing table (replicated, cached). Cells are independently deployable and scalable — a failure in Cell A doesn't affect Cell B.

This is not required on day one. We start with a single cell and split when a tenant's resource consumption exceeds a threshold (e.g., >20% of a shared cell's capacity). The cell architecture is designed into the system from the start (tenant routing, connection pool configuration), even if we run on a single cell initially.

### Failure Containment (Limiting the Scope of Impact)

Even within a cell, we need to ensure that one component failing doesn't bring down everything:
- **Automatic failure detection** (circuit breakers) on all cross-service calls (DB, ES, Kafka). If ES error rate exceeds 50% over a 10-second window, the system stops sending queries to ES and falls back to Postgres-backed degraded mode — like a fuse that trips to protect the rest of the system.
- **Separate queues by priority** (sometimes called the "bulkhead pattern"): real-time automation triggers, batch re-indexing, and analytics backfill each get their own queue. A slow analytics backfill cannot block time-sensitive automation triggers because they run in different queues.
- **Graceful degradation**: if ClickHouse is down, dashboards show "data temporarily unavailable" rather than cascading the failure to the API layer. Elasticsearch being down degrades search to Postgres (slower but functional).

When ES becomes unhealthy (error rate > 50% over 10 seconds), a **circuit breaker** activates — the system stops sending queries to ES temporarily, like tripping a fuse to prevent further damage. The query router enters degraded mode. In normal operation, all list/filter/search queries are routed to ES (since ES's inverted indexes serve these more efficiently than Postgres). When ES is unavailable, only a subset can fall back to Postgres:
- **Queries that work in degraded mode**: single-record ID lookups, exact email lookups, `lifecycle_status` filters with sorts by `created_at`/`updated_at` — these map to indexed Postgres queries within the P95 budget (< 500ms for most tenants).
- **Queries that return 503**: full-text search, association-based filters, custom field range queries, faceted counts. These would require expensive Postgres JOINs and sequential scans. The API returns `503 Service Degraded` with a `Retry-After: 60` header and a body explaining which query types are unsupported in degraded mode.
- **UI behavior**: The frontend detects the `metadata.source: "database"` flag and shows a banner: "Search is running in limited mode. Some filters are temporarily unavailable."

### Cell Migration Runbook

When a tenant outgrows a shared cell (resource consumption >20% of the cell) or upgrades to enterprise tier, we migrate them to a dedicated cell. This is one of the highest-risk operations in the platform — it moves a live tenant's data across independent infrastructure stacks without data loss or extended downtime. The procedure below is a step-by-step runbook with timing estimates based on a reference tenant of 50M contacts, 10M opportunities, 500M activities, and 2B change log entries.

**Pre-Migration (T-7 days to T-1 day)**

| Step | Action | Duration | Owner |
|---|---|---|---|
| 1 | **Provision target cell.** Spin up the full infrastructure stack (Postgres, ES, ClickHouse, Kafka, Redis, app servers) in the target cell. Run smoke tests against empty cell. | 2–4 hours | Infrastructure |
| 2 | **Capacity validation.** Estimate tenant data volume from source cell's `pg_total_relation_size` and ES `_cat/indices`. Verify target cell has ≥2x headroom for initial sync + ongoing writes. | 30 min | SRE |
| 3 | **Create logical replication slot.** On the source Postgres, create a replication slot for the tenant's data. This anchors the WAL position so no changes are lost during the migration. | 5 min | DBA |
| 4 | **Notify tenant.** Send a maintenance window notification (72h advance). Enterprise SLA requires pre-agreed maintenance windows. | — | Account team |

**Phase 1: Bulk Data Copy (T-1 day, ~6–14 hours)**

| Step | Action | Duration | Notes |
|---|---|---|---|
| 5 | **Postgres bulk copy.** Run a parallel `COPY` extraction from source, filtered by `tenant_id`, piped into target via `pg_dump --data-only` with tenant filter. Process tables in dependency order: `tenants` → `pipelines` → `contacts` → `companies` → `opportunities` → `custom_object_types` → `custom_object_records` → `activities` → `relationships` → `change_log`. 8 parallel workers, 10K rows per batch. | **6–10 hours** for 50M contacts + related tables | Runs on read replica to avoid source cell impact. Throttled to 50% of replica I/O budget. |
| 6 | **Verify row counts.** Compare `SELECT count(*) WHERE tenant_id = $1` on source vs target for each table. Mismatch > 0 is a stop condition. | 15 min | Automated verification script |
| 7 | **Build target indexes.** Create all indexes on target cell's Postgres (indexes are not copied with data). Run `ANALYZE` on all target tables. | **1–2 hours** | Parallel index builds across partitions |
| 8 | **Backfill ES on target cell.** Start CDC consumers on the target cell pointing at target Postgres. Trigger a full re-index for the tenant. | **2–3 hours** (8 parallel consumers, ~50K docs/min) | ES is rebuildable; no need for bulk copy |
| 9 | **Backfill ClickHouse on target cell.** Batch-insert from target Postgres into target ClickHouse via the CDC loader. | **1–2 hours** | Analytics data tolerates lag |

**Phase 2: Incremental Catch-Up (T-0, ~15–30 minutes)**

| Step | Action | Duration | Notes |
|---|---|---|---|
| 10 | **Start incremental replication.** Consume the logical replication slot created in step 3. Apply all WAL changes for `tenant_id` from the slot's anchored position to the target Postgres. This catches up all writes that occurred during the bulk copy. | **10–20 min** depending on write volume during copy | Filter replication stream by `tenant_id` to avoid cross-tenant data |
| 11 | **Verify incremental sync.** Compare `max(updated_at)` per table between source and target. Delta must be < 5 seconds. | 5 min | Automated |

**Phase 3: Cutover (T-0, ~2–5 minutes of downtime)**

| Step | Action | Duration | Notes |
|---|---|---|---|
| 12 | **Enable maintenance mode for tenant.** The cell router returns `503 Service Unavailable` with `Retry-After: 300` for all requests from this tenant. Queued writes are buffered at the API gateway (up to 30s). | **Instant** | Tenant-scoped; other tenants on source cell are unaffected |
| 13 | **Drain in-flight requests.** Wait for all active transactions for this tenant to complete on the source cell. | **10–30 seconds** | Monitor `pg_stat_activity` for tenant's queries |
| 14 | **Final incremental sync.** Replay any remaining WAL entries accumulated during the drain. | **5–15 seconds** | Should be near-zero entries |
| 15 | **Verify final consistency.** Checksum comparison: hash a random sample of 10K records on source and target. All must match. | **30 seconds** | Stop condition if any mismatch |
| 16 | **Update global routing table.** Atomically update the cell router's tenant→cell mapping: `tenant_abc123 → cell_target`. The routing table is replicated to all cell routers via Redis pub/sub. | **< 1 second** | All subsequent requests route to target cell |
| 17 | **Disable maintenance mode.** Resume serving requests for the tenant from the target cell. Buffered requests at the API gateway are replayed. | **Instant** | |

**Total tenant-visible downtime: 2–5 minutes** (steps 12–17).

**Phase 4: Validation & Cleanup (T+0 to T+7 days)**

| Step | Action | Duration | Notes |
|---|---|---|---|
| 18 | **Monitor target cell.** Watch SLO dashboards, error rates, CDC lag, and ES index freshness for the migrated tenant for 24 hours. | 24 hours | On-call watches for anomalies |
| 19 | **Warm caches.** Target cell's Redis and local caches are cold. First few minutes of traffic will have elevated latency (~2x) as caches warm. Pre-warm tenant metadata and field schemas via a synthetic read sweep. | 10 min | Run immediately after step 17 |
| 20 | **Disable source replication slot.** Drop the logical replication slot on the source cell to stop WAL retention. | 1 min | Failing to do this causes WAL bloat on source |
| 21 | **Retain source data (7-day soak).** Keep the tenant's data on the source cell for 7 days as a rollback safety net. | 7 days | If target cell has issues, re-point routing table back to source |
| 22 | **Purge source data.** After the 7-day soak with no issues, delete the tenant's data from the source cell via background purge job (tenant-scoped batches, throttled). | 2–4 hours | Frees capacity on source cell |

**Rollback Procedure (at any point before step 20):**

1. Re-point the global routing table back to the source cell.
2. Disable maintenance mode on source cell.
3. Drop the target cell's data (or retain for debugging).
4. The logical replication slot on source ensures no WAL data was lost.

Rollback time: < 1 minute (routing table update + maintenance mode toggle).

**Key Invariants During Migration:**

- **Zero data loss.** The logical replication slot anchors the WAL position. Every write to the source is captured and replayed on the target.
- **Tenant isolation preserved.** The replication stream is filtered by `tenant_id`. No other tenant's data touches the target cell.
- **Minimal scope of impact.** The cutover affects only the migrating tenant. Other tenants on the source cell experience zero impact.
- **Reversible until cleanup.** The 7-day soak period with source data retained means rollback is always available.

---

## 3. Microservice Decomposition

### Service Boundaries

The system is decomposed into **9 services**, split by data ownership and scaling needs — not by entity type. A dedicated **CRM Gateway** service orchestrates multi-service flows (resolve tenant → query search → enrich from Postgres → post-filter). This keeps downstream services single-purpose: the Search Service is a pure ES query engine (no Postgres knowledge), and the Core CRM Service is a pure Postgres CRUD layer (no ES knowledge).

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                             API Gateway                                      │
│                   Auth + Rate Limit + Resolve tenant_id + roles              │
└─────────────────────────────────┬────────────────────────────────────────────┘
                                  │  ALL requests
                                  ▼
                        ┌──────────────────┐
                        │   CRM Gateway    │
                        │   (Orchestrator) │
                        │                  │
                        │ Coordinates:     │
                        │ 1. Tenant lookup │
                        │ 2. Route to svc  │
                        │ 3. Enrich IDs    │
                        │ 4. Post-filter   │
                        │ 5. Return resp   │
                        └────────┬─────────┘
                                 │ calls downstream services
        ┌────────┬───────────┬───┴───┬───────────┬──────────┐
        ▼        ▼           ▼       ▼           ▼          ▼
  ┌──────────┐ ┌────────┐ ┌────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
  │ Tenant   │ │ Core   │ │ Search │ │Analytics │ │Import/   │ │ Webhook  │
  │ Service  │ │ CRM    │ │Service │ │ Service  │ │Export    │ │ Service  │
  │          │ │Service │ │(pure ES│ │          │ │ Service  │ │          │
  │partition │ │(pure PG│ │ query) │ │          │ │          │ │          │
  │ + config │ │ CRUD)  │ │        │ │          │ │          │ │          │
  └──────────┘ └────────┘ └────────┘ └──────────┘ └──────────┘ └──────────┘

                              Kafka (CDC)
  ┌──────────────────────────────┼───────────────────────────────┐
  │                              │                               │
  ▼                              ▼                               ▼
  ┌──────────┐            ┌──────────┐                    ┌──────────┐
  │Automation│            │ ES Index │                    │  Dedup   │
  │ Service  │            │ Worker   │                    │ Service  │
  │          │            │(Search)  │                    │          │
  └──────────┘            └──────────┘                    └──────────┘
  Async (Events)          Async (Events)                  Async (Events)
```

### Service Catalog

#### 1. CRM Gateway (Orchestrator)

**Owns:** No database tables. Stateless orchestration layer.

**Responsibilities:**
- Receives all API requests from the API Gateway
- Orchestrates multi-service flows for every read and write operation
- **Read flow (list/search):** Call Tenant Service (get partition_number) → Call Search Service (pass partition_number, get sorted IDs) → Call Core CRM Service (pass IDs, get enriched rows) → Post-filter (verify tenant_id, remove deleted, check RBAC) → Return response
- **Write flow (CRUD):** Call Tenant Service (get partition_number, scoring_rules, field_schema) → Call Core CRM Service (pass tenant metadata + request body) → Return response
- **Direct reads (by ID, timeline):** Call Core CRM Service directly (no Search Service involved)
- **Dashboards:** Call Analytics Service directly
- Idempotency check (Redis SET NX for Idempotency-Key header)
- Degraded mode decision: when Search Service reports ES is down, fall back to Core CRM for basic queries

**Scaling:** Stateless, horizontally scaled. CPU-bound (request parsing, post-filter logic, response assembly). Scales with total API request volume.

**Why this is a separate service:** Without it, the Search Service would need to know about Postgres (to enrich IDs) and the Core CRM Service would need to know about ES (to route queries). The CRM Gateway keeps each downstream service single-purpose. It also centralizes cross-cutting concerns: idempotency, post-filtering, RBAC enforcement, and degraded-mode fallback.

**API surface (external — all user-facing endpoints):**
```
POST/GET/PATCH/DELETE  /v1/crm/objects/{object_type}
POST/GET/PATCH/DELETE  /v1/crm/objects/{object_type}/{id}
POST                   /v1/crm/objects/{object_type}/batch
POST                   /v1/crm/objects/{object_type}/search
POST/GET               /v1/crm/objects/{object_type}/{id}/activities
GET                    /v1/crm/analytics/*
POST/GET               /v1/crm/imports, /v1/crm/exports/*
PUT/GET/DELETE         /v1/crm/tenant/scoring-rules/{entity_type}
POST/GET/PATCH/DELETE  /v1/crm/automation-rules
POST/GET/PATCH/DELETE  /v1/crm/webhook-subscriptions
```

**Internal calls (to downstream services):**
```
→ Tenant Service:    GET  /internal/tenant/{id}
→ Search Service:    POST /internal/search/{object_type}
→ Core CRM Service:  POST /internal/crm/enrich
                     POST /internal/crm/objects/{object_type}
                     GET  /internal/crm/objects/{object_type}/{id}
→ Analytics Service: GET  /internal/analytics/*
→ Import/Export:     POST /internal/imports, GET /internal/exports/*
```

---

#### 2. Tenant Service

**Owns:** `tenants`, `scoring_rules`

**Responsibilities:**
- Tenant CRUD (create, update plan tier, configure settings)
- Scoring rule management (`PUT /v1/crm/tenant/scoring-rules/{entity_type}`)
- Cell routing table (maps `tenant_id → cell_id` for multi-cell deployments)
- `partition_number` assignment on tenant creation

**Scaling:** Low traffic (tenant config changes rarely). 2 replicas behind load balancer. Redis cache absorbs 99% of reads (tenant metadata cached 5 min).

**Why separate:** Tenant metadata is read on every single API request (for auth, rate limits, scoring rule lookup). It must be highly available and independently deployable. Changes to tenant configuration (plan tier upgrade, scoring rule change) should not require deploying the Core CRM Service.

---

#### 2. Core CRM Service

**Owns:** `contacts`, `companies`, `opportunities`, `pipelines`, `custom_object_types`, `custom_object_type_versions`, `custom_object_records`, `relationships`, `activities`, `change_log`, `merge_suggestions`

**Responsibilities:**
- All CRUD for core entities + custom objects + activities + relationships
- Lifecycle state machine enforcement (active → archived → deleted → purged)
- Merge execution (contact dedup merges)
- Field validation against `field_schema`
- `custom_score` computation on every write (reads scoring rule from cache)
- Change log recording
- Serves Postgres PK batch lookups for the Search Service enrichment step

**Database:** PostgreSQL (source of truth, 64 hash partitions, RLS enforced)

**Scaling:** This is the highest-traffic service. Horizontally scaled behind load balancer. Each instance is stateless — tenant context set via `SET LOCAL` per transaction. Connection pooling via PgBouncer.

**Why this big:** Contacts, companies, opportunities, and relationships are queried and written together in the same transaction (e.g., "create contact + link to company + log activity"). Splitting them into separate services would require distributed transactions or eventual consistency for operations that users expect to be atomic.

**API surface:**
```
POST/GET/PATCH/DELETE  /v1/crm/objects/{object_type}
POST/GET/PATCH/DELETE  /v1/crm/objects/{object_type}/{id}
POST                   /v1/crm/objects/{object_type}/batch
POST/GET               /v1/crm/objects/{object_type}/{id}/activities
Internal:
POST                   /internal/crm/enrich    (batch PK lookup for Search Service)
```

---

#### 3. Search Service (Pure ES Query — No Postgres Knowledge)

**Owns:** Elasticsearch per-partition indexes (`crm_contacts_p00..p63`, `crm_opportunities_p00..p63`), ES Index Worker (Kafka consumer), Cascade Worker

**Responsibilities:**
- Receive a `partition_number` + API-level filters + sort + limit from the CRM Gateway
- **Query translation layer:** translate API field names and operators into ES-internal field names and query types. The CRM Gateway (and API consumers) have no knowledge of ES internals. Examples:
  - `properties.email contains "@acme.com"` → rewritten to `term` query on internal `email_domain` field (extracted at index time)
  - `association.opportunity.count >= 3` → rewritten to `range` query on internal `opportunity_stats.open_count` (pre-computed)
  - `properties.first_name contains "jan"` → rewritten to `match` query on internal `full_name` (combined field)
  - `custom_properties.region eq "Northeast"` → translated to `term` on internal `custom_fields.region` (flattened type)
- Query the correct per-partition ES index (`crm_contacts_p{NN}`)
- Return sorted IDs + total count + faceted counts
- ES index maintenance: consume CDC events from Kafka, build/update thin documents, cascade updates on company/opportunity changes
- If ES schema changes (field renamed, denormalization strategy changed, switch to a different search engine), only this service's translation layer is updated — no API contract change, no CRM Gateway change

**What this service does NOT do** (handled by CRM Gateway instead):
- Does NOT call Core CRM Service for enrichment (CRM Gateway does this)
- Does NOT post-filter results (CRM Gateway does this)
- Does NOT make degraded-mode decisions (CRM Gateway does this)
- Does NOT call Tenant Service for partition_number on the read path (CRM Gateway passes it)

**Note:** The ES Index Worker (CDC consumer) does call Tenant Service for `partition_number` — because it runs asynchronously and doesn't go through the CRM Gateway.

**Scaling:** Network-bound (ES queries). Scale independently based on search QPS. ES Index Worker scales by Kafka consumer count (up to 32 per topic, one per partition).

**Why separate:** The Search Service is a pure query engine — it takes a partition number and filters, returns IDs. No business logic, no Postgres coupling, no orchestration. This makes it independently testable, deployable, and scalable.

**API surface (internal only — called by CRM Gateway):**
```
POST  /internal/search/{object_type}   (partition_number + filters + sort + limit → sorted IDs)
GET   /internal/search/{object_type}/count  (exact count)
```

**Internal communication:**
```
CRM Gateway → Search Service:  POST /internal/search/{object_type}
ES Index Worker → Tenant Service:  GET /internal/tenant/{id} (partition_number for CDC indexing)
Kafka → Search Service:  CDC events → ES Index Worker + Cascade Worker
```

---

#### 4. Automation Service

**Owns:** `automation_rules`, `automation_execution_log`

**Responsibilities:**
- Automation rule CRUD (create, update, enable/disable rules)
- CDC event consumption: evaluate field-change and activity-based triggers
- Idempotent execution via `execution_key` unique constraint
- Action dispatch: call Core CRM Service (create activity, update field), call Webhook Service (send webhook), call external email service
- Snapshot semantics: all rules evaluate against the original CDC event

**Scaling:** Event-driven. Scales by Kafka consumer count. Stateless evaluation (rules cached in memory, 30s TTL). Independent of API traffic — scales based on write volume (CDC event rate).

**Why separate:** Automation evaluation is a hot-path Kafka consumer. It must process events within 2 seconds. If bundled with the Core CRM Service, a spike in API traffic would compete with trigger evaluation for CPU and connections. Separate deployment = independent scaling and failure isolation.

**API surface:**
```
POST/GET/PATCH/DELETE  /v1/crm/automation-rules
GET                    /v1/crm/automation-rules/{id}/executions
```

**Internal communication:**
```
Kafka → Automation Service:          CDC events (all entity topics)
Automation Service → Core CRM:       POST /internal/crm/objects/{type} (create activity, update field)
Automation Service → Webhook Service: POST /internal/webhooks/deliver  (trigger webhook action)
```

---

#### 5. Webhook Service

**Owns:** `webhook_subscriptions`, `webhook_delivery_log`

**Responsibilities:**
- Webhook subscription CRUD (register/update/delete endpoints)
- Event consumption from Kafka: match events to subscriptions
- HTTP delivery with retry (1s, 5s, 30s, 2min, 10min backoff)
- HMAC-SHA256 payload signing
- Circuit breaker management (closed → open → half_open per endpoint)
- Rate limiting per endpoint (max deliveries/sec)
- Dead-letter handling for persistently failing deliveries

**Scaling:** Network I/O-bound (HTTP calls to external endpoints). Scales independently — a tenant with 100 webhook subscriptions needs more delivery capacity than a tenant with 1. Consumer count scales with event volume.

**Why separate:** Webhook delivery is network-bound with unpredictable latency (external endpoints may be slow). It must not block or slow down any other service. Circuit breaker state management is complex enough to warrant its own deployment.

**API surface:**
```
POST/GET/PATCH/DELETE  /v1/crm/webhook-subscriptions
GET                    /v1/crm/webhook-subscriptions/{id}/deliveries
```

---

#### 6. Analytics Service

**Owns:** ClickHouse tables (`crm_contacts`, `crm_opportunities`, `crm_activities`, `crm_change_events`, `mv_pipeline_value_by_stage`), CH Loader (Kafka consumer)

**Responsibilities:**
- Dashboard queries (pipeline value by stage, win rate trends, cohort analysis)
- Funnel reporting (opportunity stage progression)
- ML feature extraction (contact engagement scoring)
- CH Loader: consume CDC events, batch-insert into ClickHouse

**Scaling:** Read-heavy (dashboard queries are columnar scans). ClickHouse scales by adding nodes. CH Loader scales by Kafka consumer count. Independent of API write traffic.

**Why separate:** Analytics workload (columnar scans over billions of rows) is fundamentally different from OLTP. ClickHouse needs its own resource management (memory for large GROUP BYs), and a slow dashboard query should never affect CRUD latency.

**API surface:**
```
GET  /v1/crm/analytics/pipeline-summary
GET  /v1/crm/analytics/funnel/{pipeline_id}
GET  /v1/crm/analytics/cohort
POST /v1/crm/analytics/query   (ad-hoc analytics with tenant filter)
```

---

#### 7. Import/Export Service

**Owns:** No database tables (stateless workers). Uses S3 for file storage.

**Responsibilities:**
- Bulk import: parse CSV/NDJSON, validate against field schema, dedup, batch-write to Core CRM Service
- Bulk export: read from Core CRM Service (small exports) or ClickHouse (large exports), stream as NDJSON or write to S3
- Job tracking: progress, error reports, download URLs

**Scaling:** CPU-bound (parsing/validation) + I/O-bound (reading large files). Scales by job worker count. Long-running jobs (10M-row import) need their own compute — must not consume API serving capacity.

**Why separate:** Imports are long-running (minutes to hours), resource-intensive (parsing, validation, batching), and bursty (a tenant imports 5M contacts once, then not again for months). Running this on API servers would steal capacity from interactive requests.

**API surface:**
```
POST  /v1/crm/imports                    (start import job)
GET   /v1/crm/imports/{job_id}           (check progress)
GET   /v1/crm/objects/{type}/export      (start export)
GET   /v1/crm/exports/{export_id}        (check export status, download URL)
```

**Internal communication:**
```
Import Service → Core CRM Service:  POST /v1/crm/objects/{type}/batch  (bulk writes)
Export Service → Core CRM Service:  GET  /internal/crm/export-scan     (cursor-based read)
Export Service → Analytics Service:  GET  /internal/analytics/export    (large exports from CH)
```

---

#### 8. Dedup Service

**Owns:** `merge_suggestions` (operationally, though table lives in Core CRM's database)

**Responsibilities:**
- On-ingestion dedup: when a contact is created, check for duplicates via `pg_trgm` similarity
- Weekly full-tenant scan: compute pairwise similarity in batches
- Surface merge suggestions to UI
- Execute merges via Core CRM Service (re-point relationships, set merged status)

**Scaling:** Background batch workers. Scales by worker count. CPU-intensive (trigram matching). Runs on schedule, not on demand.

**Why separate:** Dedup is a batch process that scans millions of records. It must not run on API servers. The weekly full-tenant scan is resource-intensive and should be scheduled during off-peak hours.

**API surface:**
```
GET   /v1/crm/merge-suggestions                (list pending suggestions)
POST  /v1/crm/merge-suggestions/{id}/accept    (execute merge)
POST  /v1/crm/merge-suggestions/{id}/dismiss   (dismiss suggestion)
```

**Internal communication:**
```
Dedup Service → Core CRM Service:  POST /internal/crm/contacts/merge  (execute merge)
Kafka → Dedup Service:             CDC contact.created events (on-ingestion check)
```

---

### How a List/Search Request Flows Through Services

```
User: "Show all leads in Technology industry, sorted by score"

1. Browser → API Gateway
   - Validates JWT → extracts tenant_id, user_id, roles from the token
     (tenant_id is NEVER supplied by the client — it is resolved server-side
     from the authenticated credential. Any client-supplied X-Tenant-Id header
     is stripped and overwritten. See Part 3, "Tenant Identity" section.)
   - Rate limit check (Redis, keyed by server-resolved tenant_id)
   - Injects internal headers: X-Tenant-Id, X-User-Id, X-User-Roles
   - Routes to CRM Gateway

2. API Gateway → CRM Gateway (Orchestrator)
   - Passes: server-resolved tenant_id, user_id, roles, filters, sort, pagination

3. CRM Gateway → Tenant Service
   GET /internal/tenant/{tenant_id}
   ← Returns: { partition_number: 7, plan_tier: "professional", ... }

4. CRM Gateway → Search Service
   POST /internal/search/contact
   { partition_number: 7, plan_tier: "professional",
     filters: [lifecycle_stage=lead, company_industries=Technology],
     sort: custom_score DESC, limit: 50 }
   
   Search Service internally queries: GET crm_contacts_p07/_search
   ← Returns: { ids: [id_1, id_2, ..., id_50], total: 2340 }

5. CRM Gateway → Core CRM Service
   POST /internal/crm/enrich
   { tenant_id: "...", ids: [id_1, ..., id_50] }
   
   Core CRM Service internally runs: SELECT * FROM contacts
     WHERE tenant_id=$1 AND id=ANY($2) ORDER BY array_position($2, id)
   ← Returns: 50 full contact rows from Postgres

6. CRM Gateway: Post-Filter
   - Verify each row's tenant_id matches (ES eventual consistency guard)
   - Remove any deleted/merged records (deleted after ES indexed them)
   - Remove records the user isn't authorized to see (RBAC check using roles —
     see README "Deliberate Scope Exclusions" for why RBAC is out of scope in
     this iteration; the post-filter slot is reserved for it)
   - 48 records pass (2 were deleted since ES indexed them)

7. CRM Gateway → Browser
   { data: [48 contacts], paging: {has_more: true},
     metadata: {source: "search_index+database"} }
```

### How a Write Request Flows Through Services

```
User: "Create a contact and link to BigCorp company"

1. Browser → API Gateway (validates JWT, resolves tenant_id server-side)
      → CRM Gateway (Orchestrator)
   POST /v1/crm/objects/contact
   { properties: {email: "jane@bigcorp.com", ...},
     associations: [{target_type: "company", target_id: "comp_123"}] }

2. CRM Gateway → Tenant Service
   GET /internal/tenant/{tenant_id}
   ← Returns: { partition_number: 7, scoring_rules: {...}, field_schema: [...] }

3. CRM Gateway → Core CRM Service
   POST /internal/crm/objects/contact
   { tenant_metadata: { partition_number: 7, scoring_rules: {...}, field_schema: [...] },
     body: { properties: {...}, associations: [...] } }

4. Core CRM Service:
   - Validate fields against field_schema
   - Compute custom_score from scoring_rules
   - BEGIN transaction (SET LOCAL app.current_tenant)
   - INSERT INTO contacts (...)
   - INSERT INTO relationships (...)
   - INSERT INTO change_log (...)
   - COMMIT
   ← Returns: full contact with associations

5. CRM Gateway → Browser
   { data: { id: "cont_jane456", ... }, created_at: "..." }

6. Postgres WAL → Debezium → Kafka (async, after response sent)
   Events published to: cdc.crm.contacts, cdc.crm.relationships, cdc.crm.change_log

7. Kafka consumers (async, independent):
   - Search Service (ES Index Worker): calls Tenant Service for partition_number
     → builds thin ES doc → PUT crm_contacts_p07/_doc/{id}
   - Analytics Service (CH Loader): batch-inserts into ClickHouse
   - Automation Service: evaluates trigger rules → creates follow-up task if rule matches
   - Dedup Service: checks for duplicate contacts by email/name
   - Webhook Service: delivers "contact.created" to subscribed endpoints
```

### Data Ownership Map

| Table | Owning Service | Other Services That Read |
|---|---|---|
| (no tables) | CRM Gateway | Stateless — orchestrates calls to other services |
| `tenants` | Tenant Service | CRM Gateway (via Tenant Service API), all async consumers |
| `scoring_rules` | Tenant Service | Core CRM (passed by CRM Gateway on write) |
| `contacts` | Core CRM Service | CRM Gateway (PK enrichment via Core CRM API), Dedup (trigram scan) |
| `companies` | Core CRM Service | CRM Gateway (PK enrichment via Core CRM API) |
| `opportunities` | Core CRM Service | CRM Gateway (PK enrichment via Core CRM API) |
| `pipelines` | Core CRM Service | CRM Gateway (stage name resolution via Core CRM API) |
| `custom_object_types` | Core CRM Service | All (via cache, for validation) |
| `custom_object_type_versions` | Core CRM Service | — |
| `custom_object_records` | Core CRM Service | Search (PK enrichment) |
| `relationships` | Core CRM Service | Search (ES cascade worker) |
| `activities` | Core CRM Service | — |
| `change_log` | Core CRM Service | — |
| `merge_suggestions` | Dedup Service | Core CRM (merge execution) |
| `automation_rules` | Automation Service | — |
| `automation_execution_log` | Automation Service | — |
| `webhook_subscriptions` | Webhook Service | — |
| `webhook_delivery_log` | Webhook Service | — |
| ES indexes (`crm_contacts_p*`) | Search Service | — |
| ES indexes (`crm_opportunities_p*`) | Search Service | — |
| ClickHouse tables | Analytics Service | Import/Export (large exports) |

### Inter-Service Communication

| From | To | Method | Why |
|---|---|---|---|
| **CRM Gateway → Tenant Service** | Sync (internal HTTP) | Get partition_number, plan_tier, scoring_rules, field_schema — on every request |
| **CRM Gateway → Search Service** | Sync (internal HTTP) | Pass partition_number + filters → get sorted IDs |
| **CRM Gateway → Core CRM Service** | Sync (internal HTTP) | Enrich IDs (batch PK lookup), CRUD writes, timeline queries |
| **CRM Gateway → Analytics Service** | Sync (internal HTTP) | Dashboard queries |
| **CRM Gateway → Import/Export** | Sync (internal HTTP) | Start/track import/export jobs |
| CRM Gateway → Webhook Service | Sync (internal HTTP) | Webhook subscription management |
| Automation → Core CRM (via CRM Gateway) | Sync (internal HTTP) | Execute actions (create activity, update field) |
| Automation → Webhook | Sync (internal HTTP) | Trigger webhook delivery as an automation action |
| Webhook → external | Async (HTTP with retry) | Deliver events to customer endpoints |
| Import → Core CRM (via CRM Gateway) | Sync (internal HTTP) | Batch writes |
| Dedup → Core CRM (via CRM Gateway) | Sync (internal HTTP) | Execute contact merges |
| ES Index Worker → Tenant Service | Sync (internal HTTP) | Get partition_number for CDC indexing |
| CDC (Kafka) → Search (ES Index Worker) | Async (event) | ES index updates |
| CDC (Kafka) → Analytics (CH Loader) | Async (event) | ClickHouse loading |
| CDC (Kafka) → Automation | Async (event) | Trigger evaluation |
| CDC (Kafka) → Webhook | Async (event) | Event matching + delivery |
| CDC (Kafka) → Dedup | Async (event) | On-ingestion duplicate check |

### Why Not More Services? Why Not Fewer?

**Why does the CRM Gateway exist? Why not have the API Gateway call services directly?**
A list/search request requires 3 sequential calls (Tenant → Search → Core CRM) plus post-filtering. Embedding this orchestration in the API Gateway would make the gateway stateful and business-logic-aware. Embedding it in the Search Service would couple ES query logic with Postgres enrichment and RBAC checks. The CRM Gateway keeps each downstream service single-purpose: Search Service is a pure ES query engine, Core CRM Service is a pure Postgres CRUD layer, Tenant Service is a pure config provider. The Gateway owns the composition.

**Why not split Core CRM further (Contact Service, Opportunity Service, etc.)?**
Creating a contact linked to a company requires writing to `contacts`, `relationships`, and `change_log` in one transaction. With separate services, this becomes a distributed transaction (2PC or saga pattern) — dramatically more complex, slower, and harder to debug. The entities change together, so they belong together.

**Why not merge Search into Core CRM?**
Search talks to Elasticsearch, a completely different infrastructure component. When ES is down, the CRM Gateway falls back to Core CRM for basic queries — but Core CRM continues serving writes and PK lookups normally. Different failure modes = different services. Also, the ES Index Worker (Kafka consumer) scales based on CDC event rate, not API request rate.

**Why not merge Automation into Core CRM?**
Automation evaluation is a Kafka consumer running at 70K events/sec. It must scale independently of API traffic. A traffic spike in the API shouldn't slow down trigger evaluation, and vice versa.

**Why not merge Webhook into Automation?**
Webhook delivery is network I/O-bound (calling external endpoints with unpredictable latency). Automation is CPU-bound (rule evaluation in memory). They have opposite scaling profiles. Also, webhooks can be triggered by API calls too (not just automations), so they're a separate concern.

---

## 4. Tenant Onboarding & Live Partition Migration

### Capacity-Based Partition Assignment

When a new tenant signs up, the Tenant Service assigns a `partition_number` based on current load — not a hash function. This gives full control over which tenants share infrastructure.

**What the tenant provides at signup:**

```json
POST /v1/crm/tenants
{
  "name": "Acme Insurance",
  "plan_tier": "professional",
  "capacity_estimate": {
    "contacts": 5000000,
    "companies": 200000,
    "opportunities": 500000,
    "activities_per_contact": 8
  }
}
```

**Weight calculation:**

The weight formula is **configurable at the system level**, not hardcoded. Different deployments have different data shapes — one platform may be activity-heavy (call center CRM), another may be opportunity-heavy (enterprise sales). The multipliers are stored in a system config (e.g., environment variable or a `system_config` table) and can be tuned without a code deploy.

**Default formula (example — multipliers are configurable):**

```
weight = contacts × W_CONTACT
       + companies × W_COMPANY
       + opportunities × W_OPPORTUNITY
       + (contacts × activities_per_contact) × W_ACTIVITY

Default multipliers (configurable per deployment):
  W_CONTACT     = 1.0    (base unit)
  W_COMPANY     = 2.0    (larger rows, more custom fields)
  W_OPPORTUNITY = 1.5    (medium rows + pipeline joins)
  W_ACTIVITY    = 0.5    (smaller rows, append-only)

Acme example with defaults: (5M × 1) + (200K × 2) + (500K × 1.5) + (5M × 8 × 0.5) = 26.15M weight units
```

The multipliers reflect relative storage and query cost per entity type. A deployment where activities dominate (e.g., 50 activities per contact) would increase `W_ACTIVITY` to 0.8; a deployment where opportunities are complex (large `custom_fields` JSONB, many pipeline stages) would increase `W_OPPORTUNITY` to 2.0. The `actual_weight` column on the `tenants` table is recomputed nightly using the current multipliers and real row counts — so changing the multipliers automatically rebalances partition load calculations.

**Assignment rules:**

| Plan Tier | Weight | Assignment |
|---|---|---|
| Standard / Professional | Any | Least-loaded shared partition (0-59) where `current_weight + new_weight < 150M` |
| Enterprise | ≤ 50M | Least-loaded shared partition (same rule) |
| Enterprise | > 50M | Dedicated partition (60-63) — one tenant per partition |
| Any | > 200M (actual, post-growth) | Dedicated cell (separate infrastructure) |

The Tenant Service queries `SELECT partition_number, sum(actual_weight) FROM tenants GROUP BY partition_number` and picks the partition with the most headroom. The assignment is stored on the `tenants` row and cached in Redis (5-min TTL). All downstream services (CRM Gateway, Search Service, ES Index Worker) read this value to route data.

### Live Partition Migration (Zero-Downtime Tenant Move)

When a partition becomes too hot (too much data, too many writes, vacuum taking too long), the Tenant Service moves a tenant from one partition to another. The migration happens live — the tenant's users experience ~2-5 seconds of read pause during cutover, and writes are never interrupted.

**When to migrate:**

| Signal | Action |
|---|---|
| Partition actual_weight > 100M (soft limit) | Alert operations team, suggest migration for the largest tenant |
| Partition actual_weight > 150M (hard limit) | Auto-queue migration |
| Tenant actual_weight crosses 50M | Consider promotion to dedicated partition (60-63) |
| Dedicated partition crosses 200M | Consider dedicated cell |

**The migration has 5 phases and 12 steps:**

**Phase 1: Preparation (T-1 day)**

| Step | Action | Duration |
|---|---|---|
| 1 | Validate target partition has capacity: `current_weight + tenant_weight < 150M` | 1 min |
| 2 | Create migration record: `INSERT INTO tenant_migrations (status='pending')` | Instant |

**Phase 2: Dual-Write (T-0, zero user impact)**

| Step | Action | Duration | Details |
|---|---|---|---|
| 3 | Set migration status to `dual_writing` | Instant | CRM Gateway detects this (5s cache TTL) |
| | **From this point:** every write for this tenant goes to BOTH old and new partition | | CRM Gateway writes: `INSERT INTO contacts (partition_number=7, ...)` AND `INSERT INTO contacts (partition_number=34, ...)` in one transaction. ES Index Worker writes to both `crm_contacts_p07` and `crm_contacts_p34`. Reads still come from old partition (consistent). |

**Phase 3: Backfill Historical Data (T-0, ~1-4 hours, zero user impact)**

| Step | Action | Duration | Details |
|---|---|---|---|
| 4 | Copy all tenant data from old partition to new partition, table by table, in batches of 5K rows | 1-4 hours | `INSERT INTO contacts (partition_number=34, ...) SELECT 34, tenant_id, id, ... FROM contacts WHERE partition_number=7 AND tenant_id=$1 AND id > $cursor LIMIT 5000 ON CONFLICT DO NOTHING` — ON CONFLICT handles rows already created by dual-write. Throttled: 50ms pause between batches. |
| 5 | Backfill ES index: re-index tenant's data from new Postgres partition into new ES index | 1-2 hours | 8 parallel workers, ~50K docs/min. Dual-write handles new data during backfill. |
| 6 | Verify row counts match between old and new partition for this tenant | 15 min | `SELECT count(*) FROM contacts WHERE partition_number=7 AND tenant_id=$1` vs `partition_number=34`. Must match. |

**Phase 4: Cutover (~2-5 seconds of read pause)**

| Step | Action | Duration | Details |
|---|---|---|---|
| 7 | Set migration status to `cutting_over` | Instant | CRM Gateway: writes still dual-write, reads return 503 with `Retry-After: 5` |
| 8 | Final consistency check: compare `max(updated_at)` between partitions | 1-2 sec | Must match within 1 second |
| 9 | Switch partition: `UPDATE tenants SET partition_number = 34 WHERE id = $1` + invalidate Redis cache | < 1 sec | From this instant, all services read partition_number = 34 |
| 10 | Set migration status to `completed` | Instant | CRM Gateway: reads and writes go to partition 34 only. Dual-write stops. |

**Total user-visible disruption: ~2-5 seconds of "loading" on reads (Steps 7-10). Writes are never paused.**

**Phase 5: Cleanup (T+7 days)**

| Step | Action | Duration | Details |
|---|---|---|---|
| 11 | Keep tenant data in old partition for 7 days as rollback safety net | 7 days | If anything goes wrong, revert: `UPDATE tenants SET partition_number = 7` |
| 12 | After 7-day soak: delete tenant data from old partition + old ES index | 2-4 hours | Batched deletes, throttled. `DELETE FROM contacts WHERE partition_number=7 AND tenant_id=$1 LIMIT 5000` in a loop. Remove docs from `crm_contacts_p07`. |

**Rollback (at any point before Step 12):**

```
1. UPDATE tenants SET partition_number = 7 WHERE id = $1;  (revert to old partition)
2. DEL tenant:{tenant_id} from Redis                        (invalidate cache)
3. UPDATE tenant_migrations SET status = 'rolled_back';
4. Delete tenant data from new partition (34) — cleanup
Time: < 30 seconds. Old partition data is untouched throughout.
```

### How CRM Gateway Handles Migration States

The CRM Gateway checks for active migrations on every request (cached, 5s TTL):

| Migration Status | Writes | Reads |
|---|---|---|
| No migration | → old partition | → Search Service (old ES index) → Core CRM (old partition) |
| `dual_writing` | → BOTH old + new partition | → Search Service (old ES index) → Core CRM (old partition) |
| `backfilling` | → BOTH old + new partition | → Search Service (old ES index) → Core CRM (old partition) |
| `cutting_over` | → BOTH old + new partition | → 503 Retry-After: 5 (brief pause) |
| `completed` | → new partition only | → Search Service (new ES index) → Core CRM (new partition) |

---

## 5. Disaster Recovery & Backup

A CRM platform holding billions of business-critical records needs recovery guarantees that are concrete, tested, and contractual — not aspirational.

**RPO/RTO targets.** Enterprise-tier tenants have contractual guarantees: RPO = 1 minute (maximum data loss in a disaster) and RTO = 15 minutes (maximum time to restore service). Standard-tier tenants operate under relaxed targets: RPO = 1 hour, RTO = 4 hours. These numbers drive every backup and replication decision below.

**Postgres backup.** Postgres records every change in a Write-Ahead Log (WAL) — a sequential file of "what changed" that the database writes before modifying actual data. We ship these WAL files to S3 every 60 seconds. Daily base backups provide a full snapshot. Together, these enable **point-in-time recovery (PITR)** — the ability to restore the database to its exact state at any specific second within the 30-day retention window (e.g., "restore to 2026-04-10 at 14:32:17 UTC"). The critical part: backups are tested monthly via an automated restore-to-staging pipeline that restores the latest backup, runs a validation suite against the restored data, and reports success/failure. Untested backups are not backups.

**Cross-region replication.** A Postgres streaming replica runs in a secondary region with asynchronous replication (~1 second lag). Failover to the secondary region is manual by design — automatic promotion risks a **split-brain scenario** (where both regions think they're the primary and accept writes simultaneously, leading to conflicting data that is nearly impossible to merge back together). Automated promotion tooling exists but requires explicit operator approval via a two-person confirmation flow.

**Elasticsearch.** ES is a derived store — it contains no data that doesn't originate from Postgres via the CDC pipeline. Backup is unnecessary. Recovery means creating a fresh index, pointing the CDC backfill consumers at the appropriate Postgres WAL position, and rebuilding. Time to rebuild: approximately 2 hours for 1 billion records with 8 parallel consumers. This is acceptable because ES being unavailable triggers the degraded-mode fallback described above, not a full outage.

**ClickHouse.** Daily snapshots are taken to S3 via `BACKUP TABLE ... TO S3(...)`. The acceptable RPO for ClickHouse is 24 hours — analytics data already has minutes-level lag tolerance by design, and losing a day of analytics is an inconvenience, not a crisis. Full rebuild from Postgres via the CDC analytics pipeline is always available as a fallback.

**Kafka.** Topic data is retained for 7 days. Kafka itself runs 3-broker clusters with replication factor RF=3, so it survives individual broker failures without data loss. In a full disaster, CDC replay from the Postgres WAL position handles recovery — Kafka is a transport layer, not a source of truth.

**Runbook and testing.** The disaster recovery runbook is tested quarterly via chaos engineering exercises: simulate a region failure, execute the recovery procedure, and measure actual RTO against the target. Results are documented and reviewed. Any exercise that exceeds the RTO target triggers an immediate remediation project.

---

## 4. GDPR, Compliance & Data Governance

A multi-tenant CRM platform stores some of the most regulated data in enterprise software — personal contact information, communication history, deal details. Compliance is not a feature bolted on after launch; it's a constraint that shapes the data model and access patterns from day one.

**Right to Erasure (RTBF).** A tenant or data subject can request full deletion of their data. The implementation is a three-phase process:

1. **Soft-delete** all records for the subject (the contact and all related records — opportunities, activities, notes, relationships). Soft-deleted records are immediately invisible to all API queries and search results.
2. **Queue a hard-purge job** that runs after a 72-hour grace period. This grace period allows the tenant to undo an accidental deletion request — a surprisingly common occurrence.
3. **Hard purge** removes data from Postgres, triggers a re-index to remove the documents from ES, and issues a `DELETE` to ClickHouse (`ALTER TABLE DELETE WHERE`). The `change_log` entries for the deleted subject are anonymized — `entity_id` is replaced with a one-way hash, and `changed_fields` are scrubbed — but the log entries themselves are retained for audit compliance. This satisfies both the right to erasure and the obligation to demonstrate that erasure occurred.

**Data Residency.** Tenants can be assigned to region-specific cells (EU, US, APAC). The cell router enforces that a tenant's data never leaves its assigned region. Postgres, ES, ClickHouse, and Kafka are all deployed per-region. This is not just a configuration flag — it's an architectural invariant enforced at the routing layer. A misconfigured cell assignment that routes an EU tenant's data to a US cell would be a P1 incident.

**Field-level encryption.** Sensitive custom fields (marked `"sensitive": true` in `field_schema`) are encrypted by the Core CRM Service using AES-256-GCM with per-tenant encryption keys stored in a KMS (AWS KMS / GCP KMS). Encrypted fields are stored as ciphertext in the JSONB `custom_fields` column and decrypted on read. The trade-off is explicit: encrypted fields cannot be indexed or searched in ES — they are display-only. This is acceptable for fields like SSN, tax ID, or internal account numbers where searchability is not a valid use case.

**Audit log retention.** The `change_log` is retained for 7 years, the regulatory minimum for financial services tenants. Older partitions are archived to cold storage (S3 Glacier) but remain queryable via Athena/Presto for compliance investigations. Postgres table partitioning by month makes this lifecycle management straightforward — archiving a partition is a metadata operation, not a data migration.

**Consent tracking.** Consent management is not in scope for the data platform layer — it's handled by a dedicated consent service that tracks opt-in/opt-out status, consent timestamps, and consent sources. The CRM platform enforces consent by checking a `consent_status` field on Contact before allowing messaging operations (email sends, SMS, etc.). The consent service is the authority; the CRM platform is a consumer of that authority.

**SOC 2 / PII handling.** All PII fields (email, phone, name) are tagged in the schema metadata. Access to PII fields is logged — every read of a PII field generates an audit entry. In non-production environments, data masking is applied automatically: email addresses become `****@domain.com`, phone numbers become `***-***-1234`, names become `[REDACTED]`. This eliminates the risk of PII exposure in staging, development, and demo environments.

---

## 5. Observability

You cannot operate a system you cannot see. For a multi-tenant CRM platform with billions of records and sub-second latency targets, observability is not optional infrastructure — it's as critical as the database itself.

**Distributed Tracing (OpenTelemetry).** Every inbound request is assigned a trace ID that propagates across all services: API gateway → application → Postgres → Kafka → ES indexer → ES query. Traces are exported to Jaeger or Grafana Tempo. This is critical for debugging cross-service latency — when a customer reports "this contact update took 3 seconds," the trace reveals whether the bottleneck was a slow Postgres query, a backed-up Kafka consumer, or an ES indexing delay. Without distributed tracing, debugging latency in a system with 5+ components per request path is guesswork.

**Structured Logging.** All logs are JSON-formatted with mandatory fields: `trace_id`, `tenant_id`, `entity_type`, `entity_id`, `action`, `duration_ms`, `status_code`. Logs are shipped to a centralized log store (ELK or Loki). Tenant-scoped log queries are a first-class debugging tool — support engineers can pull all log entries for a specific tenant and trace ID without grepping through raw text. Unstructured logs in a multi-tenant system are nearly useless; structured logs with tenant context are a superpower.

**Metrics (Prometheus/Datadog):**

| Metric | Type | Labels | Purpose |
|---|---|---|---|
| `crm_api_request_duration_seconds` | histogram | method, object_type, status_code, tenant_tier | SLO tracking, latency budgets |
| `crm_cdc_lag_seconds` | gauge | table, consumer_group | CDC pipeline health — lag between WAL position and consumer position |
| `crm_es_index_lag_seconds` | gauge | index | Search freshness — how stale is the ES index? |
| `crm_pg_connections_active` | gauge | pool, tenant_tier | Connection pool saturation detection |
| `crm_tenant_query_count` | counter | tenant_id, object_type | Noisy tenant detection — which tenant is generating disproportionate load? |

**Alerting hierarchy:**

- **P1 (page)**: SLO breach (P95 latency exceeds budget for > 5 minutes), data integrity alert (cross-tenant data leak detected, checksum mismatch between Postgres and ES). These wake people up at 3 AM.
- **P2 (Slack urgent)**: CDC lag > 30 seconds, ES cluster status yellow, connection pool exhaustion approaching threshold. These need attention within 30 minutes.
- **P3 (Slack)**: Stale feature flag detected (>90 days), drift reconciliation mismatch rate > 1%, single tenant approaching their quota limit. These are addressed during business hours.

**Error tracking (Sentry).** Unhandled exceptions and validation failures are captured with full context: `tenant_id`, request payload hash (not the payload itself — PII risk), and stack trace. Errors are grouped by tenant to detect tenant-specific issues — if one tenant's custom field schema is causing parsing failures, that shows up as a cluster, not noise in the global error stream.

---

## 6. AI/ML Pipeline Integration

A CRM platform sitting on billions of structured records about contacts, companies, deals, and interactions is a natural foundation for machine learning. The data architecture must support ML workloads without compromising the OLTP database.

**Feature extraction.** ML pipelines read from ClickHouse, not Postgres. This is a hard rule. ClickHouse's columnar layout is purpose-built for computing features across millions of records — queries like "average deal value per contact in the last 90 days" or "email open rate by lifecycle stage" run in seconds on ClickHouse and would saturate Postgres connection pools. The CDC pipeline that feeds ClickHouse ensures features are computed on data that is at most minutes stale, which is acceptable for all current ML use cases.

**Batch feature pipeline.** Runs nightly as a scheduled job. It reads from ClickHouse, computes features (contact engagement score, deal velocity, churn risk indicators), and writes results back to Postgres as `custom_fields` entries via the CRM API. Writing through the API (rather than directly to Postgres) ensures that CDC propagates the computed features to ES and ClickHouse, maintaining consistency across all stores. The pipeline is idempotent — re-running it produces the same results.

**Real-time features.** For low-latency ML inference (e.g., "should we show a deal recommendation right now?"), pre-computed features are cached in Redis with a TTL of 1 hour. The ML inference service reads from Redis first, falling back to ClickHouse on cache miss. This keeps inference latency under 50ms for cached features, which is critical for in-app recommendations that must render within the UI's loading budget.

**Vector embeddings.** For semantic search ("find contacts similar to this one"), contact profiles are embedded using a language model and stored in a vector index. We use the pgvector extension in Postgres (or a dedicated vector DB like Qdrant for larger deployments). Vector search is exposed via a `POST /crm/objects/{object_type}/similar` endpoint that accepts either a record ID (find similar to this contact) or a text query (find contacts matching this description). This is purely additive — it doesn't replace keyword search in ES; it complements it for discovery-oriented use cases.

**Data access pattern.** ML pipelines authenticate as a service account with read-only access to ClickHouse and the CRM API. They cannot write directly to Postgres — all writes go through the API to maintain the audit trail and CDC consistency. This means ML-computed features appear in the `change_log` just like any other field update, providing full traceability of how a contact's "churn risk score" changed over time.

---

## 7. Capacity Estimation (Napkin Math)

Architecture diagrams without numbers are just cartoons. Here's the back-of-envelope math for a CRM platform at scale:

**Storage estimates:**

| Data | Record Count | Avg Record Size | Raw Size |
|---|---|---|---|
| Contacts | 2B | 2 KB (including custom_fields JSONB) | ~4 TB |
| Opportunities | 500M | 1.5 KB | ~750 GB |
| Activities | 10B | 800 bytes (subject + details JSONB, no body for most) | ~8 TB |
| Custom Object Records | 1B | 1 KB | ~1 TB |
| Relationships (edges) | 5B | 200 bytes | ~1 TB |
| Change Log | 10B entries | 500 bytes | ~5 TB (partitioned by month, older partitions archived) |
| Automation Execution Log | 2B entries | 400 bytes | ~800 GB (partitioned monthly, archived after 90 days) |
| Webhook Delivery Log | 1B entries | 300 bytes | ~300 GB (partitioned monthly, archived after 90 days) |
| **Total Postgres** | | | **~21 TB** |

Activities are the highest-volume entity after change log. At an average of 5 activities per contact (emails, calls, meetings, notes, tasks), 2B contacts yield ~10B activity rows. The `body` column (email bodies, meeting notes) is typically NULL or short for call/task types but can be large for email/note types — the 800-byte average accounts for this skew. With 64 hash partitions on `tenant_id`, each partition is approximately 330 GB — still within the range where Postgres performs efficiently with proper indexing, but the increase from the previous ~190 GB/partition warrants monitoring.

**Elasticsearch:** With the **thin-document / ID-only / per-partition index** pattern, ES documents are ~400-600 bytes. Data is spread across **64 per-partition indexes** per entity type (1 ES index per Postgres hash partition). Contact indexes total **~800 GB-1.2 TB** (~15 GB per partition index). Opportunity indexes total **~200 GB** (~3 GB per partition index). Each partition index has 1 primary shard + 1 replica. Total: **128 indexes, ~256 shards** across a 3-node cluster (~85 shards/node — comfortable). Most partition indexes stay at 1 shard indefinitely; only whale-heavy partitions (>30 GB) are resharded to 2-3 shards via an isolated reshard procedure that affects only that partition. Activities are not indexed in ES — timeline queries are served directly from Postgres.

**ClickHouse:** ~4 TB with columnar compression (roughly 10:1 compression ratio from raw data) — up from ~3 TB with the addition of `crm_activities`. With 2 replicas, total storage is ~8 TB.

**Kafka:** CDC throughput peaks at ~70K events/sec (up from ~50K with activity events, which are the highest-frequency CDC stream). 32 partitions across 8 topics (added `cdc.crm.activities`, `cdc.crm.automation_execution_log`) = 256 partitions. With 7-day retention, total on-disk storage is approximately 3 TB.

**Monthly cloud cost estimate (AWS, single cell):**

| Component | Instance / Config | Monthly Cost |
|---|---|---|
| Postgres | r6g.8xlarge + 21 TB gp3 | ~$7,000 |
| Elasticsearch | 2x r6g.xlarge + 1.5 TB | ~$2,000 |
| ClickHouse | 3x m6g.2xlarge + 8 TB | ~$3,500 |
| Kafka (MSK) | 3-broker cluster | ~$2,000 |
| Redis | r6g.xlarge | ~$500 |
| **Total** | | **~$15,000-19,000/month** |

The ES cost reduction (from ~$6K to ~$2K) reflects the thin-document approach: ~1.5 TB total ES storage (down from ~11 TB) allows a smaller cluster with fewer, smaller nodes. ES stores only filterable/sortable fields; Postgres handles all display data via batch PK lookup. Enterprise tenants on dedicated cells pay a premium that covers their isolated infrastructure. The cost scales linearly with the number of cells — adding a dedicated cell for a large enterprise tenant adds roughly $15-19K/month to infrastructure costs, which is easily covered by enterprise contract pricing.

---

## 8. Data Import & Export

A CRM platform that can't get data in and out efficiently is a roach motel. Import and export are not afterthoughts — they're core workflows that existing customers use weekly and that every prospect evaluates during migration from a competing platform.

**Bulk import.** `POST /crm/imports` accepts a CSV or NDJSON file (uploaded to S3 or streamed directly). An async import job validates each row against the object schema, deduplicates against existing records (email match for contacts, external ID match for other objects), and inserts or updates in batches of 500. Progress is tracked via `GET /crm/imports/{job_id}`, which returns total rows, processed count, success count, and error count. Failed rows are collected into an error report — a downloadable CSV with the original row plus an `error_reason` column — so users can fix and re-upload without re-importing the entire file.

**Bulk export.** `GET /crm/objects/{object_type}/export` uses the same filter model as the search API. Small exports (under 100K records) stream directly as NDJSON in the response body. Large exports produce a file hosted on S3, and the API returns a signed download URL. Maximum export size: 10 million records per request. Exports beyond this limit must be paginated using filter-based windowing (e.g., by `created_at` ranges).

**Data portability (GDPR Article 20).** A tenant can request a full data export via `POST /crm/tenant/export`. This produces a ZIP archive containing NDJSON files for all entity types (contacts, companies, opportunities, custom objects), all relationships, and all custom object schema definitions. The export is delivered within 72 hours (SLA). Implementation: a background job reads from Postgres read replicas to avoid any impact on production query performance. The export includes schema metadata so that the data is self-describing and can be imported into another system without manual mapping.

---

## 9. Migrations & Evolution

### Schema Migrations at Billion-Row Scale

Traditional `ALTER TABLE` with a lock is untenable at billion-row scale — a single `ALTER TABLE contacts ADD COLUMN` on a 2-billion-row table could lock the table for hours. We use a four-step process:

**Step 1: Expand** — Add the new column as nullable with no default, or create the new table alongside the old one. This is a metadata-only operation in Postgres and completes instantly.

```sql
-- Instant in PG 11+ (metadata-only, no rewrite):
ALTER TABLE contacts ADD COLUMN phone_numbers JSONB;
```

**Step 2: Dual-write** — The Core CRM Service writes to both old and new columns/tables. Reads still come from the old column. This is controlled by a feature flag:

```java
@Service
public class ContactService {

    @Autowired private ContactRepository contactRepo;
    @Autowired private FeatureFlagService featureFlags;

    @Transactional
    public ContactResponse updateContact(Contact contact) {
        // Always write to new column
        contact.setPhoneNumbers(normalizePhoneNumbers(contact.getPhone()));

        contactRepo.save(contact);

        // Feature flag: when enabled, start reading from new column
        if (featureFlags.isEnabled("read_phone_numbers_v2", contact.getTenantId())) {
            return readFromNewSchema(contact);
        }
        return readFromOldSchema(contact);
    }
}
```

**Step 3: Backfill** — A background migration job backfills existing rows in small, tenant-scoped batches:

```java
@Component
public class PhoneNumberBackfillJob {

    private static final int BATCH_SIZE = 1000;
    private static final UUID ZERO_UUID = UUID.fromString("00000000-0000-0000-0000-000000000000");

    @Autowired private JdbcTemplate jdbc;

    public void execute() {
        List<UUID> tenantIds = jdbc.queryForList(
            "SELECT id FROM tenants ORDER BY id", UUID.class);

        for (UUID tenantId : tenantIds) {
            UUID cursor = ZERO_UUID;
            int batchCount;

            do {
                // Process 1000 rows per batch, per tenant
                batchCount = jdbc.update("""
                    WITH candidates AS (
                        SELECT id
                        FROM contacts
                        WHERE tenant_id = ?
                          AND id > ?
                          AND phone IS NOT NULL
                          AND phone_numbers IS NULL
                        ORDER BY id
                        LIMIT ?
                    )
                    UPDATE contacts c
                    SET phone_numbers = jsonb_build_array(
                        jsonb_build_object('type', 'primary', 'value', c.phone, 'primary', true)
                    ),
                    updated_at = now()
                    FROM candidates
                    WHERE c.tenant_id = ? AND c.id = candidates.id
                    """, tenantId, cursor, BATCH_SIZE, tenantId);

                // Get the last ID processed for cursor advancement
                if (batchCount > 0) {
                    cursor = jdbc.queryForObject("""
                        SELECT max(id) FROM contacts
                        WHERE tenant_id = ? AND phone_numbers IS NOT NULL
                          AND id > ?
                        """, UUID.class, tenantId, cursor);
                }

                // Yield to other queries — avoid saturating the connection pool
                try { Thread.sleep(100); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }

            } while (batchCount == BATCH_SIZE);
        }
    }
}
```

Key properties of the backfill: it's idempotent (re-running it is safe), it's tenant-scoped (one tenant's backfill can't affect another), and it's throttled (100ms pause between batches).

**Step 4: Contract** — Once backfill is complete and all reads are on the new schema (verified by metrics), remove the old column/dual-write code. This is done in a subsequent release.

### Rolling Out New Indexing Strategies

When we need to change the ES mapping (e.g., adding a new analyzed field, changing a field type), we use the **blue-green index** pattern:

1. Create a new index (`crm_contacts_v3`) with the new mapping.
2. Start dual-writing: the CDC pipeline writes to both the old index and the new index.
3. Backfill the new index from Postgres (full re-index, running in the background).
4. Once the new index is caught up (verified by comparing document counts and sampling checksums), atomically swap the index alias (`crm_contacts` → `crm_contacts_v3`).
5. Delete the old index after a cooling-off period (24h).

This achieves zero-downtime index migrations. The backfill reads use a Postgres cursor scan ordered by `(tenant_id, id)`, processing ~50,000 documents per minute per consumer instance. For a 1-billion-record index, this takes ~14 hours with a single consumer or ~2 hours with 8 parallel consumers.

### Evolving Service Boundaries Without Losing Integrity

The platform is deployed as 8 microservices from the start (see Section 3: Microservice Decomposition). If a service needs to be further decomposed in the future (e.g., splitting the Core CRM Service into a Contact Service and an Opportunity Service), we **replace one piece at a time** (sometimes called the "strangler fig" pattern — named after a vine that grows around a tree and gradually replaces it):

1. **Extract reads first.** Route read traffic for a specific entity type to the new service while writes still go through the original service. The new service reads from a read replica or its own synced datastore. This is low-risk — the original service is still the authoritative writer.

2. **Extract writes with dual-write verification.** When ready to move writes, the new service becomes the writer and publishes events. The original service consumes these events and verifies that its local state matches. Any discrepancy triggers an alert and automatic reconciliation.

3. **Cut over.** Once dual-write verification shows zero discrepancies for N days, remove the original service's write path for that entity. The new service owns the data.

Throughout this process, **feature flags** control which code path is active per tenant. We roll out to internal tenants first, then to a canary group (5% of traffic), then 25%, then 100%. Each stage runs for at least one week before advancing.

### The Role of Feature Flags

Feature flags are not just a convenience — they're a safety mechanism:
- **Schema migrations**: `read_phone_numbers_v2` controls whether we read from the old or new column.
- **Service decomposition**: `route_contacts_to_new_service` controls traffic routing.
- **Index migrations**: `use_contacts_v3_index` controls which ES index alias is queried.
- **Rollback**: If any migration causes P95 latency to breach its budget, the flag is automatically toggled off by the monitoring system, and the team is paged.

Every flag has an owner, a creation date, and an expected removal date. Stale flags (>90 days old with no planned removal) trigger a weekly nag notification. The flag system is the connective tissue that makes billion-row migrations safe, reversible, and observable.

---

## 10. Testing Strategy

A CRM platform at this scale cannot rely on manual QA or developer-laptop test suites. We need a layered testing strategy that covers correctness, performance, resilience, and contract compatibility — and that runs automatically on every change.

### 10.1 SLO Checks in CI

Every PR that touches a query path, index definition, or storage configuration runs against a **benchmark dataset** in CI. This is not a unit test — it's a miniature load test that validates SLO compliance before merge.

**How it works:**

1. **Benchmark dataset.** A pre-seeded Postgres + ES + ClickHouse environment containing a representative dataset: 10M contacts, 2M opportunities, 50M activities, 500K relationships across 100 tenants (one "whale" tenant with 5M contacts, the rest evenly distributed). This environment runs on dedicated CI infrastructure, not ephemeral containers — consistent hardware eliminates measurement noise.

2. **SLO test suite.** A set of parameterized queries that exercise every documented SLO:

   ```yaml
   # .slo-tests/contact_crud.yml
   - name: single_contact_read
     query: GET /v1/crm/objects/contact/{id}
     tenant: whale_tenant
     slo:
       p50: 15ms
       p95: 50ms
       p99: 150ms
     iterations: 1000

   - name: filtered_contact_search
     query: POST /v1/crm/objects/contact/search
     body: { "filters": { "AND": [{ "field": "lifecycle_stage", "op": "eq", "value": "sql" }] }, "limit": 50 }
     tenant: whale_tenant
     slo:
       p50: 50ms
       p95: 200ms
       p99: 500ms
     iterations: 500

   - name: complex_segment_query
     query: POST /v1/crm/objects/contact/search
     body: { "filters": { "AND": [{ "field": "lifecycle_stage", "op": "eq", "value": "lead" }, { "association": { "target_type": "opportunity", "aggregate": { "op": "count", "compare": "gte", "value": 3 } } }] }, "limit": 50 }
     tenant: whale_tenant
     slo:
       p50: 200ms
       p95: 800ms
       p99: 2000ms
     iterations: 200

   - name: activity_timeline_load
     query: GET /v1/crm/objects/contact/{id}/activities?limit=25
     tenant: whale_tenant
     slo:
       p50: 30ms
       p95: 100ms
       p99: 300ms
     iterations: 500

   - name: automation_trigger_latency
     description: "Measure end-to-end CDC → trigger evaluation → action enqueue"
     slo:
       p50: 500ms
       p95: 2000ms
       p99: 5000ms
     iterations: 200
   ```

3. **CI gate.** The SLO test runner executes queries, collects latency percentiles, and compares against the defined budgets. If any SLO is breached, the CI check fails with a detailed report showing which query regressed, by how much, and the execution plan diff (for Postgres queries) or profile diff (for ES queries).

4. **Baseline tracking.** Results are stored in a time-series database. A dashboard shows SLO trends over time, making it easy to spot gradual regressions that stay just within budget — a query that crept from P95=120ms to P95=180ms over 3 months warrants investigation even though it hasn't breached the 200ms budget yet.

### 10.2 Load Testing

Load tests validate that the platform handles expected peak traffic without SLO breaches, and characterize breaking points for capacity planning.

**Scenarios:**

| Scenario | Profile | Target | Frequency |
|---|---|---|---|
| **Steady-state** | 10K concurrent tenants, realistic read/write mix (80/20), 5K req/sec | All SLOs met for 1 hour | Weekly (automated) |
| **Noisy neighbor** | One tenant fires 500 req/sec (10x their rate limit) while 9,999 tenants operate normally | Noisy tenant gets throttled (429s); other tenants' SLOs unaffected | Weekly (automated) |
| **Burst import** | 5 tenants simultaneously import 1M contacts each via batch API | Import completes within 30 min per tenant; search SLOs unaffected for other tenants | Monthly |
| **CDC backpressure** | Kafka consumers paused for 10 minutes, then resumed | Consumers catch up within 15 min; no data loss; automation triggers fire in order | Monthly |
| **Peak activity logging** | 50K activities/min across all tenants (sales campaign blitz) | Activity timeline queries stay within SLO; automation triggers fire within 2s | Monthly |

**Tooling:** k6 scripts with tenant-aware virtual users. Each VU authenticates as a specific tenant and executes a weighted mix of operations (search, CRUD, timeline, batch). Scripts live in the repo under `tests/load/` and run on dedicated load-generation infrastructure (not CI runners — those don't have the network bandwidth).

**Breaking-point tests (quarterly):** Ramp traffic until SLOs break. Record the breaking point (req/sec, concurrent connections, data volume). This informs capacity planning: if the breaking point is 15K req/sec and projected peak is 10K req/sec, we have 50% headroom — enough. If headroom drops below 30%, scale the cell or add a new one.

### 10.3 Contract Testing

With multiple consumers of the same data (ES indexer, ClickHouse loader, automation evaluator, webhook delivery, external API clients), schema changes can silently break downstream consumers. Contract tests catch this at build time.

**Provider-side contracts (API → consumers):**

Every API endpoint has a contract definition (OpenAPI spec + example fixtures). The contract test suite validates:

1. **Response shape conformance.** Every response from the API matches the OpenAPI schema. Fields are not silently added, removed, or type-changed without a version bump.
2. **CDC event schema.** Avro schemas in the Confluent schema registry are validated against consumer expectations. A schema change that breaks backward compatibility (removing a field, changing a type) is rejected at CI time.
3. **Webhook payload contracts.** Each webhook event type has a fixture. The webhook delivery service serializes a test event and validates it against the registered schema for each webhook version.

**Consumer-side contracts (consumers → providers):**

Each Kafka consumer declares what fields it reads from CDC events:

```yaml
# contracts/es-indexer-contact.yml
consumer: es-indexer
topic: cdc.crm.contacts
required_fields:
  - id
  - tenant_id
  - email
  - first_name
  - last_name
  - lifecycle_stage
  - lifecycle_status
  - custom_fields
  - updated_at
optional_fields:
  - phone
  - merged_into_id
```

The contract test runner cross-references consumer declarations against the current Avro schema. If a required field is removed or renamed in the schema, the test fails — forcing the developer to update the consumer before the schema change ships.

**Cross-store consistency contracts:**

A dedicated test validates that the ES document shape matches what the API query router expects. If the ES mapping adds a field that the query translator doesn't know how to filter on, or removes a field that the translator references, the test catches it.

### 10.4 Chaos Testing

Controlled fault injection validates that the platform degrades gracefully under failure conditions. These tests run monthly against a staging environment that mirrors production topology.

**Failure scenarios:**

| Fault | Injection Method | Expected Behavior | Validation |
|---|---|---|---|
| **ES cluster unavailable** | Block ES ports via iptables / network policy | Circuit breaker opens within 10s. Search falls back to Postgres degraded mode. API returns `503` for unsupported queries with `Retry-After` header. UI shows "limited mode" banner. | Verify: simple queries still work via Postgres; complex queries return 503; other tenants unaffected; ES recovery restores full functionality within 60s of port unblock |
| **Kafka broker failure** | Kill 1 of 3 brokers | RF=3 ensures no data loss. Producers fail over to remaining brokers. Consumer rebalance completes within 30s. CDC lag spikes briefly then recovers. | Verify: zero events lost (compare Postgres change_log count vs. Kafka topic offset); automation triggers continue firing; lag returns to <5s within 5 min |
| **Postgres replica failure** | Stop streaming replication to secondary | Primary continues serving all traffic. Read-replica consumers (exports, ML pipelines) fail over to primary or queue. Alert fires within 60s. | Verify: no API errors; export jobs retry against primary; alert received; replication resumes cleanly after replica restart |
| **Redis cluster failure** | Kill Redis primary | Rate limiting falls back to in-memory approximate counters (permits slightly higher throughput for ~60s). Cache misses cause elevated Postgres load (~2x for metadata queries). | Verify: API continues functioning; latency increases but stays within P99 budget; Redis recovery restores normal latency within 30s |
| **Single cell network partition** | Isolate one cell's network from cell router | Cell router detects health check failures within 5s. Affected tenants get 503. Unaffected cells continue normally. | Verify: impact contained to affected cell only; no cross-cell impact; recovery is automatic when partition heals |
| **Noisy tenant query** | Inject a tenant that runs 1000 concurrent complex segment queries | Tenant hits rate limit (429). ES per-tenant timeout prevents query from consuming shard threads. Other tenants' search latency unaffected. | Verify: noisy tenant throttled; SLOs met for 5 randomly sampled other tenants |
| **CDC consumer crash loop** | Kill automation-trigger-evaluator repeatedly (every 30s) | Events accumulate in Kafka (7-day retention). After consumer stabilizes, it catches up from last committed offset. No events lost; triggers fire in order (delayed). | Verify: once stable, consumer catches up within 15 min; all queued triggers fire; no duplicate actions (idempotency keys) |

**Gameday exercises (quarterly):**

Full-team exercises where SRE injects a combination of faults (e.g., ES down + spike in write traffic + one broker unhealthy) and the on-call team responds using the runbook. The exercise is timeboxed to 2 hours. Afterward, a blameless retrospective documents:
- What failed as expected
- What failed unexpectedly
- Runbook gaps discovered
- Action items with owners and deadlines

### 10.5 Integration & End-to-End Tests

Beyond the specialized test types above, a baseline integration test suite runs on every PR:

**CDC pipeline integration tests:**
- Create a contact in Postgres → verify the ES document appears within 10s with correct field values.
- Update a contact's `lifecycle_stage` → verify the CDC event fires, the automation evaluator processes it, and the expected action is enqueued.
- Log an activity on a contact → verify the activity event fires, activity-based automation triggers evaluate correctly, and the timeline API returns the activity.
- Delete a contact → verify ES document is removed, relationships are soft-deleted, and activities remain (orphan activities are display-only, not cascade-deleted).

**Cross-tenant isolation tests:**
- Create a record as tenant A → verify tenant B cannot read, update, or delete it via API or direct Postgres query (RLS).
- Verify that search results for tenant A never include tenant B's documents (ES routing validation).
- Verify that CDC events for tenant A are not visible to tenant B's automation rules.

**Data consistency smoke tests (run hourly in production):**
- Sample 1000 random records from Postgres, compute expected ES document hash, compare with actual ES document. Alert if mismatch rate > 0.1%.
- Verify ClickHouse materialized view accuracy: compare `mv_pipeline_value_by_stage` against a fresh `SELECT` on `crm_opportunities` for 10 random tenants.

This layered testing strategy ensures that correctness is verified at every level — from individual query latency in CI, to contract compatibility between services, to resilience under real failure conditions. No single layer is sufficient on its own; together they provide confidence that the platform behaves correctly under both normal and adversarial conditions.
