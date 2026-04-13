# Part 3 – API & Data Contract Design (Including Custom Objects)

## 1. Generic Object APIs

The core design principle is a **unified object API** where core objects (Contact, Company, Opportunity) and custom objects (Policy, Vehicle, etc.) share the same endpoint contract. The `object_type` path parameter determines which entity is being addressed, and the response shape is consistent across all types.

### Type Registry

The system maintains a type registry that maps `object_type` slugs to their backing storage:

| `object_type` value | Backed by | Notes |
|---|---|---|
| `contact` | `contacts` table | Core type, hard-coded schema |
| `company` | `companies` table | Core type, hard-coded schema |
| `opportunity` | `opportunities` table | Core type, hard-coded schema |
| `pipeline` | `pipelines` table | Core type, hard-coded schema |
| `policy`, `vehicle`, etc. | `custom_object_records` table | Custom type, schema from `custom_object_types` |

---

### Tenant Identity: Server-Resolved, Not Client-Supplied

The `X-Tenant-Id` header shown in the API examples below is **not set by the client**. It is injected by the **API Gateway** after authenticating the request:

1. The client sends a request with an authentication credential (JWT bearer token, API key, or session cookie).
2. The API Gateway validates the credential and determines which tenant and user the caller belongs to (e.g., by decoding `tenant_id` and `user_id` claims from the JWT, or by looking up the API key in a key-to-tenant mapping table).
3. The API Gateway injects `X-Tenant-Id` and `X-User-Id` as **internal headers** on the forwarded request. These headers are stripped from any incoming external request — a client cannot set or override them.
4. All downstream services (CRM Gateway, Core CRM Service, Search Service, etc.) trust these internal headers because they originate from the API Gateway, which is the only ingress point.

This ensures that **no client can tamper with the tenant context**. Even if a malicious caller crafts a request with a forged `X-Tenant-Id` header, the API Gateway overwrites it with the tenant resolved from their authenticated credential. The `tenant_id` used for RLS (`SET LOCAL app.current_tenant`), ES index routing, and all authorization checks is always derived server-side from the authenticated identity — never from user input.

In the examples below, `X-Tenant-Id: tenant_abc123` is shown for readability to indicate which tenant the request is scoped to. In production, this header is invisible to the client.

---

### POST /v1/crm/objects/{object_type} — Create

**Request:**
```json
POST /v1/crm/objects/contact
Content-Type: application/json
X-Tenant-Id: tenant_abc123  (server-injected, not client-supplied — see above)

{
  "properties": {
    "email": "jane@acme.com",
    "first_name": "Jane",
    "last_name": "Doe",
    "phone": "+1-555-0100",
    "lifecycle_stage": "lead"
  },
  "custom_properties": {
    "lead_score": 85,
    "preferred_language": "en"
  },
  "associations": [
    {
      "target_type": "company",
      "target_id": "comp_xyz789",
      "relation_kind": "associated"
    }
  ]
}
```

**Custom object example:**
```json
POST /v1/crm/objects/policy
Content-Type: application/json
X-Tenant-Id: tenant_abc123

{
  "properties": {
    "policy_number": "POL-2026-00142",
    "premium": 1250.00,
    "renewal_date": "2027-03-15",
    "coverage_type": "home"
  },
  "associations": [
    {
      "target_type": "contact",
      "target_id": "cont_jane456",
      "relation_kind": "policyholder"
    }
  ]
}
```

Note: For custom objects, all fields go into `properties` (there is no separate `custom_properties` section) because every field on a custom object is defined by the tenant's schema.

**Response (201 Created):**
```json
{
  "data": {
    "id": "cont_jane456",
    "object_type": "contact",
    "tenant_id": "tenant_abc123",
    "properties": {
      "email": "jane@acme.com",
      "first_name": "Jane",
      "last_name": "Doe",
      "phone": "+1-555-0100",
      "lifecycle_stage": "lead"
    },
    "custom_properties": {
      "lead_score": 85,
      "preferred_language": "en"
    },
    "lifecycle_status": "active",
    "associations": [
      {
        "id": "rel_001",
        "target_type": "company",
        "target_id": "comp_xyz789",
        "relation_kind": "associated"
      }
    ],
    "created_at": "2026-04-10T14:30:00Z",
    "updated_at": "2026-04-10T14:30:00Z"
  }
}
```

---

### GET /v1/crm/objects/{object_type}/{id} — Read

**Request:**
```
GET /v1/crm/objects/contact/cont_jane456
X-Tenant-Id: tenant_abc123
```

**Optional query parameters:**
- `?associations=true` — include the `associations` array (default: false for performance)
- `?fields=email,first_name,custom_properties.lead_score` — sparse fieldset

**Response (200 OK):**
```json
{
  "data": {
    "id": "cont_jane456",
    "object_type": "contact",
    "tenant_id": "tenant_abc123",
    "properties": {
      "email": "jane@acme.com",
      "first_name": "Jane",
      "last_name": "Doe",
      "phone": "+1-555-0100",
      "lifecycle_stage": "lead"
    },
    "custom_properties": {
      "lead_score": 85,
      "preferred_language": "en"
    },
    "lifecycle_status": "active",
    "associations": [
      {
        "id": "rel_001",
        "target_type": "company",
        "target_id": "comp_xyz789",
        "relation_kind": "associated",
        "target_snapshot": {
          "name": "Acme Corp",
          "domain": "acme.com"
        }
      }
    ],
    "created_at": "2026-04-10T14:30:00Z",
    "updated_at": "2026-04-10T14:30:00Z"
  }
}
```

The `target_snapshot` in associations is a lightweight preview of the related object — just enough for UI display without requiring a second API call. It includes only display-relevant fields (name, domain, email) and is populated server-side.

---

### PATCH /v1/crm/objects/{object_type}/{id} — Update

PATCH uses **merge semantics**: fields not included in the request body are left unchanged; fields explicitly set to `null` are cleared.

**Request:**
```json
PATCH /v1/crm/objects/contact/cont_jane456
Content-Type: application/json
X-Tenant-Id: tenant_abc123
If-Match: "2026-04-10T14:30:00Z"

{
  "properties": {
    "lifecycle_stage": "sql"
  },
  "custom_properties": {
    "lead_score": 92
  },
  "associations_to_add": [
    {
      "target_type": "opportunity",
      "target_id": "opp_123",
      "relation_kind": "associated"
    }
  ],
  "associations_to_remove": ["rel_001"]
}
```

- `properties` — partial update; only the supplied fields are overwritten.
- `custom_properties` — partial merge; supplied keys are upserted, existing keys not in the payload are preserved.
- `associations_to_add` — list of new associations to create.
- `associations_to_remove` — list of relationship IDs (strings) to delete.

**Optimistic concurrency control:** The `If-Match` header carries the object's `updated_at` timestamp (or a version number). The server compares this value against the current state before applying the update. If the object was modified since the client last read it, the server returns `409 Conflict`:

```json
{
  "error": {
    "code": "CONFLICT",
    "message": "Object was modified since your last read. Current version: \"2026-04-10T15:12:00Z\". Please re-fetch and retry."
  }
}
```

**Response (200 OK):**

The response contains the full object after the update, in the same shape as the GET response:

```json
{
  "data": {
    "id": "cont_jane456",
    "object_type": "contact",
    "tenant_id": "tenant_abc123",
    "properties": {
      "email": "jane@acme.com",
      "first_name": "Jane",
      "last_name": "Doe",
      "phone": "+1-555-0100",
      "lifecycle_stage": "sql"
    },
    "custom_properties": {
      "lead_score": 92,
      "preferred_language": "en"
    },
    "lifecycle_status": "active",
    "associations": [
      {
        "id": "rel_002",
        "target_type": "opportunity",
        "target_id": "opp_123",
        "relation_kind": "associated"
      }
    ],
    "created_at": "2026-04-10T14:30:00Z",
    "updated_at": "2026-04-10T16:45:00Z"
  }
}
```

---

### DELETE /v1/crm/objects/{object_type}/{id} — Soft Delete

By default, DELETE performs a **soft delete**: the object's `lifecycle_status` is set to `"deleted"` and a `deleted_at` timestamp is recorded. The record remains in the database and can be restored if needed. Hard purge happens via a background job after 90 days.

**Request:**
```
DELETE /v1/crm/objects/contact/cont_jane456
X-Tenant-Id: tenant_abc123
```

**Optional query parameters:**
- `?permanent=true` — hard delete (immediate, irreversible). Requires elevated admin permissions (`crm:objects:purge` scope). Returns `403 Forbidden` if the caller lacks this scope.

**Response (200 OK):**
```json
{
  "data": {
    "id": "cont_jane456",
    "object_type": "contact",
    "tenant_id": "tenant_abc123",
    "properties": {
      "email": "jane@acme.com",
      "first_name": "Jane",
      "last_name": "Doe",
      "phone": "+1-555-0100",
      "lifecycle_stage": "sql"
    },
    "custom_properties": {
      "lead_score": 92,
      "preferred_language": "en"
    },
    "lifecycle_status": "deleted",
    "deleted_at": "2026-04-10T17:00:00Z",
    "associations": [],
    "created_at": "2026-04-10T14:30:00Z",
    "updated_at": "2026-04-10T17:00:00Z"
  }
}
```

**Cascade behavior:** Deleting an object also soft-deletes its relationships. Associated objects themselves are not deleted — only the association edges are removed. This prevents orphaned references in queries and UI.

**Activities are NOT cascade-deleted.** When a contact is soft-deleted, their activity timeline (calls, emails, meetings, notes, tasks) remains intact. Activities are evidence of real-world interactions and serve as audit trail. The timeline is no longer queryable via the normal API (the parent entity is deleted), but remains accessible to admin users and compliance queries. On GDPR hard-purge (90-day grace period), the activity `body` and `details` fields are scrubbed (set to NULL), but activity metadata (`activity_type`, `occurred_at`, `duration_secs`, `owner_id`) is retained for aggregate analytics — similar to how `change_log` entries are anonymized but not deleted.

---

### POST /v1/crm/objects/{object_type}/batch — Bulk Operations

The batch endpoint supports creating, updating, and deleting multiple records in a single request. This is the preferred approach for imports, sync jobs, and any workflow that touches more than a handful of records.

**Request:**
```json
POST /v1/crm/objects/contact/batch
Content-Type: application/json
X-Tenant-Id: tenant_abc123
Idempotency-Key: batch_abc_123

{
  "operations": [
    {
      "action": "create",
      "properties": {
        "email": "alice@acme.com",
        "first_name": "Alice",
        "last_name": "Smith",
        "lifecycle_stage": "lead"
      }
    },
    {
      "action": "update",
      "id": "cont_jane456",
      "properties": {
        "lifecycle_stage": "customer"
      }
    },
    {
      "action": "delete",
      "id": "cont_old789"
    }
  ]
}
```

**Optional query parameters:**
- `?atomic=true` — wraps the entire batch in a single database transaction (all-or-nothing). If any operation fails, all changes are rolled back and the response status is `422 Unprocessable Entity`. Without this flag, the batch is **non-atomic** by default: each operation is processed independently, and partial success is allowed.

**Max batch size:** 100 operations per request. Requests exceeding this limit are rejected with `400 Bad Request`.

**Response (200 OK — non-atomic mode):**
```json
{
  "data": {
    "results": [
      {
        "index": 0,
        "status": "created",
        "data": {
          "id": "cont_alice001",
          "object_type": "contact",
          "properties": { "email": "alice@acme.com", "first_name": "Alice", "last_name": "Smith", "lifecycle_stage": "lead" },
          "lifecycle_status": "active",
          "created_at": "2026-04-10T17:10:00Z",
          "updated_at": "2026-04-10T17:10:00Z"
        }
      },
      {
        "index": 1,
        "status": "updated",
        "data": {
          "id": "cont_jane456",
          "object_type": "contact",
          "properties": { "email": "jane@acme.com", "first_name": "Jane", "last_name": "Doe", "lifecycle_stage": "customer" },
          "lifecycle_status": "active",
          "created_at": "2026-04-10T14:30:00Z",
          "updated_at": "2026-04-10T17:10:00Z"
        }
      },
      {
        "index": 2,
        "status": "deleted",
        "data": {
          "id": "cont_old789",
          "lifecycle_status": "deleted",
          "deleted_at": "2026-04-10T17:10:00Z"
        }
      }
    ],
    "summary": {
      "total": 3,
      "succeeded": 3,
      "failed": 0
    }
  }
}
```

When an individual operation fails in non-atomic mode, its entry contains an `error` object instead of `data`:

```json
{
  "index": 1,
  "status": "error",
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Field 'lifecycle_stage' value 'invalid_stage' is not in the allowed set."
  }
}
```

---

### GET /v1/crm/objects/{object_type}/export — Bulk Export

The export endpoint accepts the same filter model as the search endpoint and produces a downloadable result set. The behavior depends on the estimated result size:

**Small exports (< 10,000 records) — synchronous streaming:**

```
GET /v1/crm/objects/contact/export?filter=...&fields=email,first_name,last_name
X-Tenant-Id: tenant_abc123
```

The response is streamed as **NDJSON** (newline-delimited JSON), one record per line. This allows clients to process results incrementally without buffering the entire dataset:

```
HTTP/1.1 200 OK
Content-Type: application/x-ndjson
Transfer-Encoding: chunked

{"id":"cont_jane456","properties":{"email":"jane@acme.com","first_name":"Jane","last_name":"Doe"}}
{"id":"cont_alice001","properties":{"email":"alice@acme.com","first_name":"Alice","last_name":"Smith"}}
...
```

**Large exports (> 10,000 records) — asynchronous job:**

```
GET /v1/crm/objects/contact/export?filter=...&fields=email,first_name,last_name
X-Tenant-Id: tenant_abc123
```

```json
HTTP/1.1 202 Accepted

{
  "data": {
    "export_id": "exp_abc123",
    "status": "processing",
    "estimated_records": 145000,
    "poll_url": "/v1/crm/exports/exp_abc123"
  }
}
```

The client polls `GET /v1/crm/exports/{export_id}` for status:

```json
{
  "data": {
    "export_id": "exp_abc123",
    "status": "completed",
    "record_count": 144892,
    "download_url": "https://exports.crm-platform.com/exp_abc123.ndjson?token=...",
    "expires_at": "2026-04-11T17:10:00Z"
  }
}
```

Export files are stored in object storage (S3) with a **24-hour expiry**. After expiry, the download URL returns `410 Gone`.

**Rate limits:** 1 concurrent export per tenant (standard tier), 5 concurrent exports (enterprise tier). Additional requests return `429 Too Many Requests` with a `Retry-After` header.

---

### GET /v1/crm/objects/{object_type} — List / Query

**Request:**
```
GET /v1/crm/objects/contact?filter=...&sort=...&cursor=...&limit=50
X-Tenant-Id: tenant_abc123
```

**Response (200 OK):**
```json
{
  "data": [
    {
      "id": "cont_jane456",
      "object_type": "contact",
      "properties": {
        "email": "jane@acme.com",
        "first_name": "Jane",
        "last_name": "Doe",
        "lifecycle_stage": "lead"
      },
      "custom_properties": {
        "lead_score": 85
      },
      "lifecycle_status": "active",
      "created_at": "2026-04-10T14:30:00Z",
      "updated_at": "2026-04-10T14:30:00Z"
    }
  ],
  "paging": {
    "next_cursor": "eyJ0IjoxNzEyNzY0MjAwLCJpIjoiY29udF9qYW5lNDU2In0=",
    "has_more": true,
    "total_estimate": 12450
  },
  "metadata": {
    "source": "search_index",
    "index_lag_ms": 1200
  }
}
```

The `metadata.source` field tells the caller whether results came from the relational DB or the search index, and `index_lag_ms` reports the current ES replication lag. This transparency lets clients make informed decisions (e.g., retry against the DB if lag is high and exactness matters).

---

## 2. Query & Filter Model

### Filter Syntax

Filters are passed as a JSON body on `POST /v1/crm/objects/{object_type}/search` (we use POST for complex queries to avoid URL length limits):

```json
POST /v1/crm/objects/contact/search
X-Tenant-Id: tenant_abc123

{
  "filters": {
    "AND": [
      { "field": "lifecycle_stage", "op": "eq", "value": "lead" },
      { "field": "custom_properties.lead_score", "op": "gte", "value": 50 },
      {
        "OR": [
          { "field": "properties.email", "op": "contains", "value": "@acme.com" },
          { "field": "properties.email", "op": "contains", "value": "@bigcorp.com" }
        ]
      },
      {
        "association": {
          "target_type": "opportunity",
          "relation_kind": "associated",
          "filter": {
            "AND": [
              { "field": "lifecycle_status", "op": "eq", "value": "active" },
              { "field": "properties.amount", "op": "gte", "value": 5000 }
            ]
          },
          "aggregate": { "op": "count", "compare": "gte", "value": 3 }
        }
      }
    ]
  },
  "sort": [
    { "field": "custom_properties.lead_score", "direction": "desc" },
    { "field": "created_at", "direction": "asc" }
  ],
  "cursor": null,
  "limit": 50,
  "fields": ["email", "first_name", "last_name", "custom_properties.lead_score"]
}
```

This query translates to: "All leads with a lead score ≥ 50, whose email is at acme.com or bigcorp.com, who have 3 or more active opportunities worth ≥ $5,000 each."

### Supported Filter Operators

| Operator | Meaning | Applicable Types |
|---|---|---|
| `eq` | Equals | All |
| `neq` | Not equals | All |
| `gt`, `gte`, `lt`, `lte` | Comparisons | number, date, datetime, currency |
| `in` | Value in set | text, enum, keyword |
| `nin` | Not in set | text, enum, keyword |
| `contains` | Substring match | text, email |
| `starts_with` | Prefix match | text |
| `is_set` | Field is not null | All |
| `is_not_set` | Field is null | All |
| `between` | Range (inclusive) | number, date, currency |

**Custom field operator restrictions.** Fields under `custom_properties.*` support only `eq`, `neq`, `in`, `nin`, `is_set`, and `is_not_set`. Range operators (`gt`, `gte`, `lt`, `lte`, `between`) and text operators (`contains`, `starts_with`) are **not supported** on custom fields — the GIN index and ES flattened type only handle exact match. For range queries and sorting on tenant-defined data, use `custom_score` (a system-level field that supports all operators). The API returns `400 Bad Request` with a clear error if a range operator is applied to a custom field: `"Range operators are not supported on custom_properties fields. Use custom_score for ranking and sorting."`

### Mapping to Storage Engines

The **CRM Gateway** (the orchestrator service that handles all incoming API requests) decides whether to execute against Postgres, Elasticsearch, or ClickHouse using a **deterministic decision tree** — not a heuristic score. The CRM Gateway evaluates conditions in priority order; the first match wins.

**Decision Tree (evaluated top-to-bottom, first match wins):**

```
1. Is ES circuit breaker OPEN?
   ├─ YES → Is query Postgres-capable? (see degraded-mode list below)
   │        ├─ YES → Route to Postgres (degraded mode, limited filters)
   │        └─ NO  → Return 503 Service Degraded + Retry-After: 60
   └─ NO  → continue

2. Is this a single-record lookup by ID?
   └─ YES → Route to Postgres
            (PK B-tree traversal ~3-5ms, strong consistency)

3. Is this an activity timeline or open-tasks query?
   └─ YES → Route to Postgres
            (Entity-scoped queries served by dedicated indexes:
             activities: (tenant_id, entity_type, entity_id, occurred_at)
             open tasks: (tenant_id, owner_id, status) WHERE task + open)

4. Is this a dashboard/aggregation query?
   └─ YES → Route to ClickHouse
            (Columnar scans + materialized views)

5. Is this any list/filter/search/sort/paginate query?
   └─ YES → Route to Elasticsearch (ID-only pattern):

            Step 1: ES returns sorted IDs
                    Query the per-partition index (crm_contacts_pNN).
                    ES handles: filtering, sorting, pagination, facets.
                    Returns: sorted list of IDs only (_source: false).

            Step 2: Postgres enriches IDs with full fresh data
                    SELECT * FROM {table} WHERE tenant_id=$1 AND id=ANY($2)
                    ORDER BY array_position($2, id)  -- preserves ES sort

            Step 3: Post-filter (guard against ES eventual consistency)
                    Before returning results, the Search Service filters the
                    Postgres rows to remove records that ES returned but
                    shouldn't be in the result set:

                    a) Tenant verification — confirm every row's tenant_id
                       matches the requesting tenant. ES indexes are
                       per-partition (multiple tenants share a partition),
                       and the ES query includes a tenant_id filter, but
                       this is the final safety check using authoritative
                       Postgres data.

                    b) Deleted/archived records — ES may still contain a
                       record that was soft-deleted 2 seconds ago (CDC lag).
                       The Postgres row has lifecycle_status='deleted'. Remove
                       it from results.

                    c) Authorization check — if intra-tenant RBAC is enabled,
                       verify the requesting user has permission to see each
                       record (e.g., sales rep can only see their own contacts,
                       not the whole team's). Strip unauthorized records.
                       NOTE: Intra-tenant RBAC is a deliberate scope exclusion
                       in this iteration — see README for rationale and the
                       three-layer enforcement approach planned for it. The
                       post-filter slot is architecturally reserved for it.

                    d) Backfill if short — if post-filtering removed records
                       (e.g., 3 out of 50 were deleted since ES indexed them),
                       the page is now short (47 instead of 50). Two options:
                       - Return 47 results (simpler, what most CRMs do)
                       - Issue a follow-up ES query for 3 more IDs to fill
                         the page (more complex, better UX for power users)

            Step 4 (optional): Postgres fetches associations if requested
                    SELECT * FROM relationships WHERE source_id=ANY($2)
```

**Why post-filtering is necessary:** Elasticsearch is eventually consistent (~2-5 seconds behind Postgres). During that window, ES may return IDs for records that have been deleted, merged, or had their tenant_id changed in Postgres. The post-filter step uses authoritative Postgres data to catch these cases. This is a lightweight check — the rows are already fetched in Step 2, so the filter is an in-memory scan over 50 rows (no extra database query). In practice, < 0.1% of results are removed by post-filtering.

**Read-after-write handling:** When a user creates a contact and immediately sees the list view, the just-created record may not be in ES yet (2-5s lag). The frontend handles this client-side: it merges the just-saved record (returned from the POST response) into the list results locally. This avoids routing list queries to Postgres for strong consistency, keeping the read path clean.

**Why a decision tree, not a scoring system:** A deterministic tree means routing is always explainable. Log the step number that matched, and the decision is fully auditable. The `metadata.source` field in every API response indicates the routing: `"search_index+database"` (ES found IDs, Postgres enriched), `"database"` (Postgres-only), or `"analytics"` (ClickHouse).

**Degraded-mode capabilities (when ES circuit breaker is open):**

When ES is unavailable, Postgres serves a limited set of queries using fallback indexes. The CRM remains usable for basic workflows — browsing contacts, looking up by email, viewing pipeline — but advanced search and filtering are unavailable.

- **Works in degraded mode:**
  - Single-record by ID (PK index)
  - Activity timelines and open tasks (dedicated indexes)
  - Exact email lookup (`WHERE lower(email) = $1` — index: `idx_contacts_email`)
  - Active contacts sorted by recency (`WHERE lifecycle_status = 'active' ORDER BY updated_at DESC` — index: `idx_contacts_status`)
  - Pipeline view (`WHERE pipeline_id = $1 AND stage_id = $2` — index: `idx_opps_pipeline`)
  - My deals (`WHERE owner_id = $1` — index: `idx_opps_owner`)
- **Returns 503 in degraded mode:** full-text search, company/industry filters, association-based aggregates, faceted counts, custom field filters, custom_score sorting. The API returns `503 Service Degraded` with a `Retry-After: 60` header.
- **UI behavior:** The frontend detects `metadata.source: "database"` and shows a banner: "Search is running in limited mode. Some filters are temporarily unavailable."

The table below summarizes the routing:

| Query Type | Routed To | Why |
|---|---|---|
| Single record by ID | Postgres | PK lookup, 3-5ms, strong consistency |
| Activity timeline / open tasks | Postgres | Entity-scoped, dedicated indexes |
| Dashboard aggregations | ClickHouse | Columnar scans, materialized views |
| All list/filter/sort/paginate | ES (IDs) → Postgres (enrichment) | ES finds + sorts, Postgres returns fresh data |
| ES down: basic list/email/pipeline | Postgres (degraded) | Fallback indexes kept as safety net |
| ES down: everything else | 503 | Cannot serve without ES |

**Postgres translation of a simple filter:**
```sql
SELECT id, email, first_name, last_name, custom_fields->>'lead_score' as lead_score
FROM contacts
WHERE tenant_id = $1
  AND lifecycle_stage = 'lead'
  AND (custom_fields->>'lead_score')::int >= 50
  AND lifecycle_status = 'active'
ORDER BY (custom_fields->>'lead_score')::int DESC, created_at ASC
LIMIT 50;
```

**Search Service Query Translation Layer:**

The API consumer writes filters using **API field names** (`properties.email`, `lifecycle_stage`, `custom_score`). The Search Service owns a **translation layer** that converts these API-level filters into the internal ES query. The API consumer has no knowledge of ES — no ES field names, no ES query syntax, no awareness that `email contains "@acme.com"` is internally rewritten to a different field.

**API-to-ES field mapping (owned by Search Service):**

| API Field (what the consumer writes) | ES Internal Field | Translation Rule |
|---|---|---|
| `lifecycle_stage` | `lifecycle_stage` (keyword) | Direct: `eq` → `term`, `in` → `terms` |
| `lifecycle_status` | `lifecycle_status` (keyword) | Direct |
| `custom_score` | `custom_score` (double) | Direct: supports `eq`, `gte`, `lte`, `between` → `range` |
| `properties.email` with `contains "@domain"` | `email_domain` (keyword) | **Rewrite:** Search Service detects `@domain` pattern, strips `@`, and queries the pre-extracted `email_domain` field. The API consumer writes `contains "@acme.com"` — the Search Service translates it to an exact keyword match on `email_domain = "acme.com"`. The consumer doesn't know `email_domain` exists. |
| `properties.email` with `eq` | `email_domain` or direct | Exact match on full email can use keyword |
| `properties.first_name` or `properties.last_name` with `contains` | `full_name` (text, analyzed) | **Rewrite:** Search Service combines into a `match` query on the internal `full_name` field. Consumer filters by `first_name`, Search Service searches the combined field. |
| `custom_properties.*` with `eq` | `custom_fields.*` (flattened) | Direct: `eq` → `term` on flattened field |
| `association.target_type = "opportunity"` with `aggregate.count >= 3` | `opportunity_stats.open_count` (integer) | **Rewrite:** Search Service translates the association aggregate filter into a range query on the pre-computed stats field. Consumer writes a semantic filter ("3+ associated opportunities"), Search Service knows this maps to a flat integer field. |
| `association.target_type = "company"` with `filter.industry = "Technology"` | `company_industries` (keyword array) | **Rewrite:** Search Service translates the association property filter into a `terms` query on the flat keyword array. Consumer writes "associated company in Technology industry", Search Service queries the denormalized `company_industries` array. |
| `created_at`, `updated_at` | `created_at`, `updated_at` (date) | Direct: supports all date operators |

**Example: how the Search Service translates a complex API query:**

The API consumer sends this filter (using API field names only):

```json
POST /v1/crm/objects/contact/search
{
  "filters": {
    "AND": [
      { "field": "lifecycle_stage", "op": "eq", "value": "lead" },
      { "field": "custom_score", "op": "gte", "value": 50 },
      {
        "OR": [
          { "field": "properties.email", "op": "contains", "value": "@acme.com" },
          { "field": "properties.email", "op": "contains", "value": "@bigcorp.com" }
        ]
      },
      {
        "association": {
          "target_type": "opportunity",
          "aggregate": { "op": "count", "compare": "gte", "value": 3 }
        }
      }
    ]
  },
  "sort": [{ "field": "custom_score", "direction": "desc" }],
  "limit": 50
}
```

The Search Service translates this into ES query language (internal — never exposed to the API consumer):

```
Search Service translation steps:
  1. "lifecycle_stage eq lead"
     → { "term": { "lifecycle_stage": "lead" } }                     (direct mapping)

  2. "custom_score gte 50"
     → { "range": { "custom_score": { "gte": 50 } } }               (direct mapping)

  3. "properties.email contains @acme.com"
     → Detect @domain pattern → strip @ → query email_domain field
     → { "term": { "email_domain": "acme.com" } }                    (rewrite)

  4. "properties.email contains @bigcorp.com"
     → { "term": { "email_domain": "bigcorp.com" } }                 (same rewrite)

  5. OR(3, 4) → { "bool": { "should": [...], "minimum_should_match": 1 } }

  6. "association opportunity count >= 3"
     → Map to pre-computed stats field
     → { "range": { "opportunity_stats.open_count": { "gte": 3 } } } (rewrite)

  7. Add mandatory tenant filter:
     → { "term": { "tenant_id": "tenant_abc123" } }                  (always prepended)

  8. Add default active-record filter:
     → { "term": { "lifecycle_status": "active" } }                   (always prepended)

  9. Sort "custom_score desc" → { "custom_score": { "order": "desc" } }

  10. Resolve partition: partition_number=7 → index name "crm_contacts_p07"

  11. Execute: GET crm_contacts_p07/_search { ... }
      → Returns sorted IDs only (_source: false)
```

**The API consumer never sees:** `email_domain`, `opportunity_stats.open_count`, `company_names`, `company_industries`, `full_name`, `custom_fields.*` (flattened), index names like `crm_contacts_p07`, or any ES query syntax. The Search Service is a clean abstraction — it accepts API field names and operators, and internally translates them to whatever ES needs.

**Why this matters:** If we change the ES mapping (rename a field, change the denormalization strategy, switch from ES to a different search engine), the API contract doesn't change. Only the Search Service's translation layer is updated. Every API consumer is shielded from the internal implementation.

### Pagination Strategy

We use **cursor-based pagination** (not offset-based):

- The cursor encodes the sort values of the last returned record (e.g., `{lead_score: 85, created_at: "2026-04-10T14:30:00Z", id: "cont_jane456"}`), base64-encoded.
- The next page query uses `search_after` in ES or a keyset WHERE clause in Postgres.
- This avoids the O(offset) performance degradation of OFFSET/LIMIT and handles concurrent inserts/deletes gracefully.

```sql
-- Keyset pagination in Postgres:
WHERE tenant_id = $1
  AND lifecycle_status = 'active'
  AND (
    (custom_fields->>'lead_score')::int < 85
    OR (
      (custom_fields->>'lead_score')::int = 85
      AND created_at > '2026-04-10T14:30:00Z'
    )
    OR (
      (custom_fields->>'lead_score')::int = 85
      AND created_at = '2026-04-10T14:30:00Z'
      AND id > 'cont_jane456'
    )
  )
ORDER BY (custom_fields->>'lead_score')::int DESC, created_at ASC, id ASC
LIMIT 50;
```

The `total_estimate` in the response is computed differently per storage engine. For Elasticsearch, we use `track_total_hits` with a cap of 10,000 — ES provides an accurate count up to that threshold and an estimate beyond it. For Postgres-routed queries, we do **not** use `COUNT(*) OVER()` (which would force a full scan of all matching rows, negating the benefit of LIMIT). Instead, we use a fast approximation from `pg_class.reltuples` scaled by the filter's estimated selectivity, or omit the count entirely and return `total_estimate: null`. The frontend handles missing counts gracefully by showing 'many results' instead of a number. Exact counts are only computed on explicit user request via a separate `POST /v1/crm/objects/{object_type}/count` endpoint that runs a dedicated `COUNT(*)` query.

---

## 3. Versioning & Evolution

### Versioning Strategy: URL-Based Major + Header-Based Minor

```
Base URL:  /v1/crm/objects/{object_type}
           /v2/crm/objects/{object_type}

Header:    X-API-Version: 2026-04-01  (date-based minor version)
```

**Major versions** (v1, v2) are used for breaking changes: renamed fields, removed fields, changed semantics. We support at most 2 major versions concurrently (current + previous), with a 12-month deprecation window.

**Minor versions** (date-based) are used for additive, non-breaking changes: new fields, new filter operators, new optional parameters. Clients can pin to a specific date to get stable behavior, or omit the header to get the latest.

### Field Lifecycle

Every field has a lifecycle tracked in the API schema:

```
stable → deprecated → removed
```

- **Stable**: Normal use.
- **Deprecated**: Field still present in responses but marked with `"deprecated": true` in the schema. A `Sunset` header is included in responses. Documentation points to the replacement.
- **Removed**: Field no longer appears. Only happens in a new major version.

### Evolution Example: Contact v1 → v2

**Scenario:** We need to:
1. Split the `name` field into `first_name` + `last_name`.
2. Rename `lifecycle` to `lifecycle_stage` for clarity.
3. Add a new `phone_numbers` array (replacing the single `phone` string).

**v1 Contact Response (current):**
```json
{
  "data": {
    "id": "cont_jane456",
    "object_type": "contact",
    "properties": {
      "name": "Jane Doe",
      "email": "jane@acme.com",
      "phone": "+1-555-0100",
      "lifecycle": "lead"
    },
    "custom_properties": { ... }
  }
}
```

**v1 Contact Response (during deprecation period):**
```json
{
  "data": {
    "id": "cont_jane456",
    "object_type": "contact",
    "properties": {
      "name": "Jane Doe",
      "first_name": "Jane",
      "last_name": "Doe",
      "email": "jane@acme.com",
      "phone": "+1-555-0100",
      "phone_numbers": [
        { "type": "mobile", "value": "+1-555-0100", "primary": true }
      ],
      "lifecycle": "lead",
      "lifecycle_stage": "lead"
    }
  }
}
```

During the deprecation window, both old and new fields are returned. Writes to the old field names are accepted and mapped to the new fields internally.

**v2 Contact Response (new):**
```json
{
  "data": {
    "id": "cont_jane456",
    "object_type": "contact",
    "properties": {
      "first_name": "Jane",
      "last_name": "Doe",
      "email": "jane@acme.com",
      "phone_numbers": [
        { "type": "mobile", "value": "+1-555-0100", "primary": true }
      ],
      "lifecycle_stage": "lead"
    }
  }
}
```

### Implementation: Version Translation Layer

The API has a **version translation layer** that sits between the HTTP handler and the domain logic:

```
HTTP Request → Version Translator (inbound) → Domain Logic → Version Translator (outbound) → HTTP Response
```

Internally, the domain always works with the latest schema. The translator handles:

**Inbound (request):**
```java
public class ContactVersionTranslator {

    public InternalContactInput translateRequest(int version, ContactRequestBody body) {
        if (version == 1) {
            var props = body.getProperties();

            // Map old "name" field to new first_name + last_name
            if (props.getName() != null && props.getFirstName() == null) {
                String[] parts = props.getName().split(" ", 2);
                props.setFirstName(parts[0]);
                props.setLastName(parts.length > 1 ? parts[1] : "");
            }

            // Map old "lifecycle" to new "lifecycle_stage"
            if (props.getLifecycle() != null) {
                props.setLifecycleStage(props.getLifecycle());
            }

            // Map old single "phone" to new "phone_numbers" array
            if (props.getPhone() != null && props.getPhoneNumbers() == null) {
                props.setPhoneNumbers(List.of(
                    new PhoneNumber("mobile", props.getPhone(), true)
                ));
            }
        }
        return InternalContactInput.from(body);
    }
}
```

**Outbound (response):**
```java
public ContactResponse translateResponse(int version, InternalContact internal) {
    var response = ContactResponse.from(internal);

    if (version == 1) {
        var props = response.getProperties();

        // Add deprecated fields back for v1 clients
        String fullName = (internal.getFirstName() + " " + internal.getLastName()).trim();
        props.setName(fullName);
        props.setLifecycle(internal.getLifecycleStage());
        props.setPhone(
            internal.getPhoneNumbers().stream()
                .filter(PhoneNumber::isPrimary)
                .map(PhoneNumber::getValue)
                .findFirst()
                .orElse(null)
        );
    }

    return response;
}
```

### Migration Timeline

| Phase | Duration | What Happens |
|---|---|---|
| **Announce** | T+0 | Publish changelog, migration guide, new SDK versions |
| **Dual-serve** | 12 months | v1 and v2 both active. v1 responses include deprecated fields alongside new fields. `Sunset` header on v1 responses. |
| **Warn** | Last 3 months | v1 returns `Warning` header on every response. Dashboard shows v1 usage metrics per API key. |
| **Sunset** | T+12m | v1 returns `410 Gone` with a body explaining the migration path. |

### Webhook Versioning

Webhooks sent by the platform (e.g., "contact.updated") also carry a version:

```json
{
  "webhook_version": "2026-04-01",
  "event": "contact.updated",
  "data": { ... }
}
```

Webhook consumers register with a specific version. When we deprecate a webhook format, consumers receive a migration notice and have 6 months to update their endpoint registration to the new version.

### Webhook Delivery Mechanics

Webhook delivery is handled by a dedicated **Webhook Delivery Service** that consumes change events from Kafka and dispatches HTTP POST requests to registered endpoints.

**Delivery guarantees:**
- **At-least-once delivery.** The delivery service retries failed deliveries with exponential backoff (1s, 5s, 30s, 2min, 10min) up to 5 attempts. After 5 failures, the event is moved to a dead-letter queue and the webhook subscription is marked as `degraded`.
- **Ordering.** Events for the same entity are delivered in order (Kafka partition key ensures this). Events across different entities may arrive out of order.
- **Idempotency.** Each webhook payload includes a unique `event_id`. Consumers should deduplicate by `event_id` to handle retries gracefully.

**Rate limiting:** The delivery service enforces per-endpoint rate limits — at most 100 deliveries/second per registered URL. A tenant with 50 webhook subscriptions all pointing to the same URL shares this limit. If the endpoint cannot keep up, events are queued (up to 10,000 per endpoint) and delivered when the endpoint recovers. Beyond the queue limit, oldest events are dropped and an alert fires.

**Circuit breaking:** If an endpoint returns 5xx errors for >50% of deliveries over a 5-minute window, the circuit breaker opens for that endpoint. No deliveries are attempted for 10 minutes. After the cool-down, the circuit enters half-open state (10% of traffic). If the endpoint recovers, the circuit closes. If it fails again, the endpoint is suspended and the tenant admin is notified via email.

**Payload shape:**
```json
{
  "event_id": "evt_abc123",
  "webhook_version": "2026-04-01",
  "event": "contact.updated",
  "tenant_id": "tenant_abc123",
  "timestamp": "2026-04-10T14:30:00Z",
  "data": {
    "id": "cont_jane456",
    "object_type": "contact",
    "properties": { ... },
    "changed_fields": ["lifecycle_stage"]
  }
}
```

### Adding Custom Fields: A Non-Breaking Change

When a tenant adds a custom field (e.g., "preferred_color"), no API version change is needed:
1. The tenant updates their `custom_object_types.field_schema` via a schema management endpoint.
2. New records can include the field in `custom_properties` (or `properties` for custom objects).
3. The field becomes filterable and sortable immediately (ES dynamic mapping picks it up; the Core CRM Service validates writes against the updated schema).
4. Existing records without the field simply return `null` for it.

This is a key benefit of the JSONB + schema registry approach: custom field evolution is entirely within the tenant's control and never requires an API version bump.

---

## 4. Activity / Timeline API

Activities represent interactions and events attached to any CRM entity. They use the same polymorphic design as Relationships — `entity_type` + `entity_id` — so activities work with core objects and custom objects without additional DDL.

### POST /v1/crm/objects/{object_type}/{id}/activities — Log Activity

```json
POST /v1/crm/objects/contact/cont_jane456/activities
Content-Type: application/json
X-Tenant-Id: tenant_abc123

{
  "activity_type": "call",
  "subject": "Discovery call with Jane",
  "body": "Discussed budget and timeline. Jane wants a proposal by Friday.",
  "occurred_at": "2026-04-10T14:00:00Z",
  "duration_secs": 1800,
  "details": {
    "direction": "outbound",
    "disposition": "connected",
    "phone_number": "+1-555-0100"
  }
}
```

**Response (201 Created):**
```json
{
  "data": {
    "id": "act_call_001",
    "object_type": "activity",
    "tenant_id": "tenant_abc123",
    "entity_type": "contact",
    "entity_id": "cont_jane456",
    "activity_type": "call",
    "subject": "Discovery call with Jane",
    "body": "Discussed budget and timeline. Jane wants a proposal by Friday.",
    "details": {
      "direction": "outbound",
      "disposition": "connected",
      "phone_number": "+1-555-0100"
    },
    "status": "completed",
    "occurred_at": "2026-04-10T14:00:00Z",
    "duration_secs": 1800,
    "owner_id": "user_rep_01",
    "created_at": "2026-04-10T14:35:00Z",
    "updated_at": "2026-04-10T14:35:00Z"
  }
}
```

### GET /v1/crm/objects/{object_type}/{id}/activities — Timeline

Retrieves the activity timeline for any entity, sorted by `occurred_at DESC` (newest first).

```
GET /v1/crm/objects/contact/cont_jane456/activities
    ?activity_types=call,email
    &limit=25
    &cursor=...
X-Tenant-Id: tenant_abc123
```

**Response (200 OK):**
```json
{
  "data": [
    {
      "id": "act_call_001",
      "activity_type": "call",
      "subject": "Discovery call with Jane",
      "status": "completed",
      "occurred_at": "2026-04-10T14:00:00Z",
      "duration_secs": 1800,
      "owner_id": "user_rep_01"
    },
    {
      "id": "act_email_005",
      "activity_type": "email",
      "subject": "Re: Proposal follow-up",
      "status": "completed",
      "occurred_at": "2026-04-09T10:30:00Z",
      "details": { "direction": "inbound", "tracking": { "opened": true } },
      "owner_id": "user_rep_01"
    }
  ],
  "paging": {
    "next_cursor": "eyJ0IjoxNzEyNjc4MjAwfQ==",
    "has_more": true
  }
}
```

### Automation Triggers on Activities

Activities are first-class trigger sources in the automation engine. When an activity is created or updated, the CDC pipeline emits an event to `cdc.crm.activities`. The `automation-trigger-evaluator` consumer evaluates these events against activity-based rules in addition to field-change rules.

**Rule definition examples:**

```json
// Trigger: "When an outbound email is logged on a contact, increment engagement score"
{
  "id": "rule_email_engagement",
  "tenant_id": "tenant_abc123",
  "trigger_source": "activity",
  "trigger_event": "create",
  "trigger_conditions": {
    "activity_type": "email",
    "details.direction": "outbound"
  },
  "entity_type": "contact",
  "action": "update_field",
  "action_params": {
    "field": "custom_properties.engagement_score",
    "operation": "increment",
    "value": 5
  }
}

// Trigger: "When a meeting is completed for an opportunity, create a follow-up task"
{
  "id": "rule_meeting_followup",
  "tenant_id": "tenant_abc123",
  "trigger_source": "activity",
  "trigger_event": "create",
  "trigger_conditions": {
    "activity_type": "meeting",
    "status": "completed"
  },
  "entity_type": "opportunity",
  "action": "create_activity",
  "action_params": {
    "activity_type": "task",
    "subject": "Follow up on meeting: {{activity.subject}}",
    "details": { "priority": "high", "task_type": "follow_up", "due_date": "{{today+3d}}" },
    "status": "open"
  }
}
```

**Trigger evaluation flow for activities:**

```
Activity created/updated in Postgres
    → CDC (Debezium) emits event to cdc.crm.activities
    → automation-trigger-evaluator consumer:
        1. Reads activity_type, status, details from event payload
        2. Loads tenant's trigger rules from local cache (30s TTL)
        3. Filters rules where trigger_source = 'activity'
        4. Evaluates trigger_conditions against the activity event
        5. For matched rules: enqueues action to Action Queue
    → Action Queue executes: update_field, create_activity, send_email, call_webhook, etc.
```

This architecture means automations trigger on both **data changes** (field updates, stage transitions) and **behavioral signals** (calls logged, emails sent, meetings completed). The two trigger sources share the same evaluation engine, action queue, and execution infrastructure — they differ only in the event payload shape and the condition matching logic.

### Automation Rule Conflict Resolution

When multiple rules match the same CDC event, they are evaluated using **snapshot semantics** — all rules see the original CDC event payload, not the entity state modified by earlier rules' actions. Rules are processed sequentially in `execution_order` (lower = first), but each rule evaluates its `trigger_conditions` against the same immutable event snapshot.

**Example:** A contact's `lifecycle_stage` changes from `lead` to `sql`. Two rules match:
- Rule A (`execution_order: 1`): "When lifecycle_stage = sql → create follow-up task"
- Rule B (`execution_order: 2`): "When lifecycle_stage = sql → send email to sales manager"

Both rules see `{"changed_fields": {"lifecycle_stage": {"old": "lead", "new": "sql"}}}` from the CDC event. Rule A fires first and creates a task. Rule B fires second and sends an email. Rule B does not re-read the contact to check if Rule A changed anything — it evaluates against the original event.

**If conflicting actions occur** (e.g., two rules both set `lifecycle_stage` to different values), the rule with the lower `execution_order` wins. The second rule's action generates a new CDC event, which is evaluated independently in the next cycle. This prevents infinite loops — each evaluation cycle processes only the events from the previous write, not the actions triggered by the current cycle.

### Automation Action Idempotency

CDC events can be replayed (Kafka consumer restart, rebalance, or manual replay for recovery). Without idempotency, a replayed event would re-match rules and re-execute actions — sending duplicate emails, creating duplicate tasks, or double-incrementing a field. The automation engine prevents this with a deterministic execution key.

**Execution key computation:**

```
execution_key = SHA-256(tenant_id + rule_id + entity_id + cdc_event_id)
```

The `cdc_event_id` is the Kafka topic-partition-offset (e.g., `cdc.crm.contacts:12:48291037`) — a globally unique identifier for each CDC event. This makes the execution key deterministic: the same event replayed against the same rule for the same entity always produces the same key.

**Deduplication flow:**

```
1. Automation evaluator matches a rule against an incoming CDC event
2. Compute execution_key = SHA-256(tenant_id + rule_id + entity_id + cdc_event_id)
3. INSERT INTO automation_execution_log (execution_key, ...)
   ON CONFLICT (tenant_id, execution_key) DO NOTHING
   RETURNING id
4. If INSERT returned a row → new execution → enqueue action to Action Queue
5. If INSERT returned nothing → duplicate → skip (log as 'skipped' for observability)
```

The `automation_execution_log` table has a unique index on `(tenant_id, execution_key)`, so the dedup check is a single atomic INSERT that races safely under concurrency. No distributed locks, no Redis coordination — the database is the source of truth for execution state.

**Execution log lifecycle:**
- Entries are created with `status = 'pending'` before the action is enqueued.
- The action executor updates `status` to `'succeeded'` or `'failed'` after execution.
- Failed executions can be retried manually or via a background retry job (configurable per tenant).
- Execution log is range-partitioned monthly (same pattern as `change_log`). Partitions older than 90 days are archived — the log is operational, not compliance-mandated.

---

## 5. Scoring Rules API

Each tenant can define one scoring formula per entity type (contact, company, opportunity). The Core CRM Service computes `custom_score` on every write using the scoring rule cached from the Tenant Service. When a rule changes, a background job recomputes all existing scores for that entity type.

### PUT /v1/crm/tenant/scoring-rules/{entity_type} — Create or Update Scoring Rule

```json
PUT /v1/crm/tenant/scoring-rules/contact
Content-Type: application/json
X-Tenant-Id: tenant_abc123

{
  "label": "Lead Score",
  "formula_type": "weighted_sum",
  "formula_config": {
    "fields": [
      { "source": "custom_fields.engagement", "weight": 0.5, "max": 100 },
      { "source": "custom_fields.company_fit", "weight": 0.3, "max": 100 },
      { "source": "custom_fields.recency",     "weight": 0.2, "max": 100 }
    ]
  },
  "default_value": 0
}
```

**Response (200 OK):**
```json
{
  "data": {
    "tenant_id": "tenant_abc123",
    "entity_type": "contact",
    "label": "Lead Score",
    "formula_type": "weighted_sum",
    "formula_config": { ... },
    "default_value": 0,
    "is_enabled": true,
    "created_at": "2026-04-11T10:00:00Z",
    "updated_at": "2026-04-11T10:00:00Z"
  },
  "recompute": {
    "status": "queued",
    "estimated_records": 2400000,
    "message": "Scoring rule updated. Recomputing custom_score for all contacts in background."
  }
}
```

When a rule is created or updated, the response includes a `recompute` block indicating that a background job has been queued to recompute all existing scores. New records created during the recompute use the new rule immediately (the cache is invalidated on write).

### GET /v1/crm/tenant/scoring-rules/{entity_type} — Read Scoring Rule

```
GET /v1/crm/tenant/scoring-rules/contact
X-Tenant-Id: tenant_abc123
```

Returns the current scoring rule for the entity type, or `404` if none is defined.

### DELETE /v1/crm/tenant/scoring-rules/{entity_type} — Remove Scoring Rule

Removes the scoring rule. All existing `custom_score` values for that entity type are set to `NULL` via a background job.

### Supported Formula Types

| Formula Type | Description | Example |
|---|---|---|
| `weighted_sum` | Sum of (field_value × weight) for each configured field. Fields capped at optional `max` | `0.5 × engagement + 0.3 × company_fit + 0.2 × recency` |
| `max_of` | Maximum value across configured fields | `max(engagement, company_fit, recency)` |
| `conditional` | First matching condition determines the score. Falls through to `else` | `if risk_tier = 'high' → 90; if 'medium' → 50; else → 10` |

---

## 6. Idempotency

All mutating endpoints (POST, PATCH, DELETE) accept an `Idempotency-Key` header. This ensures that retried requests (due to network timeouts, client crashes, etc.) do not produce duplicate side effects.

**How it works:**

- The key is a client-generated UUID included in the request header: `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000`
- The server stores the key in Redis with a TTL of 24 hours.
- If a request arrives with a key that was already processed, the server returns the stored response without re-executing the operation. The response includes the same status code, headers, and body as the original.
- For batch operations, the idempotency key covers the entire batch — not individual operations within it.
- Keys are scoped to `tenant_id`. The same key from different tenants is treated as different (the Redis key is `idempotency:{tenant_id}:{key}`).

**Implementation:**

```
1. Receive request with Idempotency-Key header
2. SET NX idempotency:{tenant_id}:{key} → "processing" (with TTL 24h)
3. If SET NX fails (key exists):
   a. Read the stored value
   b. If status is "processing" → return 409 Conflict ("request in progress")
   c. If status is "completed" → return the cached response
4. If SET NX succeeds:
   a. Process the request
   b. Store the response: SET idempotency:{tenant_id}:{key} → {status: "completed", response: ...}
   c. Return the response
```

**Example:**
```
POST /v1/crm/objects/contact
X-Tenant-Id: tenant_abc123
Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
Content-Type: application/json

{ ... }
```

If the client retries this request (same `Idempotency-Key`), the server returns the previously created contact without creating a duplicate.
