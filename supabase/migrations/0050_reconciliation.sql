-- ============================================================
-- RECONCILIATION
-- Migration: 0050
-- Milestone: 20
-- ============================================================

begin;

-- ============================================================
-- 1. RECONCILIATION RUNS TABLE
-- ============================================================

create table reconciliation_runs (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete cascade,

    run_type varchar not null
        check (run_type in ('GL_CUSTOMER', 'CASH', 'TRANSACTION', 'LEDGER_BALANCE')),

    run_date date not null,

    branch_id uuid null
        references branches(id)
        on delete set null,

    status varchar not null default 'RUNNING'
        check (status in ('RUNNING', 'COMPLETED', 'FAILED')),

    total_matched integer not null default 0,
    total_exceptions integer not null default 0,
    summary jsonb,

    started_at timestamptz not null default now(),
    completed_at timestamptz,

    created_by uuid null
        references users(id)
        on delete set null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_reconciliation_runs_tenant on reconciliation_runs(tenant_id);
create index idx_reconciliation_runs_type on reconciliation_runs(tenant_id, run_type);

create trigger reconciliation_runs_updated_at
before update on reconciliation_runs
for each row
execute function update_updated_at();

-- ============================================================
-- 2. RECONCILIATION EXCEPTIONS TABLE
-- ============================================================

create table reconciliation_exceptions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete cascade,

    reconciliation_run_id uuid null
        references reconciliation_runs(id)
        on delete cascade,

    exception_type varchar not null
        check (exception_type in ('BALANCE_MISMATCH', 'MISSING_ENTRY', 'DUPLICATE_ENTRY', 'ORPHAN_ENTRY', 'DEBIT_CREDIT_IMBALANCE')),

    severity varchar not null
        check (severity in ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),

    entity_type varchar not null,
    entity_id uuid,

    expected_amount bigint,
    actual_amount bigint,
    difference_amount bigint,

    description text,

    resolution_status varchar not null default 'OPEN'
        check (resolution_status in ('OPEN', 'INVESTIGATING', 'RESOLVED', 'WRITTEN_OFF')),

    resolved_by uuid null
        references users(id)
        on delete set null,

    resolved_at timestamptz,
    resolution_notes text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_reconciliation_exceptions_tenant on reconciliation_exceptions(tenant_id);
create index idx_reconciliation_exceptions_run on reconciliation_exceptions(reconciliation_run_id);
create index idx_reconciliation_exceptions_status on reconciliation_exceptions(tenant_id, resolution_status);

create trigger reconciliation_exceptions_updated_at
before update on reconciliation_exceptions
for each row
execute function update_updated_at();

-- ============================================================
-- 3. SUSPENSE ENTRIES TABLE
-- ============================================================

create table suspense_entries (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete cascade,

    original_transaction_id uuid null
        references transactions(id)
        on delete set null,

    suspense_ledger_account_id uuid not null
        references ledger_accounts(id)
        on delete restrict,

    amount bigint not null,
    currency varchar(3) not null default 'GHS',
    reason text not null,

    status varchar not null default 'OPEN'
        check (status in ('OPEN', 'CLEARED', 'WRITTEN_OFF')),

    cleared_at timestamptz,
    cleared_by uuid null
        references users(id)
        on delete set null,

    clearing_transaction_id uuid null
        references transactions(id)
        on delete set null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_suspense_entries_tenant on suspense_entries(tenant_id);
create index idx_suspense_entries_status on suspense_entries(tenant_id, status);
create index idx_suspense_entries_ledger on suspense_entries(suspense_ledger_account_id);

create trigger suspense_entries_updated_at
before update on suspense_entries
for each row
execute function update_updated_at();

-- ============================================================
-- 4. FUNCTIONS
-- ============================================================

create or replace function reconcile_gl_customer_accounts(
    p_tenant_id uuid,
    p_created_by uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_run_id uuid;
    v_total_matched integer := 0;
    v_total_exceptions integer := 0;
    v_rec record;
    v_diff bigint;
begin
    -- Create run record
    insert into reconciliation_runs(tenant_id, run_type, run_date, created_by, status)
    values (p_tenant_id, 'GL_CUSTOMER', current_date, p_created_by, 'RUNNING')
    returning id into v_run_id;

    -- Compare logic:
    -- In a real scenario, this queries accounts and groups by ledger_account_id
    -- comparing sum(ledger_balance) with ledger_accounts.current_balance
    
    for v_rec in (
        select a.ledger_account_id, 
               sum(a.ledger_balance) as calculated_balance, 
               la.current_balance as gl_balance,
               la.currency
        from accounts a
        join ledger_accounts la on a.ledger_account_id = la.id
        where a.tenant_id = p_tenant_id
        group by a.ledger_account_id, la.current_balance, la.currency
    ) loop
        v_diff := coalesce(v_rec.calculated_balance, 0) - coalesce(v_rec.gl_balance, 0);
        
        if v_diff = 0 then
            v_total_matched := v_total_matched + 1;
        else
            v_total_exceptions := v_total_exceptions + 1;
            insert into reconciliation_exceptions (
                tenant_id, reconciliation_run_id, exception_type, severity, 
                entity_type, entity_id, expected_amount, actual_amount, 
                difference_amount, description
            ) values (
                p_tenant_id, v_run_id, 'BALANCE_MISMATCH', 'HIGH',
                'LEDGER_ACCOUNT', v_rec.ledger_account_id, v_rec.calculated_balance, 
                v_rec.gl_balance, v_diff, 
                'GL Balance ' || v_rec.currency || ' mismatch with customer accounts'
            );
        end if;
    end loop;

    -- Complete run
    update reconciliation_runs
    set status = 'COMPLETED',
        completed_at = now(),
        total_matched = v_total_matched,
        total_exceptions = v_total_exceptions,
        summary = jsonb_build_object('accounts_processed', v_total_matched + v_total_exceptions)
    where id = v_run_id;

    return jsonb_build_object(
        'run_id', v_run_id,
        'status', 'COMPLETED',
        'total_matched', v_total_matched,
        'total_exceptions', v_total_exceptions
    );
end;
$$;

alter function reconcile_gl_customer_accounts(uuid, uuid) owner to postgres;

create or replace function reconcile_cash_position(
    p_tenant_id uuid,
    p_branch_id uuid,
    p_created_by uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_run_id uuid;
    v_total_matched integer := 0;
    v_total_exceptions integer := 0;
begin
    -- Create run record
    insert into reconciliation_runs(tenant_id, run_type, run_date, branch_id, created_by, status)
    values (p_tenant_id, 'CASH', current_date, p_branch_id, p_created_by, 'RUNNING')
    returning id into v_run_id;

    -- Simplified logic for cash reconciliation
    -- Typically involves comparing teller cash box balances and vault balances
    -- against cash GL account (e.g. 1010)

    -- Complete run
    update reconciliation_runs
    set status = 'COMPLETED',
        completed_at = now(),
        total_matched = v_total_matched,
        total_exceptions = v_total_exceptions,
        summary = jsonb_build_object('notes', 'Cash position reconciliation placeholder')
    where id = v_run_id;

    return jsonb_build_object(
        'run_id', v_run_id,
        'status', 'COMPLETED',
        'total_matched', v_total_matched,
        'total_exceptions', v_total_exceptions
    );
end;
$$;

alter function reconcile_cash_position(uuid, uuid, uuid) owner to postgres;

create or replace function detect_ledger_imbalances(
    p_tenant_id uuid,
    p_created_by uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_run_id uuid;
    v_total_matched integer := 0;
    v_total_exceptions integer := 0;
    v_rec record;
    v_diff bigint;
begin
    insert into reconciliation_runs(tenant_id, run_type, run_date, created_by, status)
    values (p_tenant_id, 'LEDGER_BALANCE', current_date, p_created_by, 'RUNNING')
    returning id into v_run_id;

    -- Verify sum(debit) = sum(credit) for transactions
    for v_rec in (
        select t.id, sum(te.debit) as tot_debit, sum(te.credit) as tot_credit
        from transactions t
        join transaction_entries te on t.id = te.transaction_id
        where t.tenant_id = p_tenant_id
        group by t.id
        having sum(te.debit) <> sum(te.credit)
    ) loop
        v_total_exceptions := v_total_exceptions + 1;
        v_diff := abs(coalesce(v_rec.tot_debit, 0) - coalesce(v_rec.tot_credit, 0));
        
        insert into reconciliation_exceptions (
            tenant_id, reconciliation_run_id, exception_type, severity, 
            entity_type, entity_id, expected_amount, actual_amount, 
            difference_amount, description
        ) values (
            p_tenant_id, v_run_id, 'DEBIT_CREDIT_IMBALANCE', 'CRITICAL',
            'TRANSACTION', v_rec.id, v_rec.tot_debit, v_rec.tot_credit, 
            v_diff, 'Debit does not equal credit for transaction'
        );
    end loop;

    -- This simplified logic just tracks exceptions; matches would be total txs - exceptions.
    
    update reconciliation_runs
    set status = 'COMPLETED',
        completed_at = now(),
        total_matched = v_total_matched,
        total_exceptions = v_total_exceptions,
        summary = jsonb_build_object('imbalances_found', v_total_exceptions)
    where id = v_run_id;

    return jsonb_build_object(
        'run_id', v_run_id,
        'status', 'COMPLETED',
        'total_matched', v_total_matched,
        'total_exceptions', v_total_exceptions
    );
end;
$$;

alter function detect_ledger_imbalances(uuid, uuid) owner to postgres;

create or replace function create_suspense_entry(
    p_tenant_id uuid,
    p_amount bigint,
    p_currency varchar,
    p_reason text,
    p_original_transaction_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_suspense_account_id uuid;
    v_suspense_id uuid;
begin
    -- Find suspense ledger account for the tenant (assume one exists or use a mapping)
    select id into v_suspense_account_id
    from ledger_accounts
    where tenant_id = p_tenant_id 
      and account_name ilike '%suspense%' 
    limit 1;
    
    if v_suspense_account_id is null then
        raise exception 'Suspense account not found for tenant';
    end if;

    insert into suspense_entries (
        tenant_id, suspense_ledger_account_id, original_transaction_id,
        amount, currency, reason, status
    ) values (
        p_tenant_id, v_suspense_account_id, p_original_transaction_id,
        p_amount, p_currency, p_reason, 'OPEN'
    ) returning id into v_suspense_id;

    return jsonb_build_object(
        'suspense_id', v_suspense_id,
        'status', 'OPEN'
    );
end;
$$;

alter function create_suspense_entry(uuid, bigint, varchar, text, uuid) owner to postgres;


create or replace function clear_suspense_entry(
    p_tenant_id uuid,
    p_suspense_id uuid,
    p_cleared_by uuid,
    p_notes text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_status varchar;
begin
    select status into v_status
    from suspense_entries
    where id = p_suspense_id and tenant_id = p_tenant_id;
    
    if v_status is null then
        raise exception 'Suspense entry not found';
    end if;
    
    if v_status <> 'OPEN' then
        raise exception 'Suspense entry is not OPEN';
    end if;
    
    update suspense_entries
    set status = 'CLEARED',
        cleared_by = p_cleared_by,
        cleared_at = now(),
        reason = reason || coalesce(E'\nClearance Notes: ' || p_notes, '')
    where id = p_suspense_id;

    return jsonb_build_object(
        'suspense_id', p_suspense_id,
        'status', 'CLEARED'
    );
end;
$$;

alter function clear_suspense_entry(uuid, uuid, uuid, text) owner to postgres;


commit;
