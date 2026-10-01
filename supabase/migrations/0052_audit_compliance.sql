-- ============================================================
-- AUDIT & COMPLIANCE
-- Migration: 0052
-- Milestone: 22
--
-- Establishes the foundation for Audit & Compliance:
--   1. Audit logs
--   2. Data access logs
--   3. Login history
--   4. Retention policies
--   5. Logging functions
--   6. Query & Reporting functions
-- ============================================================

begin;

-- ============================================================
-- 1. AUDIT LOGS
-- ============================================================

create table if not exists audit_logs (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    user_id uuid null
        references users(id)
        on delete set null,
    action varchar(100) not null,
    entity_type varchar(100) not null,
    entity_id uuid null,
    old_values jsonb,
    new_values jsonb,
    ip_address varchar(45),
    user_agent text,
    session_id varchar(255),
    created_at timestamptz not null default now()
);

alter table audit_logs
    add column if not exists session_id varchar(255);

alter table audit_logs
    alter column ip_address type varchar(45) using ip_address::text;

create index if not exists idx_audit_logs_tenant_date
    on audit_logs(tenant_id, created_at desc);

create index if not exists idx_audit_logs_entity
    on audit_logs(tenant_id, entity_type, entity_id);

create index if not exists idx_audit_logs_user_date
    on audit_logs(tenant_id, user_id, created_at desc);

create index if not exists idx_audit_logs_action
    on audit_logs(tenant_id, action);

comment on table audit_logs is 'Immutable audit log for core entities.';


-- ============================================================
-- 2. DATA ACCESS LOGS
-- ============================================================

create table data_access_logs (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    user_id uuid not null
        references users(id)
        on delete cascade,
    resource_type varchar(100) not null,
    resource_id uuid null,
    access_type varchar(50) not null
        check (access_type in ('VIEW', 'EXPORT', 'PRINT', 'DOWNLOAD')),
    ip_address varchar(45),
    created_at timestamptz not null default now()
);

create index idx_data_access_logs_tenant_date
    on data_access_logs(tenant_id, created_at desc);

create index idx_data_access_logs_user
    on data_access_logs(tenant_id, user_id);

comment on table data_access_logs is 'Logs read-only access to sensitive data.';


-- ============================================================
-- 3. LOGIN HISTORY
-- ============================================================

create table login_history (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid null
        references tenants(id)
        on delete cascade,
    user_id uuid null
        references users(id)
        on delete set null,
    email varchar(255) not null,
    event_type varchar(50) not null
        check (event_type in ('LOGIN_SUCCESS', 'LOGIN_FAILED', 'LOGOUT', 'TOKEN_REFRESH', 'PASSWORD_CHANGE', 'ACCOUNT_LOCKED')),
    ip_address varchar(45),
    user_agent text,
    created_at timestamptz not null default now()
);

create index idx_login_history_tenant_date
    on login_history(tenant_id, created_at desc);

create index idx_login_history_email_date
    on login_history(email, created_at desc);

comment on table login_history is 'Tracks authentication and session events.';


-- ============================================================
-- 4. AUDIT RETENTION POLICIES
-- ============================================================

create table audit_retention_policies (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    log_type varchar(50) not null
        check (log_type in ('AUDIT_LOG', 'DATA_ACCESS', 'LOGIN_HISTORY', 'TRANSACTION')),
    retention_days integer not null default 2555,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint uq_audit_retention_tenant_log
        unique (tenant_id, log_type)
);

create trigger audit_retention_policies_updated_at
before update on audit_retention_policies
for each row
execute function update_updated_at();

comment on table audit_retention_policies is 'Configuration for data retention periods.';


-- ============================================================
-- 5. LOG AUDIT EVENT
-- ============================================================

create or replace function log_audit_event(
    p_tenant_id uuid,
    p_user_id uuid,
    p_action varchar,
    p_entity_type varchar,
    p_entity_id uuid,
    p_old_values jsonb,
    p_new_values jsonb,
    p_ip_address varchar default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id uuid;
begin
    insert into audit_logs (
        tenant_id,
        user_id,
        action,
        entity_type,
        entity_id,
        old_values,
        new_values,
        ip_address
    )
    values (
        p_tenant_id,
        p_user_id,
        p_action,
        p_entity_type,
        p_entity_id,
        p_old_values,
        p_new_values,
        p_ip_address
    )
    returning id into v_id;

    return v_id;
end;
$$;

alter function log_audit_event(uuid, uuid, varchar, varchar, uuid, jsonb, jsonb, varchar) owner to postgres;


-- ============================================================
-- 6. LOG DATA ACCESS
-- ============================================================

create or replace function log_data_access(
    p_tenant_id uuid,
    p_user_id uuid,
    p_resource_type varchar,
    p_resource_id uuid,
    p_access_type varchar,
    p_ip_address varchar default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id uuid;
begin
    insert into data_access_logs (
        tenant_id,
        user_id,
        resource_type,
        resource_id,
        access_type,
        ip_address
    )
    values (
        p_tenant_id,
        p_user_id,
        p_resource_type,
        p_resource_id,
        p_access_type,
        p_ip_address
    )
    returning id into v_id;

    return v_id;
end;
$$;

alter function log_data_access(uuid, uuid, varchar, uuid, varchar, varchar) owner to postgres;


-- ============================================================
-- 7. LOG LOGIN EVENT
-- ============================================================

create or replace function log_login_event(
    p_tenant_id uuid,
    p_user_id uuid,
    p_email varchar,
    p_event_type varchar,
    p_ip_address varchar default null,
    p_user_agent text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id uuid;
begin
    insert into login_history (
        tenant_id,
        user_id,
        email,
        event_type,
        ip_address,
        user_agent
    )
    values (
        p_tenant_id,
        p_user_id,
        p_email,
        p_event_type,
        p_ip_address,
        p_user_agent
    )
    returning id into v_id;

    return v_id;
end;
$$;

alter function log_login_event(uuid, uuid, varchar, varchar, varchar, text) owner to postgres;


-- ============================================================
-- 8. QUERY AUDIT TRAIL
-- ============================================================

create or replace function query_audit_trail(
    p_tenant_id uuid,
    p_entity_type varchar default null,
    p_entity_id uuid default null,
    p_user_id uuid default null,
    p_from_date timestamptz default null,
    p_to_date timestamptz default null,
    p_limit integer default 100,
    p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_total_count bigint;
    v_records jsonb;
begin
    -- Get count
    select count(*)
    into v_total_count
    from audit_logs
    where tenant_id = p_tenant_id
      and (p_entity_type is null or entity_type = p_entity_type)
      and (p_entity_id is null or entity_id = p_entity_id)
      and (p_user_id is null or user_id = p_user_id)
      and (p_from_date is null or created_at >= p_from_date)
      and (p_to_date is null or created_at <= p_to_date);

    -- Get records
    select coalesce(jsonb_agg(row_to_json(a)), '[]'::jsonb)
    into v_records
    from (
        select *
        from audit_logs
        where tenant_id = p_tenant_id
          and (p_entity_type is null or entity_type = p_entity_type)
          and (p_entity_id is null or entity_id = p_entity_id)
          and (p_user_id is null or user_id = p_user_id)
          and (p_from_date is null or created_at >= p_from_date)
          and (p_to_date is null or created_at <= p_to_date)
        order by created_at desc
        limit p_limit offset p_offset
    ) a;

    return jsonb_build_object(
        'total_count', v_total_count,
        'records', v_records
    );
end;
$$;

alter function query_audit_trail(uuid, varchar, uuid, uuid, timestamptz, timestamptz, integer, integer) owner to postgres;


-- ============================================================
-- 9. APPLY RETENTION POLICY
-- ============================================================

create or replace function apply_retention_policy(
    p_tenant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_audit_days integer;
    v_access_days integer;
    v_login_days integer;
    v_tx_days integer;
    
    v_del_audit bigint := 0;
    v_del_access bigint := 0;
    v_del_login bigint := 0;
    v_del_tx bigint := 0;
begin
    -- Get retention days
    select retention_days into v_audit_days from audit_retention_policies where tenant_id = p_tenant_id and log_type = 'AUDIT_LOG' and is_active = true;
    select retention_days into v_access_days from audit_retention_policies where tenant_id = p_tenant_id and log_type = 'DATA_ACCESS' and is_active = true;
    select retention_days into v_login_days from audit_retention_policies where tenant_id = p_tenant_id and log_type = 'LOGIN_HISTORY' and is_active = true;
    select retention_days into v_tx_days from audit_retention_policies where tenant_id = p_tenant_id and log_type = 'TRANSACTION' and is_active = true;

    -- Apply deletions
    if v_audit_days is not null then
        with deleted as (
            delete from audit_logs
            where tenant_id = p_tenant_id
              and created_at < now() - (v_audit_days || ' days')::interval
            returning 1
        )
        select count(*) into v_del_audit from deleted;
    end if;

    if v_access_days is not null then
        with deleted as (
            delete from data_access_logs
            where tenant_id = p_tenant_id
              and created_at < now() - (v_access_days || ' days')::interval
            returning 1
        )
        select count(*) into v_del_access from deleted;
    end if;

    if v_login_days is not null then
        with deleted as (
            delete from login_history
            where tenant_id = p_tenant_id
              and created_at < now() - (v_login_days || ' days')::interval
            returning 1
        )
        select count(*) into v_del_login from deleted;
    end if;

    if v_tx_days is not null then
        with deleted as (
            delete from transactions
            where tenant_id = p_tenant_id
              and created_at < now() - (v_tx_days || ' days')::interval
            returning 1
        )
        select count(*) into v_del_tx from deleted;
    end if;

    return jsonb_build_object(
        'audit_logs_deleted', v_del_audit,
        'data_access_logs_deleted', v_del_access,
        'login_history_deleted', v_del_login,
        'transactions_deleted', v_del_tx
    );
end;
$$;

alter function apply_retention_policy(uuid) owner to postgres;


-- ============================================================
-- 10. GENERATE COMPLIANCE REPORT
-- ============================================================

create or replace function generate_compliance_report(
    p_tenant_id uuid,
    p_from_date date,
    p_to_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_total_logins bigint;
    v_failed_logins bigint;
    v_transactions jsonb;
    v_approvals jsonb;
    v_data_access jsonb;
begin
    -- Logins
    select count(*) into v_total_logins
    from login_history
    where tenant_id = p_tenant_id
      and event_type = 'LOGIN_SUCCESS'
      and created_at::date >= p_from_date
      and created_at::date <= p_to_date;

    select count(*) into v_failed_logins
    from login_history
    where tenant_id = p_tenant_id
      and event_type = 'LOGIN_FAILED'
      and created_at::date >= p_from_date
      and created_at::date <= p_to_date;

    -- Transactions by type
    select coalesce(jsonb_object_agg(transaction_type, tx_count), '{}'::jsonb)
    into v_transactions
    from (
        select transaction_type, count(*) as tx_count
        from transactions
        where tenant_id = p_tenant_id
          and created_at::date >= p_from_date
          and created_at::date <= p_to_date
        group by transaction_type
    ) t;

    -- Approval actions
    select coalesce(jsonb_object_agg(action, act_count), '{}'::jsonb)
    into v_approvals
    from (
        select action, count(*) as act_count
        from approval_request_history
        where request_id in (select id from approval_requests where tenant_id = p_tenant_id)
          and created_at::date >= p_from_date
          and created_at::date <= p_to_date
        group by action
    ) a;
    
    -- Sensitive data access
    select coalesce(jsonb_object_agg(access_type, acc_count), '{}'::jsonb)
    into v_data_access
    from (
        select access_type, count(*) as acc_count
        from data_access_logs
        where tenant_id = p_tenant_id
          and created_at::date >= p_from_date
          and created_at::date <= p_to_date
        group by access_type
    ) d;

    return jsonb_build_object(
        'period', jsonb_build_object('from', p_from_date, 'to', p_to_date),
        'logins', jsonb_build_object('total_success', v_total_logins, 'total_failed', v_failed_logins),
        'transactions_by_type', v_transactions,
        'approvals', v_approvals,
        'sensitive_data_access', v_data_access
    );
end;
$$;

alter function generate_compliance_report(uuid, date, date) owner to postgres;

commit;
