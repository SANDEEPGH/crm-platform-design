# CRM Data Platform – Staff Backend Engineer Take-Home

## Summary

This document set presents the architecture for a multi-tenant CRM data platform designed to scale to billions of records while remaining safe to evolve over a decade. The design treats **tenant isolation**, **schema extensibility**, **compliance**, and **operational safety** as first-class concerns rather than afterthoughts.

## What I Focused On and Why

1. **Multi-tenant isolation at the data layer.** In a CRM platform, a tenant data leak or noisy-neighbor incident is an existential event. Every design choice flows through the lens of `partition_number`-based LIST partitioning, row-level security, per-tenant resource governance, and cell-based architecture. Tenants are assigned to partitions at onboarding based on capacity estimates (not a hash function), enabling whale isolation on dedicated partitions and live tenant migration between partitions with ~2-5 seconds of read pause.

2. **Custom objects as a first-class primitive.** The longevity of a CRM platform depends on letting customers model their own domain. I chose a hybrid JSONB + schema registry approach with full schema versioning, so field evolution is tracked, validated, and reversible.

3. **Polyglot storage with a single source of truth.** Postgres is the authoritative store; Elasticsearch and ClickHouse are derived, eventually-consistent projections. Each Postgres LIST partition has a 1:1 mirror ES index (thin documents, ID-only search). The CDC-based sync pipeline (Debezium → Kafka → indexers) is designed to be idempotent, drift-detectable, and fully specified.

4. **Microservice architecture with a dedicated orchestrator.** The system is decomposed into 9 services. A **CRM Gateway** service orchestrates all read/write flows — calling the Tenant Service for partition routing, the Search Service for ES queries, and the Core CRM Service for Postgres enrichment. This keeps each downstream service single-purpose (Search = pure ES query, Core CRM = pure Postgres CRUD).

5. **API durability and completeness.** The generic `/crm/objects/{object_type}` contract unifies core and custom objects behind one surface. Full CRUD (including PATCH and DELETE), bulk operations, data export/import, activities/timeline, scoring rules, automation triggers, webhooks, idempotency, and optimistic concurrency control are all specified with concrete request/response shapes.

6. **Compliance and operational maturity.** GDPR (right to erasure, data residency, field-level encryption), disaster recovery with concrete RPO/RTO targets, observability (OpenTelemetry tracing, structured logging, alerting hierarchy), capacity-based tenant onboarding, live partition migration, and cell migration runbooks are covered alongside the core architecture.

7. **Tenant identity is server-resolved, never client-supplied.** The `X-Tenant-Id` shown in API examples is an internal header injected by the API Gateway after authenticating the caller (via JWT, API key, or session). Clients cannot set or tamper with it. The API Gateway strips any incoming `X-Tenant-Id` header and overwrites it with the tenant derived from the authenticated credential. This ensures that every downstream operation — RLS context, ES index routing, rate limiting, authorization — is based on a server-verified identity, not user input. See Part 3, "Tenant Identity: Server-Resolved, Not Client-Supplied" for the full flow.

## Major Trade-offs

| Decision | Upside | Downside |
|---|---|---|
| Shared-schema multi-tenancy (single Postgres schema partitioned by `tenant_id`; per-partition ES indexes) | Simpler ops, lower cost at scale | Requires disciplined RLS and quota enforcement |
| UUID v7 for all primary keys | Time-ordered, better B-tree locality, fewer page splits at billion-row scale | Slight clock dependency; marginally more complex than v4 |
| JSONB for custom fields — exact match only | Fast reads, simpler queries, GIN indexable; no field promotion mechanism to maintain | Per-field type enforcement by Core CRM Service; range queries use dedicated `custom_score` column, not custom fields |
| Pipeline stages as JSONB array (vs separate table) | Atomic pipeline reads, trivial ordering, no N+1 | No FK for stage_id — enforced by Core CRM Service; treat stage_id as immutable |
| Per-partition ES indexes (64 indexes per entity type, thin documents, ID-only search) | Structural isolation by partition; per-partition reshard; 87% ES storage reduction; display data always fresh from Postgres | 128 indexes to manage (vs 2 with shared index); index name resolution required on every operation |
| CDC-based sync (Debezium) over dual-writes | No write-path coupling, idempotent replay | Adds ~2-5s indexing lag; requires drift reconciliation |
| Generic object API (vs per-type endpoints) | One contract to maintain; custom objects work immediately | More complex validation layer; less discoverability without good documentation |
| Polymorphic relationships and activities tables | Supports arbitrary object pairs without DDL; activities work with custom objects immediately | No DB-level referential integrity for polymorphic FKs; requires Core CRM Service validation + Dedup Service async integrity scanner |
| Field-level encryption for sensitive custom fields | GDPR/SOC 2 compliance for PII | Encrypted fields are display-only — cannot be indexed or searched |
| `custom_score` column with tenant-defined scoring rules | One column handles all range/sort use cases; no column sprawl, no ES mapping promotion | Only one sortable custom metric per entity; tenants must design a composite score |

## Deliberate Scope Exclusions

Given the breadth of the problem (data modelling, polyglot storage, API contracts, reliability, and operational safety across a multi-tenant, billion-record platform), I prioritized defining the **end-to-end data architecture and operational flows** over depth in every cross-cutting concern. The following are conscious exclusions, not oversights:

**Role-Based Access Control (RBAC) — the most significant exclusion.** The current design enforces **tenant-level isolation** (RLS ensures tenant A cannot see tenant B's data), but does not enforce **intra-tenant authorization** (within a tenant, any authenticated user can read/write all records). In a production CRM, this is unacceptable — a sales rep should only see their own contacts and deals, a manager should see their team's records, and an admin should see everything. The architecture is designed to accommodate RBAC without structural changes:

- **Where RBAC would be enforced:** The CRM Gateway's post-filter step (Part 3, Section 2) already has a placeholder for "remove records the user isn't authorized to see." This would check the user's role and team membership against each record's `owner_id`, a `team_id` field (to be added), or a record-level ACL.
- **How it would work at the DB level:** Additional RLS policies on Postgres that filter by `owner_id = current_setting('app.current_user')::uuid` or `team_id = ANY(current_setting('app.current_teams')::uuid[])`, layered on top of the existing tenant isolation policies.
- **How it would work at the ES level:** A `visible_to` keyword array field on each ES document containing the user IDs and team IDs that can see the record. Search queries would add a mandatory `terms` filter on `visible_to`, similar to the existing mandatory `tenant_id` filter.
- **Why it was excluded:** RBAC design requires defining a role hierarchy, permission model (record-level vs field-level vs action-level), team/territory structures, and delegation rules — each of which is a substantial design exercise. Including a shallow treatment would have added pages without demonstrating depth. I chose to invest that time in the CDC pipeline, automation engine, and operational runbooks instead.

**Other exclusions:** Rate limiting implementation details beyond the API gateway (e.g., per-user limits within a tenant), notification/alerting service design, full audit log query API, and admin/back-office tooling.

## What I Would Do Next

- **Build the RBAC layer** — field-level and record-level permissions per tenant role, enforced at three layers: (1) Postgres RLS policies filtering by `owner_id`/`team_id`, (2) ES `visible_to` filter on every search query, (3) CRM Gateway post-filter as a final safety net. This is the highest-priority gap in the current design.
- **Prototype the CDC pipeline** end-to-end with Debezium → Kafka → per-partition ES indexes to validate latency and ordering guarantees under realistic multi-tenant load.
- **Load-test the hot-tenant scenario** — simulate a single tenant with 50M contacts hitting search while 10K other tenants run normal workloads; validate per-partition index isolation, circuit-breaker behavior, and degraded-mode fallback.
- **Formalize the SLO framework** — wire P95/P99 latency budgets into the CI pipeline so performance regressions are caught before deploy.
- **Implement the contact deduplication pipeline** — deploy the async duplicate detection job with pg_trgm, tune confidence thresholds, and build the merge-suggestion review UI.
- **Harden the vector search integration** — evaluate pgvector vs dedicated vector DB (Qdrant/Weaviate) for semantic contact search at scale.
- **Run disaster recovery drills** — execute the quarterly DR runbook against staging and measure actual RTO against targets.

## Deliverables

| File | Covers |
|---|---|
| [`docs/part1-data-model.md`](docs/part1-data-model.md) | Logical data model, physical schema (DDL), ERD, invariants, deduplication strategy |
| [`docs/part2-storage-indexing.md`](docs/part2-storage-indexing.md) | Storage strategy, ClickHouse schemas, ES index schemas (per-partition, thin documents), ILM, Kafka topic design, caching layer, consistency model |
| [`docs/part3-api-contracts.md`](docs/part3-api-contracts.md) | Full CRUD API, activity/timeline API, automation triggers, scoring rules, bulk operations, query/filter model, ID-only search pattern, data export, versioning, idempotency |
| [`docs/part4-reliability-essay.md`](docs/part4-reliability-essay.md) | Performance budgets, tenant isolation, cell migration runbook, DR/backup, GDPR/compliance, observability, AI/ML integration, capacity estimation, data import/export, migration safety, testing strategy |
| [`diagrams/erd.mermaid`](diagrams/erd.mermaid) | Entity-relationship diagram (Mermaid) |
| [`diagrams/architecture.mermaid`](diagrams/architecture.mermaid) | High-level system overview — all services and primary data flows |
| [`diagrams/write-path.mermaid`](diagrams/write-path.mermaid) | Write path: API request through CDC pipeline to per-partition ES indexes and ClickHouse |
| [`diagrams/read-path.mermaid`](diagrams/read-path.mermaid) | Read path: decision tree routing, ES ID-only search → Postgres enrichment |
| [`diagrams/background-jobs.mermaid`](diagrams/background-jobs.mermaid) | Background workers: index sync, automations, dedup, purge, ML, drift |
| [`snippets/types.ts`](snippets/types.ts) | TypeScript interfaces for all API contracts (CRUD, batch, export/import, activities, automation, webhooks, scoring) |
| [`snippets/schema.sql`](snippets/schema.sql) | Complete DDL with UUID v7, triggers, RLS, partitions, scoring rules, automation rules, webhook subscriptions |
