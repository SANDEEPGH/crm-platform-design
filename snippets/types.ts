// =============================================================================
// CRM Platform – API Contract Types
// =============================================================================

// --- Core Enums & Primitives ---

type ObjectType =
  | 'contact'
  | 'company'
  | 'opportunity'
  | 'pipeline'
  | string; // custom object slugs: 'policy', 'vehicle', etc.

type LifecycleStatus = 'active' | 'archived' | 'deleted' | 'merged';
type OpportunityStatus = 'active' | 'won' | 'lost' | 'deleted';
type LifecycleStage = 'subscriber' | 'lead' | 'mql' | 'sql' | 'customer' | 'evangelist';
type PlanTier = 'standard' | 'professional' | 'enterprise';

// --- Tenant Metadata (used internally for routing, not exposed in object API) ---

interface TenantMetadata {
  id: string;
  name: string;
  slug: string;
  plan_tier: PlanTier;
  partition_number: number;    // 0-59 shared, 60-63 dedicated. Assigned by Tenant Service at onboarding.
  estimated_weight: number;    // capacity estimate at signup (weight units)
  actual_weight: number;       // updated nightly from real row counts
  settings: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

interface CapacityEstimate {
  contacts: number;
  companies: number;
  opportunities: number;
  activities_per_contact: number;
}

type MigrationStatus = 'pending' | 'dual_writing' | 'backfilling' | 'cutting_over' | 'completed' | 'rolled_back';

interface TenantMigration {
  id: string;
  tenant_id: string;
  source_partition: number;
  target_partition: number;
  status: MigrationStatus;
  rows_backfilled: number;
  rows_total: number;
  started_at: string;
  completed_at?: string;
}

// --- System Fields (present on every object) ---

interface SystemFields {
  id: string;
  object_type: ObjectType;
  tenant_id: string;
  lifecycle_status: LifecycleStatus;
  created_at: string; // ISO 8601
  updated_at: string; // ISO 8601
  created_by?: string;
  updated_by?: string;
}

// --- Association ---

interface AssociationInput {
  target_type: ObjectType;
  target_id: string;
  relation_kind: string;
}

interface Association extends AssociationInput {
  id: string;
  target_snapshot?: Record<string, unknown>; // lightweight preview of related object
}

// --- Generic Object Envelope ---

interface CrmObject<P = Record<string, unknown>> extends SystemFields {
  properties: P;
  custom_properties?: Record<string, unknown>;
  associations?: Association[];
}

// --- Concrete Property Shapes ---

interface ContactProperties {
  external_id?: string;   // caller-supplied ID for CRM migration / sync (e.g. Salesforce ID)
  email?: string;
  first_name?: string;
  last_name?: string;
  phone?: string;
  lifecycle_stage: LifecycleStage;
  custom_score?: number;  // tenant-defined composite score (computed by application from scoring_rules)
}

interface CompanyProperties {
  external_id?: string;
  name: string;
  domain?: string;
  industry?: string;
  employee_count?: number;
  annual_revenue?: number;
  custom_score?: number;
}

interface OpportunityProperties {
  external_id?: string;
  name: string;
  pipeline_id: string;
  custom_score?: number;
  stage_id: string;
  amount?: number;
  currency: string;
  expected_close?: string; // ISO 8601 date
  probability?: number;
  owner_id?: string;
}

interface PipelineProperties {
  name: string;
  stages: PipelineStage[];
  is_default: boolean;
}

interface PipelineStage {
  id: string;
  name: string;
  position: number;
  type: 'open' | 'won' | 'lost';
}

// --- Create Request ---

interface CreateObjectRequest<P = Record<string, unknown>> {
  properties: P;
  custom_properties?: Record<string, unknown>;
  associations?: AssociationInput[];
}

// --- Update Request (partial) ---

interface UpdateObjectRequest {
  properties?: Record<string, unknown>;
  custom_properties?: Record<string, unknown>;
  associations_to_add?: AssociationInput[];
  associations_to_remove?: string[]; // relationship IDs to remove
}

// --- Delete Response ---

interface DeleteObjectResponse {
  data: CrmObject;  // object with lifecycle_status: 'deleted', deleted_at set
}

// --- Single Object Response ---

interface ObjectResponse<P = Record<string, unknown>> {
  data: CrmObject<P>;
}

// --- List Response ---

interface ListResponse<P = Record<string, unknown>> {
  data: CrmObject<P>[];
  paging: PagingInfo;
  metadata: QueryMetadata;
}

interface PagingInfo {
  next_cursor: string | null;
  has_more: boolean;
  total_estimate?: number;
}

interface QueryMetadata {
  source: 'database' | 'search_index';
  index_lag_ms?: number;
}

// --- Batch Operations ---

type BatchAction = 'create' | 'update' | 'delete';

interface BatchOperation {
  action: BatchAction;
  id?: string;                          // required for update/delete
  properties?: Record<string, unknown>;
  custom_properties?: Record<string, unknown>;
  associations?: AssociationInput[];
}

interface BatchRequest {
  operations: BatchOperation[];         // max 100
}

interface BatchOperationResult {
  index: number;
  status: 'success' | 'error';
  data?: CrmObject;
  error?: {
    code: string;
    message: string;
    details?: Array<{ field: string; issue: string }>;
  };
}

interface BatchResponse {
  results: BatchOperationResult[];
  summary: {
    total: number;
    succeeded: number;
    failed: number;
  };
}

// --- Filter / Query Model ---

type FilterNode = FilterCondition | FilterGroup | AssociationFilter;

interface FilterCondition {
  field: string;
  op: FilterOperator;
  value: unknown;
}

type FilterOperator =
  | 'eq' | 'neq'
  | 'gt' | 'gte' | 'lt' | 'lte'
  | 'in' | 'nin'
  | 'contains' | 'starts_with'
  | 'is_set' | 'is_not_set'
  | 'between';

interface FilterGroup {
  AND?: FilterNode[];
  OR?: FilterNode[];
}

interface AssociationFilter {
  association: {
    target_type: ObjectType;
    relation_kind?: string;
    filter?: FilterGroup;
    aggregate?: {
      op: 'count' | 'sum' | 'avg' | 'min' | 'max';
      field?: string;     // required for sum/avg/min/max
      compare: 'eq' | 'gt' | 'gte' | 'lt' | 'lte';
      value: number;
    };
  };
}

interface SortClause {
  field: string;
  direction: 'asc' | 'desc';
}

interface SearchRequest {
  filters?: FilterGroup;
  sort?: SortClause[];
  cursor?: string | null;
  limit?: number;          // default 50, max 200
  fields?: string[];       // sparse fieldset
}

// --- Export / Import Jobs ---

type ExportStatus = 'pending' | 'processing' | 'completed' | 'failed';

interface ExportJobResponse {
  id: string;
  status: ExportStatus;
  object_type: ObjectType;
  filters?: FilterGroup;
  total_records?: number;
  download_url?: string;    // present when status is 'completed'
  expires_at?: string;      // download URL expiry
  created_at: string;
  completed_at?: string;
  error?: string;
}

interface ImportJobRequest {
  object_type: ObjectType;
  file_url: string;         // S3 pre-signed URL to uploaded file
  format: 'csv' | 'ndjson';
  dedup_field?: string;     // field to use for deduplication (e.g., 'email', 'external_id')
  on_duplicate?: 'skip' | 'update' | 'error';
}

interface ImportJobResponse {
  id: string;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  object_type: ObjectType;
  total_rows?: number;
  processed_rows?: number;
  success_count?: number;
  error_count?: number;
  error_report_url?: string;
  created_at: string;
  completed_at?: string;
}

// --- Custom Object Type Definition ---

interface CustomObjectTypeDefinition {
  id: string;
  tenant_id: string;
  slug: string;
  display_name: string;
  description?: string;
  field_schema: FieldDefinition[];
  schema_version: number;
  icon?: string;
  lifecycle_status: 'active' | 'archived';
  created_at: string;
  updated_at: string;
}

interface FieldDefinition {
  key: string;
  label: string;
  type: FieldType;
  required: boolean;
  unique_per_tenant?: boolean;
  indexed?: boolean;
  default_value?: unknown;
  options?: string[];       // for enum / multi_enum types
  reference_type?: string;  // for 'reference' type: which object_type it points to
  sensitive?: boolean;      // field-level encryption for PII
}

type FieldType =
  | 'text'
  | 'number'
  | 'currency'
  | 'date'
  | 'datetime'
  | 'boolean'
  | 'enum'
  | 'multi_enum'
  | 'url'
  | 'email'
  | 'phone'
  | 'reference';

// --- Custom Object Type Version History ---

interface CustomObjectTypeVersion {
  id: string;
  tenant_id: string;
  object_type_id: string;
  version: number;
  field_schema: FieldDefinition[];
  migration_ops?: Array<{
    op: 'add_field' | 'remove_field' | 'rename_field' | 'change_type';
    key: string;
    new_key?: string;
    [key: string]: unknown;
  }>;
  created_by?: string;
  created_at: string;
}

// --- Activity / Timeline ---

type ActivityType = 'email' | 'call' | 'meeting' | 'note' | 'task' | 'custom';
type ActivityStatus = 'open' | 'completed' | 'canceled';

interface Activity extends SystemFields {
  entity_type: ObjectType;
  entity_id: string;
  activity_type: ActivityType;
  subject?: string;
  body?: string;
  details: Record<string, unknown>;
  status: ActivityStatus;
  occurred_at: string;  // ISO 8601
  duration_secs?: number;
  owner_id?: string;
}

interface CreateActivityRequest {
  entity_type: ObjectType;
  entity_id: string;
  activity_type: ActivityType;
  subject?: string;
  body?: string;
  details?: Record<string, unknown>;
  status?: ActivityStatus;
  occurred_at: string;
  duration_secs?: number;
  owner_id?: string;
}

interface ActivityListRequest {
  entity_type: ObjectType;
  entity_id: string;
  activity_types?: ActivityType[];  // filter to specific types
  sort?: SortClause[];
  cursor?: string | null;
  limit?: number;
}

interface ActivityListResponse {
  data: Activity[];
  paging: PagingInfo;
}

// --- Scoring Rules ---

type ScoringFormulaType = 'weighted_sum' | 'max_of' | 'conditional';

interface ScoringRule {
  tenant_id: string;
  entity_type: ObjectType;
  label: string;
  formula_type: ScoringFormulaType;
  formula_config: Record<string, unknown>;
  default_value: number;
  is_enabled: boolean;
  updated_by?: string;
  created_at: string;
  updated_at: string;
}

// --- Automation Rules ---

type TriggerSource = 'field_change' | 'activity';
type TriggerEvent = 'create' | 'update' | 'delete';
type AutomationAction = 'update_field' | 'create_activity' | 'send_email' | 'call_webhook';
type AutomationExecutionStatus = 'pending' | 'succeeded' | 'failed' | 'skipped';

interface AutomationRule {
  id: string;
  tenant_id: string;
  name: string;
  description?: string;
  trigger_source: TriggerSource;
  trigger_event: TriggerEvent;
  entity_type: ObjectType;
  trigger_conditions: Record<string, unknown>;
  action: AutomationAction;
  action_params: Record<string, unknown>;
  is_enabled: boolean;
  execution_order: number;
  created_by?: string;
  updated_by?: string;
  created_at: string;
  updated_at: string;
}

interface AutomationExecutionLogEntry {
  id: string;
  tenant_id: string;
  rule_id: string;
  entity_type: ObjectType;
  entity_id: string;
  cdc_event_id: string;
  execution_key: string;
  action: AutomationAction;
  action_params: Record<string, unknown>;
  status: AutomationExecutionStatus;
  error_message?: string;
  created_at: string;
  completed_at?: string;
}

// --- Webhook Subscriptions ---

type WebhookCircuitState = 'closed' | 'open' | 'half_open';
type WebhookSubscriptionStatus = 'active' | 'degraded' | 'suspended';
type WebhookDeliveryStatus = 'pending' | 'delivered' | 'failed' | 'dead_lettered';

interface WebhookSubscription {
  id: string;
  tenant_id: string;
  url: string;
  events: string[];              // e.g. ['contact.created', 'opportunity.won']
  webhook_version: string;
  is_enabled: boolean;
  status: WebhookSubscriptionStatus;
  circuit_state: WebhookCircuitState;
  max_rate_per_sec: number;
  created_by?: string;
  created_at: string;
  updated_at: string;
}

interface WebhookDeliveryLogEntry {
  id: string;
  tenant_id: string;
  subscription_id: string;
  event_id: string;
  event_type: string;
  http_status?: number;
  attempt: number;
  status: WebhookDeliveryStatus;
  error_message?: string;
  latency_ms?: number;
  created_at: string;
}

// --- Change Log / Audit Event ---

interface ChangeLogEntry {
  id: string;
  tenant_id: string;
  entity_type: ObjectType;
  entity_id: string;
  action: 'create' | 'update' | 'delete' | 'merge' | 'stage_change' | 'archive' | 'restore';
  changed_fields?: Record<string, { old: unknown; new: unknown }>;
  actor_id?: string;
  created_at: string;
}

// --- Error Response ---

interface ErrorResponse {
  error: {
    code: string;          // e.g., 'VALIDATION_FAILED', 'NOT_FOUND', 'RATE_LIMITED'
    message: string;
    details?: Array<{
      field: string;
      issue: string;
    }>;
    request_id: string;
  };
}

export type {
  ObjectType,
  LifecycleStatus,
  CrmObject,
  ContactProperties,
  CompanyProperties,
  OpportunityProperties,
  PipelineProperties,
  CreateObjectRequest,
  UpdateObjectRequest,
  DeleteObjectResponse,
  ObjectResponse,
  ListResponse,
  SearchRequest,
  FilterNode,
  FilterGroup,
  AssociationFilter,
  BatchAction,
  BatchOperation,
  BatchRequest,
  BatchOperationResult,
  BatchResponse,
  ExportStatus,
  ExportJobResponse,
  ImportJobRequest,
  ImportJobResponse,
  CustomObjectTypeDefinition,
  CustomObjectTypeVersion,
  FieldDefinition,
  Activity,
  ActivityType,
  ActivityStatus,
  CreateActivityRequest,
  ActivityListRequest,
  ActivityListResponse,
  ScoringRule,
  AutomationRule,
  AutomationExecutionLogEntry,
  WebhookSubscription,
  WebhookDeliveryLogEntry,
  ChangeLogEntry,
  ErrorResponse,
};
