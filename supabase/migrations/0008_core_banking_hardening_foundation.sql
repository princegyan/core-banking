-- ============================================================
-- CORE BANKING HARDENING FOUNDATION
-- Migration: 0008
-- ============================================================

begin;

-- ============================================================
-- 1. ENUMS
-- ============================================================

do $$
begin
  if not exists (
    select 1
    from pg_type
    where typname = 'business_date_status'
  ) then
    create type business_date_status as enum (
      'OPEN',
      'EOD_IN_PROGRESS',
      'CLOSED'
    );
  end if;

  if not exists (
    select 1
    from pg_type
    where typname = 'accounting_period_status'
  ) then
    create type accounting_period_status as enum (
      'OPEN',
      'CLOSED'
    );
  end if;

  if not exists (
    select 1
    from pg_type
    where typname = 'approval_request_status'
  ) then
    create type approval_request_status as enum (
      'PENDING',
      'APPROVED',
      'REJECTED',
      'CANCELLED'
    );
  end if;
end $$;


-- ============================================================
-- 2. BUSINESS DATES
-- ============================================================

create table if not exists business_dates (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  business_date date not null,

  status business_date_status not null default 'OPEN',

  opened_at timestamptz not null default now(),
  closed_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint business_dates_tenant_date_unique
    unique (tenant_id, business_date),

  constraint business_dates_closed_at_check
    check (
      (status = 'CLOSED' and closed_at is not null)
      or
      (status <> 'CLOSED')
    )
);

create index if not exists idx_business_dates_tenant
  on business_dates(tenant_id);

create index if not exists idx_business_dates_tenant_status
  on business_dates(tenant_id, status);


-- Only one OPEN/EOD business date per tenant.
create unique index if not exists uq_business_dates_active
  on business_dates(tenant_id)
  where status in ('OPEN', 'EOD_IN_PROGRESS');


-- ============================================================
-- 3. ACCOUNTING PERIODS
-- ============================================================

create table if not exists accounting_periods (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  period_name varchar(100) not null,

  start_date date not null,
  end_date date not null,

  status accounting_period_status not null default 'OPEN',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint accounting_periods_date_range_check
    check (end_date >= start_date),

  constraint accounting_periods_tenant_name_unique
    unique (tenant_id, period_name)
);

create index if not exists idx_accounting_periods_tenant
  on accounting_periods(tenant_id);

create index if not exists idx_accounting_periods_dates
  on accounting_periods(tenant_id, start_date, end_date);

create unique index if not exists uq_accounting_periods_open
  on accounting_periods(tenant_id)
  where status = 'OPEN';


-- ============================================================
-- 4. TRANSACTION LIFECYCLE HARDENING
-- ============================================================

alter table transactions
  add column if not exists business_date_id uuid
    references business_dates(id)
    on delete restrict;

alter table transactions
  add column if not exists accounting_period_id uuid
    references accounting_periods(id)
    on delete restrict;

alter table transactions
  add column if not exists value_date date;

alter table transactions
  add column if not exists channel varchar(50);

alter table transactions
  add column if not exists reversal_of_transaction_id uuid
    references transactions(id)
    on delete restrict;

alter table transactions
  add column if not exists approved_by uuid
    references users(id)
    on delete restrict;

alter table transactions
  add column if not exists approved_at timestamptz;


create index if not exists idx_transactions_business_date
  on transactions(tenant_id, business_date_id);

create index if not exists idx_transactions_accounting_period
  on transactions(tenant_id, accounting_period_id);

create index if not exists idx_transactions_value_date
  on transactions(tenant_id, value_date);

create index if not exists idx_transactions_reversal
  on transactions(reversal_of_transaction_id);


-- Prevent a transaction from reversing itself.
alter table transactions
  drop constraint if exists transactions_no_self_reversal;

alter table transactions
  add constraint transactions_no_self_reversal
  check (
    reversal_of_transaction_id is null
    or reversal_of_transaction_id <> id
  );


-- ============================================================
-- 5. PRODUCT GL MAPPINGS
-- ============================================================

create table if not exists product_gl_mappings (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  product_id uuid not null
    references account_products(id)
    on delete cascade,

  mapping_code varchar(50) not null,

  ledger_account_id uuid not null
    references ledger_accounts(id)
    on delete restrict,

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint product_gl_mappings_unique
    unique (tenant_id, product_id, mapping_code)
);

create index if not exists idx_product_gl_mappings_tenant
  on product_gl_mappings(tenant_id);

create index if not exists idx_product_gl_mappings_product
  on product_gl_mappings(product_id);

create index if not exists idx_product_gl_mappings_ledger
  on product_gl_mappings(ledger_account_id);


-- ============================================================
-- 6. MAKER-CHECKER / APPROVAL FOUNDATION
-- ============================================================

create table if not exists approval_requests (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  request_type varchar(100) not null,

  entity_type varchar(100) not null,
  entity_id uuid not null,

  status approval_request_status not null default 'PENDING',

  requested_by uuid not null
    references users(id)
    on delete restrict,

  approved_by uuid
    references users(id)
    on delete restrict,

  requested_at timestamptz not null default now(),

  approved_at timestamptz,
  rejected_at timestamptz,

  rejection_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint approval_requests_approval_consistency
    check (
      (
        status = 'APPROVED'
        and approved_by is not null
        and approved_at is not null
      )
      or
      status <> 'APPROVED'
    ),

  constraint approval_requests_rejection_consistency
    check (
      (
        status = 'REJECTED'
        and rejected_at is not null
      )
      or
      status <> 'REJECTED'
    )
);

create index if not exists idx_approval_requests_tenant
  on approval_requests(tenant_id);

create index if not exists idx_approval_requests_status
  on approval_requests(tenant_id, status);

create index if not exists idx_approval_requests_entity
  on approval_requests(tenant_id, entity_type, entity_id);

create index if not exists idx_approval_requests_requested_by
  on approval_requests(requested_by);


-- ============================================================
-- 7. AUDIT LOG FOUNDATION
-- ============================================================

create table if not exists audit_logs (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  user_id uuid
    references users(id)
    on delete set null,

  action varchar(100) not null,

  entity_type varchar(100) not null,
  entity_id uuid,

  old_values jsonb,
  new_values jsonb,

  ip_address inet,
  user_agent text,

  created_at timestamptz not null default now()
);

create index if not exists idx_audit_logs_tenant
  on audit_logs(tenant_id, created_at desc);

create index if not exists idx_audit_logs_user
  on audit_logs(tenant_id, user_id, created_at desc);

create index if not exists idx_audit_logs_entity
  on audit_logs(tenant_id, entity_type, entity_id, created_at desc);

create index if not exists idx_audit_logs_action
  on audit_logs(tenant_id, action, created_at desc);


-- ============================================================
-- 8. TRANSACTION CONTROL FOUNDATION
-- ============================================================

create table if not exists transaction_controls (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  product_id uuid
    references account_products(id)
    on delete cascade,

  transaction_type varchar(50) not null,

  minimum_amount bigint,
  maximum_amount bigint,

  daily_limit bigint,

  requires_approval boolean not null default false,

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint transaction_controls_amount_check
    check (
      (minimum_amount is null or minimum_amount >= 0)
      and
      (maximum_amount is null or maximum_amount >= 0)
      and
      (daily_limit is null or daily_limit >= 0)
    ),

  constraint transaction_controls_range_check
    check (
      maximum_amount is null
      or minimum_amount is null
      or maximum_amount >= minimum_amount
    )
);

create index if not exists idx_transaction_controls_tenant
  on transaction_controls(tenant_id);

create index if not exists idx_transaction_controls_product
  on transaction_controls(product_id);

create index if not exists idx_transaction_controls_type
  on transaction_controls(
    tenant_id,
    transaction_type
  );


create unique index if not exists uq_transaction_controls_product_type
  on transaction_controls(
    tenant_id,
    product_id,
    transaction_type
  )
  where product_id is not null;


create unique index if not exists uq_transaction_controls_tenant_type
  on transaction_controls(
    tenant_id,
    transaction_type
  )
  where product_id is null;


-- ============================================================
-- 9. UPDATED_AT TRIGGERS
-- ============================================================

drop trigger if exists trg_business_dates_updated_at
  on business_dates;

create trigger trg_business_dates_updated_at
before update on business_dates
for each row
execute function update_updated_at();


drop trigger if exists trg_accounting_periods_updated_at
  on accounting_periods;

create trigger trg_accounting_periods_updated_at
before update on accounting_periods
for each row
execute function update_updated_at();


drop trigger if exists trg_product_gl_mappings_updated_at
  on product_gl_mappings;

create trigger trg_product_gl_mappings_updated_at
before update on product_gl_mappings
for each row
execute function update_updated_at();


drop trigger if exists trg_approval_requests_updated_at
  on approval_requests;

create trigger trg_approval_requests_updated_at
before update on approval_requests
for each row
execute function update_updated_at();


drop trigger if exists trg_transaction_controls_updated_at
  on transaction_controls;

create trigger trg_transaction_controls_updated_at
before update on transaction_controls
for each row
execute function update_updated_at();


-- ============================================================
-- 10. COMMENTS
-- ============================================================

comment on table business_dates is
  'Tenant banking business dates used for transaction and EOD processing.';

comment on table accounting_periods is
  'Tenant accounting periods used for financial reporting and period control.';

comment on table product_gl_mappings is
  'Maps banking products and accounting purposes to GL/control ledger accounts.';

comment on table approval_requests is
  'Maker-checker approval workflow foundation for controlled banking operations.';

comment on table audit_logs is
  'Immutable-style application audit trail for financial and administrative activity.';

comment on table transaction_controls is
  'Foundation for transaction limits and approval thresholds.';

commit;