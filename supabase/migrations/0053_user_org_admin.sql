-- ============================================================
-- USER & ORGANIZATION ADMINISTRATION
-- Migration: 0053
-- Milestone: 23
-- ============================================================

begin;

-- ============================================================
-- 1. TABLES
-- ============================================================

-- ------------------------------------------------------------
-- user_limits
-- ------------------------------------------------------------
create table user_limits (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete cascade,
    user_id uuid not null references users(id) on delete cascade,
    limit_type varchar not null,
    max_amount bigint not null,
    currency varchar(3) not null default 'GHS',
    current_utilized bigint not null default 0,
    last_reset_date date,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint user_limits_type_check check (
        limit_type in (
            'DAILY_TRANSACTION',
            'SINGLE_TRANSACTION',
            'DAILY_APPROVAL',
            'DAILY_CASH_WITHDRAWAL',
            'DAILY_CASH_DEPOSIT',
            'DAILY_TRANSFER'
        )
    ),
    constraint user_limits_unique unique (tenant_id, user_id, limit_type)
);

create index idx_user_limits_tenant_user on user_limits(tenant_id, user_id);

create trigger user_limits_updated_at
before update on user_limits
for each row
execute function update_updated_at();

-- ------------------------------------------------------------
-- approval_policies
-- ------------------------------------------------------------
create table approval_policies (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete cascade,
    policy_name varchar(150) not null,
    entity_type varchar(100) not null,
    action_type varchar(100) not null,
    min_amount bigint not null default 0,
    max_amount bigint null,
    required_approvers integer not null default 1,
    approver_role_id uuid null references roles(id) on delete set null,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint approval_policies_unique unique (tenant_id, entity_type, action_type, min_amount)
);

create index idx_approval_policies_tenant_entity on approval_policies(tenant_id, entity_type, action_type);

create trigger approval_policies_updated_at
before update on approval_policies
for each row
execute function update_updated_at();

-- ------------------------------------------------------------
-- branch_controls
-- ------------------------------------------------------------
create table branch_controls (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete cascade,
    branch_id uuid not null references branches(id) on delete cascade,
    control_type varchar not null,
    control_value jsonb not null,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint branch_controls_type_check check (
        control_type in (
            'MAX_CASH_HOLDING',
            'DAILY_TRANSACTION_LIMIT',
            'OPERATING_HOURS',
            'WEEKEND_OPERATIONS'
        )
    ),
    constraint branch_controls_unique unique (tenant_id, branch_id, control_type)
);

create index idx_branch_controls_tenant_branch on branch_controls(tenant_id, branch_id);

create trigger branch_controls_updated_at
before update on branch_controls
for each row
execute function update_updated_at();


-- ============================================================
-- 2. FUNCTIONS
-- ============================================================

-- ------------------------------------------------------------
-- admin_create_user
-- ------------------------------------------------------------
create or replace function admin_create_user(
    p_tenant_id uuid,
    p_email varchar,
    p_first_name varchar,
    p_last_name varchar,
    p_phone varchar,
    p_branch_id uuid,
    p_created_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_user_id uuid;
begin
    if not exists (select 1 from tenants where id = p_tenant_id) then
        raise exception 'Tenant not found';
    end if;

    if p_branch_id is not null and not exists (select 1 from branches where id = p_branch_id and tenant_id = p_tenant_id) then
        raise exception 'Branch not found or belongs to a different tenant';
    end if;

    if exists (select 1 from users where email = p_email) then
        raise exception 'User with this email already exists';
    end if;

    insert into users (
        id, tenant_id, email, first_name, last_name, phone_number, branch_id, is_active
    ) values (
        gen_random_uuid(), p_tenant_id, p_email, p_first_name, p_last_name, p_phone, p_branch_id, true
    ) returning id into v_user_id;

    return jsonb_build_object(
        'user_id', v_user_id,
        'email', p_email,
        'first_name', p_first_name,
        'last_name', p_last_name,
        'branch_id', p_branch_id,
        'is_active', true
    );
end;
$$;

alter function admin_create_user(uuid, varchar, varchar, varchar, varchar, uuid, uuid) owner to postgres;

-- ------------------------------------------------------------
-- admin_toggle_user_active
-- ------------------------------------------------------------
create or replace function admin_toggle_user_active(
    p_tenant_id uuid,
    p_user_id uuid,
    p_is_active boolean,
    p_performed_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not exists (select 1 from users where id = p_user_id and tenant_id = p_tenant_id) then
        raise exception 'User not found or belongs to a different tenant';
    end if;

    update users set is_active = p_is_active where id = p_user_id;

    return jsonb_build_object(
        'user_id', p_user_id,
        'is_active', p_is_active
    );
end;
$$;

alter function admin_toggle_user_active(uuid, uuid, boolean, uuid) owner to postgres;

-- ------------------------------------------------------------
-- admin_assign_role
-- ------------------------------------------------------------
create or replace function admin_assign_role(
    p_tenant_id uuid,
    p_user_id uuid,
    p_role_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not exists (select 1 from users where id = p_user_id and tenant_id = p_tenant_id) then
        raise exception 'User not found or belongs to a different tenant';
    end if;

    if not exists (select 1 from roles where id = p_role_id and tenant_id = p_tenant_id) then
        raise exception 'Role not found or belongs to a different tenant';
    end if;

    insert into user_roles (user_id, role_id)
    values (p_user_id, p_role_id)
    on conflict (user_id, role_id) do nothing;

    return jsonb_build_object(
        'user_id', p_user_id,
        'role_id', p_role_id,
        'assigned', true
    );
end;
$$;

alter function admin_assign_role(uuid, uuid, uuid) owner to postgres;

-- ------------------------------------------------------------
-- admin_remove_role
-- ------------------------------------------------------------
create or replace function admin_remove_role(
    p_tenant_id uuid,
    p_user_id uuid,
    p_role_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not exists (select 1 from users where id = p_user_id and tenant_id = p_tenant_id) then
        raise exception 'User not found or belongs to a different tenant';
    end if;

    delete from user_roles where user_id = p_user_id and role_id = p_role_id;

    return jsonb_build_object(
        'user_id', p_user_id,
        'role_id', p_role_id,
        'removed', true
    );
end;
$$;

alter function admin_remove_role(uuid, uuid, uuid) owner to postgres;

-- ------------------------------------------------------------
-- admin_assign_branch
-- ------------------------------------------------------------
create or replace function admin_assign_branch(
    p_tenant_id uuid,
    p_user_id uuid,
    p_branch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not exists (select 1 from users where id = p_user_id and tenant_id = p_tenant_id) then
        raise exception 'User not found or belongs to a different tenant';
    end if;

    if p_branch_id is not null and not exists (select 1 from branches where id = p_branch_id and tenant_id = p_tenant_id) then
        raise exception 'Branch not found or belongs to a different tenant';
    end if;

    update users set branch_id = p_branch_id where id = p_user_id;

    return jsonb_build_object(
        'user_id', p_user_id,
        'branch_id', p_branch_id
    );
end;
$$;

alter function admin_assign_branch(uuid, uuid, uuid) owner to postgres;

-- ------------------------------------------------------------
-- set_user_limit
-- ------------------------------------------------------------
create or replace function set_user_limit(
    p_tenant_id uuid,
    p_user_id uuid,
    p_limit_type varchar,
    p_max_amount bigint,
    p_currency varchar
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_limit_id uuid;
begin
    if not exists (select 1 from users where id = p_user_id and tenant_id = p_tenant_id) then
        raise exception 'User not found or belongs to a different tenant';
    end if;

    insert into user_limits (
        tenant_id, user_id, limit_type, max_amount, currency, last_reset_date
    ) values (
        p_tenant_id, p_user_id, p_limit_type, p_max_amount, p_currency, current_date
    )
    on conflict (tenant_id, user_id, limit_type)
    do update set
        max_amount = excluded.max_amount,
        currency = excluded.currency,
        is_active = true
    returning id into v_limit_id;

    return jsonb_build_object(
        'limit_id', v_limit_id,
        'user_id', p_user_id,
        'limit_type', p_limit_type,
        'max_amount', p_max_amount
    );
end;
$$;

alter function set_user_limit(uuid, uuid, varchar, bigint, varchar) owner to postgres;

-- ------------------------------------------------------------
-- check_user_limit
-- ------------------------------------------------------------
create or replace function check_user_limit(
    p_tenant_id uuid,
    p_user_id uuid,
    p_limit_type varchar,
    p_amount bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_limit user_limits%rowtype;
    v_utilized bigint := 0;
    v_allowed boolean := false;
begin
    select * into v_limit
    from user_limits
    where tenant_id = p_tenant_id and user_id = p_user_id and limit_type = p_limit_type and is_active = true;

    if not found then
        -- No limit set means allowed by default? We'll assume allowed, but maybe it should be blocked. 
        -- Based on instructions, we just check. Let's say if no limit, it's unlimited.
        return jsonb_build_object(
            'allowed', true,
            'limit', null,
            'utilized', 0,
            'remaining', null
        );
    end if;

    -- If it's a daily limit, and last reset is before today, treat utilized as 0
    if p_limit_type like 'DAILY_%' and v_limit.last_reset_date < current_date then
        v_utilized := 0;
    else
        v_utilized := v_limit.current_utilized;
    end if;

    if (v_utilized + p_amount) <= v_limit.max_amount then
        v_allowed := true;
    end if;

    return jsonb_build_object(
        'allowed', v_allowed,
        'limit', v_limit.max_amount,
        'utilized', v_utilized,
        'remaining', v_limit.max_amount - v_utilized
    );
end;
$$;

alter function check_user_limit(uuid, uuid, varchar, bigint) owner to postgres;

-- ------------------------------------------------------------
-- reset_daily_user_limits
-- ------------------------------------------------------------
create or replace function reset_daily_user_limits(
    p_tenant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_count integer;
begin
    update user_limits
    set current_utilized = 0,
        last_reset_date = current_date
    where tenant_id = p_tenant_id
      and limit_type like 'DAILY_%'
      and (last_reset_date < current_date or last_reset_date is null);

    get diagnostics v_count = row_count;

    return jsonb_build_object(
        'reset_count', v_count,
        'reset_date', current_date
    );
end;
$$;

alter function reset_daily_user_limits(uuid) owner to postgres;

-- ------------------------------------------------------------
-- configure_approval_policy
-- ------------------------------------------------------------
create or replace function configure_approval_policy(
    p_tenant_id uuid,
    p_policy_name varchar,
    p_entity_type varchar,
    p_action_type varchar,
    p_min_amount bigint,
    p_max_amount bigint,
    p_required_approvers integer,
    p_approver_role_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_policy_id uuid;
begin
    insert into approval_policies (
        tenant_id, policy_name, entity_type, action_type, min_amount, max_amount, required_approvers, approver_role_id
    ) values (
        p_tenant_id, p_policy_name, p_entity_type, p_action_type, p_min_amount, p_max_amount, p_required_approvers, p_approver_role_id
    )
    on conflict (tenant_id, entity_type, action_type, min_amount)
    do update set
        policy_name = excluded.policy_name,
        max_amount = excluded.max_amount,
        required_approvers = excluded.required_approvers,
        approver_role_id = excluded.approver_role_id,
        is_active = true
    returning id into v_policy_id;

    return jsonb_build_object(
        'policy_id', v_policy_id,
        'policy_name', p_policy_name,
        'entity_type', p_entity_type,
        'action_type', p_action_type
    );
end;
$$;

alter function configure_approval_policy(uuid, varchar, varchar, varchar, bigint, bigint, integer, uuid) owner to postgres;

commit;
