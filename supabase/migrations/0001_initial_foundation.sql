create extension if not exists "pgcrypto";

-- ============================================================
-- ENUMS
-- ============================================================

create type tenant_status as enum (
    'ACTIVE',
    'SUSPENDED',
    'PENDING'
);

create type customer_type as enum (
    'INDIVIDUAL',
    'BUSINESS'
);

create type customer_status as enum (
    'ACTIVE',
    'INACTIVE',
    'BLOCKED'
);

create type kyc_status as enum (
    'PENDING',
    'VERIFIED',
    'REJECTED',
    'EXPIRED'
);

create type account_status as enum (
    'PENDING',
    'ACTIVE',
    'FROZEN',
    'DORMANT',
    'CLOSED'
);

-- ============================================================
-- TENANTS
-- ============================================================

create table tenants (
    id uuid primary key default gen_random_uuid(),

    name varchar(150) not null,
    slug varchar(100) not null unique,

    status tenant_status not null default 'PENDING',

    country_code char(2) not null default 'GH',
    default_currency char(3) not null default 'GHS',
    timezone varchar(100) not null default 'Africa/Accra',

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_tenants_status
    on tenants(status);

-- ============================================================
-- INSTITUTIONS
-- ============================================================

create table institutions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete restrict,

    name varchar(200) not null,
    code varchar(50) not null unique,

    registration_number varchar(100),

    phone varchar(30),
    email varchar(255),

    address text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (tenant_id, name)
);

create index idx_institutions_tenant
    on institutions(tenant_id);

-- ============================================================
-- BRANCHES
-- ============================================================

create table branches (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete restrict,

    institution_id uuid not null
        references institutions(id)
        on delete restrict,

    code varchar(50) not null,
    name varchar(150) not null,

    phone varchar(30),
    email varchar(255),

    address text,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (tenant_id, code)
);

create index idx_branches_tenant
    on branches(tenant_id);

create index idx_branches_institution
    on branches(institution_id);

-- ============================================================
-- ROLES
-- ============================================================

create table roles (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid
        references tenants(id)
        on delete cascade,

    name varchar(100) not null,
    description text,

    is_system_role boolean not null default false,

    created_at timestamptz not null default now(),

    unique (tenant_id, name)
);

-- ============================================================
-- PERMISSIONS
-- ============================================================

create table permissions (
    id uuid primary key default gen_random_uuid(),

    code varchar(150) not null unique,
    description text,

    created_at timestamptz not null default now()
);

-- ============================================================
-- ROLE PERMISSIONS
-- ============================================================

create table role_permissions (
    role_id uuid not null
        references roles(id)
        on delete cascade,

    permission_id uuid not null
        references permissions(id)
        on delete cascade,

    primary key (role_id, permission_id)
);

-- ============================================================
-- USERS
-- ============================================================

create table users (
    id uuid primary key,

    tenant_id uuid
        references tenants(id)
        on delete restrict,

    branch_id uuid
        references branches(id)
        on delete set null,

    email varchar(255) not null unique,

    first_name varchar(100) not null,
    last_name varchar(100) not null,

    phone varchar(30),

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_users_tenant
    on users(tenant_id);

create index idx_users_branch
    on users(branch_id);

-- ============================================================
-- USER ROLES
-- ============================================================

create table user_roles (
    user_id uuid not null
        references users(id)
        on delete cascade,

    role_id uuid not null
        references roles(id)
        on delete cascade,

    primary key (user_id, role_id)
);

-- ============================================================
-- CUSTOMERS
-- ============================================================

create table customers (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete restrict,

    customer_number varchar(50) not null,

    customer_type customer_type not null,

    first_name varchar(100),
    middle_name varchar(100),
    last_name varchar(100),

    business_name varchar(200),

    date_of_birth date,

    gender varchar(30),

    phone varchar(30),
    email varchar(255),

    address text,

    nationality varchar(100),

    identification_type varchar(50),
    identification_number varchar(100),
    identification_expiry date,

    kyc_status kyc_status not null default 'PENDING',

    status customer_status not null default 'ACTIVE',

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (tenant_id, customer_number)
);

create index idx_customers_tenant
    on customers(tenant_id);

create index idx_customers_phone
    on customers(tenant_id, phone);

create index idx_customers_email
    on customers(tenant_id, email);

create index idx_customers_identification
    on customers(tenant_id, identification_number);

-- ============================================================
-- ACCOUNT PRODUCTS
-- ============================================================

create table account_products (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete restrict,

    code varchar(50) not null,
    name varchar(150) not null,

    description text,

    currency char(3) not null default 'GHS',

    minimum_opening_balance bigint not null default 0,
    minimum_balance bigint not null default 0,

    interest_rate numeric(12,6) not null default 0,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (tenant_id, code),

    check (minimum_opening_balance >= 0),
    check (minimum_balance >= 0),
    check (interest_rate >= 0)
);

create index idx_account_products_tenant
    on account_products(tenant_id);

-- ============================================================
-- ACCOUNTS
-- ============================================================

create table accounts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete restrict,

    customer_id uuid not null
        references customers(id)
        on delete restrict,

    product_id uuid not null
        references account_products(id)
        on delete restrict,

    branch_id uuid not null
        references branches(id)
        on delete restrict,

    account_number varchar(50) not null,

    currency char(3) not null default 'GHS',

    status account_status not null default 'PENDING',

    /*
     * Monetary values are stored in minor units.
     *
     * Example:
     * GHS 100.50 = 10050
     */
    ledger_balance bigint not null default 0,
    available_balance bigint not null default 0,

    opened_at timestamptz,
    closed_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (tenant_id, account_number),

    check (ledger_balance >= 0),
    check (available_balance >= 0)
);

create index idx_accounts_tenant
    on accounts(tenant_id);

create index idx_accounts_customer
    on accounts(tenant_id, customer_id);

create index idx_accounts_branch
    on accounts(tenant_id, branch_id);

create index idx_accounts_number
    on accounts(tenant_id, account_number);

-- ============================================================
-- UPDATED_AT TRIGGER
-- ============================================================

create or replace function update_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger tenants_updated_at
before update on tenants
for each row
execute function update_updated_at();

create trigger institutions_updated_at
before update on institutions
for each row
execute function update_updated_at();

create trigger branches_updated_at
before update on branches
for each row
execute function update_updated_at();

create trigger users_updated_at
before update on users
for each row
execute function update_updated_at();

create trigger customers_updated_at
before update on customers
for each row
execute function update_updated_at();

create trigger account_products_updated_at
before update on account_products
for each row
execute function update_updated_at();

create trigger accounts_updated_at
before update on accounts
for each row
execute function update_updated_at();