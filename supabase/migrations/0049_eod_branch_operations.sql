-- ============================================================
-- END-OF-DAY / BRANCH OPERATIONS
-- Migration: 0049
-- ============================================================

begin;

-- ============================================================
-- 1. EOD BATCHES TABLE
-- ============================================================

create table eod_batches (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    branch_id uuid null
        references branches(id)
        on delete restrict,
    business_date_id uuid not null
        references business_dates(id)
        on delete restrict,
    batch_date date not null,
    status varchar not null default 'INITIATED'
        check (status in ('INITIATED','VALIDATING','PROCESSING','COMPLETED','FAILED','ROLLED_BACK')),
    initiated_by uuid null
        references users(id)
        on delete set null,
    initiated_at timestamptz default now(),
    completed_at timestamptz,
    failure_reason text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index uq_eod_batches_tenant_busdate_null_branch
    on eod_batches(tenant_id, business_date_id)
    where branch_id is null;

create unique index uq_eod_batches_tenant_busdate_branch
    on eod_batches(tenant_id, business_date_id, branch_id)
    where branch_id is not null;

create index idx_eod_batches_tenant_date
    on eod_batches(tenant_id, batch_date);

create trigger eod_batches_updated_at
before update on eod_batches
for each row
execute function update_updated_at();

-- ============================================================
-- 2. EOD BATCH STEPS TABLE
-- ============================================================

create table eod_batch_steps (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null
        references tenants(id)
        on delete cascade,
    eod_batch_id uuid not null
        references eod_batches(id)
        on delete cascade,
    step_order integer not null,
    step_type varchar not null
        check (step_type in (
            'VALIDATE_PENDING_TXN',
            'VALIDATE_TELLER_SESSIONS',
            'INTEREST_ACCRUAL',
            'FEE_PROCESSING',
            'GL_RECONCILIATION',
            'POSTING',
            'BUSINESS_DATE_CLOSE'
        )),
    status varchar not null default 'PENDING'
        check (status in ('PENDING','RUNNING','COMPLETED','FAILED','SKIPPED')),
    started_at timestamptz,
    completed_at timestamptz,
    result_summary jsonb,
    error_message text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint uq_eod_batch_steps_batch_order unique(eod_batch_id, step_order),
    constraint uq_eod_batch_steps_batch_type unique(eod_batch_id, step_type)
);

create index idx_eod_batch_steps_batch
    on eod_batch_steps(eod_batch_id);

create trigger eod_batch_steps_updated_at
before update on eod_batch_steps
for each row
execute function update_updated_at();

-- ============================================================
-- 3. FUNCTIONS
-- ============================================================

-- ----------------------------------------------------------
-- validate_eod_readiness
-- ----------------------------------------------------------
create or replace function validate_eod_readiness(
    p_tenant_id uuid,
    p_business_date_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pending_tx_count integer;
    v_open_teller_sessions_count integer;
    v_is_ready boolean := true;
begin
    -- Check for pending transactions
    select count(*)
    into v_pending_tx_count
    from transactions
    where tenant_id = p_tenant_id
      and business_date_id = p_business_date_id
      and status = 'PENDING';

    if v_pending_tx_count > 0 then
        v_is_ready := false;
    end if;

    -- Check for open teller sessions (assuming teller_sessions table exists and has status = 'OPEN')
    select count(*)
    into v_open_teller_sessions_count
    from teller_sessions
    where tenant_id = p_tenant_id
      and business_date_id = p_business_date_id
      and status = 'OPEN';

    if v_open_teller_sessions_count > 0 then
        v_is_ready := false;
    end if;

    return jsonb_build_object(
        'is_ready', v_is_ready,
        'pending_transactions', v_pending_tx_count,
        'open_teller_sessions', v_open_teller_sessions_count
    );
end;
$$;
alter function validate_eod_readiness(uuid, uuid) owner to postgres;

-- ----------------------------------------------------------
-- start_eod_processing
-- ----------------------------------------------------------
create or replace function start_eod_processing(
    p_tenant_id uuid,
    p_business_date_id uuid,
    p_initiated_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_business_date business_dates%rowtype;
    v_batch_id uuid;
begin
    -- Validate business date is OPEN
    select *
    into v_business_date
    from business_dates
    where id = p_business_date_id
      and tenant_id = p_tenant_id
    for update;

    if not found then
        raise exception 'Business date not found';
    end if;

    if v_business_date.status <> 'OPEN' then
        raise exception 'Business date is not OPEN';
    end if;

    -- Create EOD Batch
    insert into eod_batches(tenant_id, business_date_id, batch_date, status, initiated_by)
    values (p_tenant_id, p_business_date_id, v_business_date.business_date, 'PROCESSING', p_initiated_by)
    returning id into v_batch_id;

    -- Create steps
    insert into eod_batch_steps(tenant_id, eod_batch_id, step_order, step_type) values
    (p_tenant_id, v_batch_id, 1, 'VALIDATE_PENDING_TXN'),
    (p_tenant_id, v_batch_id, 2, 'VALIDATE_TELLER_SESSIONS'),
    (p_tenant_id, v_batch_id, 3, 'INTEREST_ACCRUAL'),
    (p_tenant_id, v_batch_id, 4, 'FEE_PROCESSING'),
    (p_tenant_id, v_batch_id, 5, 'GL_RECONCILIATION'),
    (p_tenant_id, v_batch_id, 6, 'POSTING'),
    (p_tenant_id, v_batch_id, 7, 'BUSINESS_DATE_CLOSE');

    return jsonb_build_object(
        'batch_id', v_batch_id,
        'status', 'PROCESSING'
    );
end;
$$;
alter function start_eod_processing(uuid, uuid, uuid) owner to postgres;

-- ----------------------------------------------------------
-- execute_eod_step
-- ----------------------------------------------------------
create or replace function execute_eod_step(
    p_tenant_id uuid,
    p_batch_id uuid,
    p_step_type varchar
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_step eod_batch_steps%rowtype;
    v_batch eod_batches%rowtype;
begin
    select * into v_batch
    from eod_batches
    where id = p_batch_id and tenant_id = p_tenant_id;

    if not found then
        raise exception 'EOD batch not found';
    end if;

    select * into v_step
    from eod_batch_steps
    where eod_batch_id = p_batch_id and step_type = p_step_type and tenant_id = p_tenant_id;

    if not found then
        raise exception 'EOD step not found';
    end if;

    update eod_batch_steps
    set status = 'RUNNING', started_at = now()
    where id = v_step.id;

    -- Mocking step logic here, real logic would be complex
    if p_step_type = 'BUSINESS_DATE_CLOSE' then
        update business_dates
        set status = 'CLOSED', updated_at = now()
        where id = v_batch.business_date_id and tenant_id = p_tenant_id;
    end if;

    update eod_batch_steps
    set status = 'COMPLETED', completed_at = now()
    where id = v_step.id;

    return jsonb_build_object(
        'step_id', v_step.id,
        'step_type', p_step_type,
        'status', 'COMPLETED'
    );
end;
$$;
alter function execute_eod_step(uuid, uuid, varchar) owner to postgres;

-- ----------------------------------------------------------
-- complete_eod_processing
-- ----------------------------------------------------------
create or replace function complete_eod_processing(
    p_tenant_id uuid,
    p_batch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch eod_batches%rowtype;
begin
    select * into v_batch
    from eod_batches
    where id = p_batch_id and tenant_id = p_tenant_id;

    if not found then
        raise exception 'EOD batch not found';
    end if;

    update eod_batches
    set status = 'COMPLETED', completed_at = now()
    where id = p_batch_id;

    update business_dates
    set status = 'CLOSED', updated_at = now()
    where id = v_batch.business_date_id;

    return jsonb_build_object(
        'batch_id', p_batch_id,
        'status', 'COMPLETED'
    );
end;
$$;
alter function complete_eod_processing(uuid, uuid) owner to postgres;

-- ----------------------------------------------------------
-- advance_business_date
-- ----------------------------------------------------------
create or replace function advance_business_date(
    p_tenant_id uuid,
    p_current_business_date_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_curr_bd business_dates%rowtype;
    v_next_date date;
    v_dow integer;
    v_period_name varchar;
    v_period_id uuid;
    v_new_bd_id uuid;
begin
    select * into v_curr_bd
    from business_dates
    where id = p_current_business_date_id and tenant_id = p_tenant_id;

    if not found then
        raise exception 'Current business date not found';
    end if;

    -- Calculate next business date
    v_next_date := v_curr_bd.business_date + interval '1 day';
    v_dow := extract(isodow from v_next_date);

    -- Skip weekends (6=Sat, 7=Sun)
    if v_dow = 6 then
        v_next_date := v_next_date + interval '2 days';
    elsif v_dow = 7 then
        v_next_date := v_next_date + interval '1 day';
    end if;

    -- Ensure accounting period exists for the new month
    v_period_name := to_char(v_next_date, 'YYYY-MM');

    select id into v_period_id
    from accounting_periods
    where tenant_id = p_tenant_id and period_name = v_period_name;

    if not found then
        insert into accounting_periods (tenant_id, period_name, start_date, end_date, status)
        values (
            p_tenant_id,
            v_period_name,
            date_trunc('month', v_next_date)::date,
            (date_trunc('month', v_next_date) + interval '1 month' - interval '1 day')::date,
            'OPEN'
        )
        returning id into v_period_id;
    end if;

    -- Create new business date
    insert into business_dates (tenant_id, business_date, status, accounting_period_id)
    values (p_tenant_id, v_next_date, 'OPEN', v_period_id)
    returning id into v_new_bd_id;

    return jsonb_build_object(
        'previous_business_date_id', v_curr_bd.id,
        'new_business_date_id', v_new_bd_id,
        'new_business_date', v_next_date,
        'accounting_period_id', v_period_id
    );
end;
$$;
alter function advance_business_date(uuid, uuid) owner to postgres;

commit;
