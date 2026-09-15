-- ============================================================
-- Ledger Engine v1
-- ============================================================

create type ledger_account_type as enum (
  'ASSET',
  'LIABILITY',
  'EQUITY',
  'INCOME',
  'EXPENSE'
);

create type transaction_status as enum (
  'PENDING',
  'POSTED',
  'REVERSED',
  'FAILED'
);

-- ============================================================
-- LEDGER ACCOUNTS
-- ============================================================

create table ledger_accounts (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  account_code varchar(50) not null,
  account_name varchar(150) not null,

  account_type ledger_account_type not null,

  parent_account_id uuid null
    references ledger_accounts(id)
    on delete restrict,

  currency varchar(3) not null default 'GHS',

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint ledger_accounts_code_unique
    unique (tenant_id, account_code)
);

create index idx_ledger_accounts_tenant
  on ledger_accounts(tenant_id);

create index idx_ledger_accounts_parent
  on ledger_accounts(parent_account_id);

-- ============================================================
-- TRANSACTIONS
-- ============================================================

create table transactions (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  reference varchar(100) not null,

  transaction_type varchar(50) not null,

  status transaction_status not null default 'PENDING',

  currency varchar(3) not null default 'GHS',

  amount bigint not null,

  description text,

  idempotency_key varchar(150),

  posted_at timestamptz,

  created_by uuid null
    references users(id)
    on delete set null,

  created_at timestamptz not null default now(),

  constraint transactions_amount_positive
    check (amount > 0),

  constraint transactions_reference_unique
    unique (tenant_id, reference),

  constraint transactions_idempotency_unique
    unique (tenant_id, idempotency_key)
);

create index idx_transactions_tenant
  on transactions(tenant_id);

create index idx_transactions_status
  on transactions(tenant_id, status);

create index idx_transactions_created_at
  on transactions(tenant_id, created_at);

-- ============================================================
-- TRANSACTION ENTRIES
-- ============================================================

create table transaction_entries (
  id uuid primary key default gen_random_uuid(),

  transaction_id uuid not null
    references transactions(id)
    on delete restrict,

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  ledger_account_id uuid not null
    references ledger_accounts(id)
    on delete restrict,

  debit bigint not null default 0,

  credit bigint not null default 0,

  description text,

  created_at timestamptz not null default now(),

  constraint transaction_entries_amount_check
    check (
      (debit > 0 and credit = 0)
      or
      (credit > 0 and debit = 0)
    )
);

create index idx_transaction_entries_transaction
  on transaction_entries(transaction_id);

create index idx_transaction_entries_ledger_account
  on transaction_entries(ledger_account_id);

create index idx_transaction_entries_tenant
  on transaction_entries(tenant_id);

-- ============================================================
-- UPDATED_AT
-- ============================================================

create trigger trg_ledger_accounts_updated_at
before update on ledger_accounts
for each row
execute function update_updated_at();