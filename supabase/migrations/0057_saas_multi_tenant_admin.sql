-- ============================================================
-- SAAS / MULTI-TENANT ADMINISTRATION
-- Migration: 0057
-- Milestone: 28
--
-- Establishes platform-level multi-tenant administration:
--   1. Subscription plans & tenant subscriptions
--   2. Tenant configuration & tenant limits
--   3. Platform SUPER_ADMIN governance
--   4. Platform audit logs & usage metrics
--   5. Tenant billing records
--   6. Onboarding, suspension & platform management RPCs
-- ============================================================

begin;

-- ============================================================
-- 1. SUBSCRIPTION PLANS
-- ============================================================

create table subscription_plans (
    id uuid primary key default gen_random_uuid(),
    plan_code varchar(50) unique not null,
    name varchar(100) not null,
    tier varchar(50) not null,
    monthly_fee bigint not null default 0,
    max_accounts integer not null default 1000,
    max_users integer not null default 10,
    max_branches integer not null default 2,
    max_monthly_transactions integer not null default 50000,
    features jsonb not null default '{}'::jsonb,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create trigger update_subscription_plans_updated_at
before update on subscription_plans
for each row
execute function update_updated_at();

-- Seed Default Plans
insert into subscription_plans (plan_code, name, tier, monthly_fee, max_accounts, max_users, max_branches, max_monthly_transactions, features)
values
('STARTER', 'Starter Tier', 'TIER_1', 50000, 500, 5, 1, 10000, '{"loans": true, "teller": true, "audit": false}'::jsonb),
('GROWTH', 'Growth Tier', 'TIER_2', 150000, 5000, 25, 5, 100000, '{"loans": true, "teller": true, "audit": true, "advanced_kyc": true}'::jsonb),
('ENTERPRISE', 'Enterprise Tier', 'TIER_3', 500000, 50000, 100, 25, 1000000, '{"loans": true, "teller": true, "audit": true, "advanced_kyc": true, "custom_gl": true, "eod_automation": true}'::jsonb)
on conflict (plan_code) do nothing;


-- ============================================================
-- 2. TENANT SUBSCRIPTIONS
-- ============================================================

create table tenant_subscriptions (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    plan_id uuid not null
        references subscription_plans(id)
        on delete restrict,
    status varchar(50) not null default 'ACTIVE'
        check (status in ('ACTIVE', 'TRIAL', 'SUSPENDED', 'EXPIRED', 'CANCELLED')),
    billing_cycle varchar(20) not null default 'MONTHLY',
    current_period_start date not null default current_date,
    current_period_end date not null default (current_date + interval '30 days')::date,
    auto_renew boolean not null default true,
    canceled_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index uq_tenant_subscriptions_active
    on tenant_subscriptions(tenant_id)
    where status in ('ACTIVE', 'TRIAL');

create index idx_tenant_subscriptions_tenant
    on tenant_subscriptions(tenant_id);

create trigger update_tenant_subscriptions_updated_at
before update on tenant_subscriptions
for each row
execute function update_updated_at();


-- ============================================================
-- 3. TENANT CONFIGURATIONS & LIMITS
-- ============================================================

create table tenant_configurations (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    config_key varchar(100) not null,
    config_value jsonb not null,
    is_encrypted boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint uq_tenant_configurations_key unique (tenant_id, config_key)
);

create trigger update_tenant_configurations_updated_at
before update on tenant_configurations
for each row
execute function update_updated_at();

create table tenant_limits (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    limit_type varchar(50) not null,
    limit_value bigint not null,
    current_value bigint not null default 0,
    reset_cycle varchar(20) not null default 'MONTHLY',
    last_reset_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint uq_tenant_limits_type unique (tenant_id, limit_type)
);

create trigger update_tenant_limits_updated_at
before update on tenant_limits
for each row
execute function update_updated_at();


-- ============================================================
-- 4. PLATFORM SUPER ADMINS & PLATFORM AUDIT
-- ============================================================

create table platform_super_admins (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null
        references users(id)
        on delete cascade,
    is_active boolean not null default true,
    granted_by uuid
        references users(id)
        on delete set null,
    granted_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint uq_platform_super_admins_user unique (user_id)
);

create trigger update_platform_super_admins_updated_at
before update on platform_super_admins
for each row
execute function update_updated_at();

create table platform_audit_logs (
    id uuid primary key default gen_random_uuid(),
    super_admin_id uuid
        references users(id)
        on delete set null,
    action varchar(100) not null,
    target_tenant_id uuid
        references tenants(id)
        on delete set null,
    details jsonb default '{}'::jsonb,
    ip_address varchar(45),
    created_at timestamptz not null default now()
);

create index idx_platform_audit_logs_created_at on platform_audit_logs(created_at desc);
create index idx_platform_audit_logs_action on platform_audit_logs(action);
create index idx_platform_audit_logs_target_tenant on platform_audit_logs(target_tenant_id);


-- ============================================================
-- 5. USAGE METRICS & BILLING RECORDS
-- ============================================================

create table tenant_usage_metrics (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    metric_date date not null default current_date,
    total_accounts integer not null default 0,
    total_customers integer not null default 0,
    total_transactions integer not null default 0,
    total_volume bigint not null default 0,
    api_calls_count integer not null default 0,
    recorded_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint uq_tenant_usage_metrics_date unique (tenant_id, metric_date)
);

create trigger update_tenant_usage_metrics_updated_at
before update on tenant_usage_metrics
for each row
execute function update_updated_at();

create table tenant_billing_records (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    subscription_id uuid
        references tenant_subscriptions(id)
        on delete set null,
    invoice_number varchar(100) unique not null,
    amount bigint not null,
    currency varchar(3) not null default 'GHS',
    status varchar(30) not null default 'PENDING'
        check (status in ('PENDING', 'PAID', 'OVERDUE', 'CANCELLED')),
    due_date date not null,
    paid_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create trigger update_tenant_billing_records_updated_at
before update on tenant_billing_records
for each row
execute function update_updated_at();


-- ============================================================
-- 6. PLATFORM MANAGEMENT FUNCTIONS
-- ============================================================

create or replace function is_super_admin(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    return exists (
        select 1
        from platform_super_admins
        where user_id = p_user_id
          and is_active = true
    );
end;
$$;
alter function is_super_admin(uuid) owner to postgres;


create or replace function onboard_new_tenant(
    p_name varchar,
    p_slug varchar,
    p_country_code varchar,
    p_default_currency varchar,
    p_admin_email varchar,
    p_admin_first_name varchar,
    p_admin_last_name varchar,
    p_plan_code varchar default 'STARTER',
    p_super_admin_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_tenant_id uuid;
    v_institution_id uuid;
    v_branch_id uuid;
    v_role_id uuid;
    v_user_id uuid;
    v_plan_id uuid;
    v_subscription_id uuid;
    v_cash_ledger_id uuid;
    v_deposit_ledger_id uuid;
begin
    -- 1. Validate slug uniqueness
    if exists (select 1 from tenants where slug = p_slug) then
        raise exception 'Tenant with slug % already exists', p_slug;
    end if;

    -- 2. Create Tenant
    insert into tenants (name, slug, status, country_code, default_currency)
    values (p_name, p_slug, 'ACTIVE', coalesce(nullif(trim(p_country_code), ''), 'GH'), coalesce(nullif(trim(p_default_currency), ''), 'GHS'))
    returning id into v_tenant_id;

    -- 3. Create Default Institution
    insert into institutions (tenant_id, name, code, phone, email)
    values (v_tenant_id, p_name || ' Institution', upper(p_slug) || '-INST', '+233000000000', p_admin_email)
    returning id into v_institution_id;

    -- 4. Create Head Office Branch
    insert into branches (tenant_id, institution_id, code, name, is_active)
    values (v_tenant_id, v_institution_id, 'HO-001', 'Head Office Branch', true)
    returning id into v_branch_id;

    -- 5. Create Tenant Admin Role
    insert into roles (tenant_id, name, description, is_system_role)
    values (v_tenant_id, 'TENANT_ADMIN', 'Full Administrative Access for Tenant', true)
    returning id into v_role_id;

    -- Attach all existing permissions to this role
    insert into role_permissions (role_id, permission_id)
    select v_role_id, p.id from permissions p
    on conflict do nothing;

    -- 6. Create Admin User
    v_user_id := gen_random_uuid();
    insert into users (id, tenant_id, branch_id, email, first_name, last_name, is_active)
    values (v_user_id, v_tenant_id, v_branch_id, lower(trim(p_admin_email)), p_admin_first_name, p_admin_last_name, true);

    insert into user_roles (user_id, role_id)
    values (v_user_id, v_role_id);

    -- 7. Subscription
    select id into v_plan_id from subscription_plans where plan_code = upper(trim(p_plan_code)) and is_active = true limit 1;
    if v_plan_id is null then
        select id into v_plan_id from subscription_plans where plan_code = 'STARTER' limit 1;
    end if;

    insert into tenant_subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end)
    values (v_tenant_id, v_plan_id, 'ACTIVE', current_date, (current_date + interval '30 days')::date)
    returning id into v_subscription_id;

    -- 8. Chart of Accounts Foundation
    insert into ledger_accounts (tenant_id, account_code, account_name, account_type, currency, is_active, current_balance)
    values (v_tenant_id, '1010', 'Vault Cash', 'ASSET', coalesce(nullif(trim(p_default_currency), ''), 'GHS'), true, 0)
    returning id into v_cash_ledger_id;

    insert into ledger_accounts (tenant_id, account_code, account_name, account_type, currency, is_active, current_balance)
    values (v_tenant_id, '2010', 'Customer Deposits Control', 'LIABILITY', coalesce(nullif(trim(p_default_currency), ''), 'GHS'), true, 0)
    returning id into v_deposit_ledger_id;

    -- 9. Open Business Date
    insert into business_dates (tenant_id, business_date, status)
    values (v_tenant_id, current_date, 'OPEN')
    on conflict do nothing;

    -- 10. Audit Log
    insert into platform_audit_logs (super_admin_id, action, target_tenant_id, details)
    values (p_super_admin_id, 'TENANT_ONBOARDED', v_tenant_id, jsonb_build_object('slug', p_slug, 'name', p_name, 'plan_code', p_plan_code));

    return jsonb_build_object(
        'tenant_id', v_tenant_id,
        'slug', p_slug,
        'name', p_name,
        'admin_user_id', v_user_id,
        'admin_email', p_admin_email,
        'branch_id', v_branch_id,
        'subscription_id', v_subscription_id,
        'status', 'ACTIVE'
    );
end;
$$;
alter function onboard_new_tenant(varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, uuid) owner to postgres;


create or replace function suspend_tenant(
    p_tenant_id uuid,
    p_reason text,
    p_super_admin_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not exists (select 1 from tenants where id = p_tenant_id) then
        raise exception 'Tenant not found';
    end if;

    update tenants
    set status = 'SUSPENDED',
        updated_at = now()
    where id = p_tenant_id;

    update tenant_subscriptions
    set status = 'SUSPENDED',
        updated_at = now()
    where tenant_id = p_tenant_id
      and status in ('ACTIVE', 'TRIAL');

    insert into platform_audit_logs (super_admin_id, action, target_tenant_id, details)
    values (p_super_admin_id, 'TENANT_SUSPENDED', p_tenant_id, jsonb_build_object('reason', p_reason));

    return jsonb_build_object(
        'tenant_id', p_tenant_id,
        'status', 'SUSPENDED',
        'reason', p_reason
    );
end;
$$;
alter function suspend_tenant(uuid, text, uuid) owner to postgres;


create or replace function reactivate_tenant(
    p_tenant_id uuid,
    p_super_admin_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not exists (select 1 from tenants where id = p_tenant_id) then
        raise exception 'Tenant not found';
    end if;

    update tenants
    set status = 'ACTIVE',
        updated_at = now()
    where id = p_tenant_id;

    update tenant_subscriptions
    set status = 'ACTIVE',
        updated_at = now()
    where tenant_id = p_tenant_id
      and status = 'SUSPENDED';

    insert into platform_audit_logs (super_admin_id, action, target_tenant_id, details)
    values (p_super_admin_id, 'TENANT_REACTIVATED', p_tenant_id, jsonb_build_object('reactivated_at', now()));

    return jsonb_build_object(
        'tenant_id', p_tenant_id,
        'status', 'ACTIVE'
    );
end;
$$;
alter function reactivate_tenant(uuid, uuid) owner to postgres;


create or replace function update_tenant_subscription(
    p_tenant_id uuid,
    p_plan_code varchar,
    p_super_admin_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_plan_id uuid;
begin
    select id into v_plan_id
    from subscription_plans
    where plan_code = upper(trim(p_plan_code))
      and is_active = true;

    if v_plan_id is null then
        raise exception 'Subscription plan % not found', p_plan_code;
    end if;

    update tenant_subscriptions
    set plan_id = v_plan_id,
        updated_at = now()
    where tenant_id = p_tenant_id
      and status in ('ACTIVE', 'TRIAL');

    insert into platform_audit_logs (super_admin_id, action, target_tenant_id, details)
    values (p_super_admin_id, 'SUBSCRIPTION_UPDATED', p_tenant_id, jsonb_build_object('new_plan_code', p_plan_code));

    return jsonb_build_object(
        'tenant_id', p_tenant_id,
        'plan_code', p_plan_code,
        'updated', true
    );
end;
$$;
alter function update_tenant_subscription(uuid, varchar, uuid) owner to postgres;


create or replace function get_platform_metrics(p_super_admin_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_total_tenants integer;
    v_active_tenants integer;
    v_suspended_tenants integer;
    v_total_accounts integer;
    v_total_customers integer;
    v_total_txns integer;
    v_total_volume bigint;
begin
    select count(*) into v_total_tenants from tenants;
    select count(*) into v_active_tenants from tenants where status = 'ACTIVE';
    select count(*) into v_suspended_tenants from tenants where status = 'SUSPENDED';
    select count(*) into v_total_accounts from accounts;
    select count(*) into v_total_customers from customers;
    select count(*), coalesce(sum(amount), 0) into v_total_txns, v_total_volume from transactions where status = 'POSTED';

    return jsonb_build_object(
        'total_tenants', v_total_tenants,
        'active_tenants', v_active_tenants,
        'suspended_tenants', v_suspended_tenants,
        'total_accounts', v_total_accounts,
        'total_customers', v_total_customers,
        'total_transactions', v_total_txns,
        'total_transaction_volume', v_total_volume
    );
end;
$$;
alter function get_platform_metrics(uuid) owner to postgres;

commit;
