-- ============================================================
-- INTEREST ENGINE
-- Migration: 0048
-- ============================================================

begin;

-- ============================================================
-- 1. TABLES
-- ============================================================

create table interest_accrual_configs (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete cascade,
    account_id uuid not null references accounts(id) on delete cascade,
    account_type varchar not null check (account_type in ('DEPOSIT', 'LOAN')),
    annual_rate_bps integer not null,
    effective_from date not null,
    effective_to date,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index uq_interest_accrual_configs_active
    on interest_accrual_configs(tenant_id, account_id, effective_from)
    where is_active = true;

create index idx_interest_accrual_configs_account
    on interest_accrual_configs(tenant_id, account_id);

create trigger interest_accrual_configs_updated_at
    before update on interest_accrual_configs
    for each row execute function update_updated_at();

comment on table interest_accrual_configs is 'Per-account interest rate overrides';

create table interest_accruals (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete cascade,
    account_id uuid not null references accounts(id) on delete cascade,
    account_type varchar not null,
    accrual_date date not null,
    principal_amount bigint not null,
    annual_rate_bps integer not null,
    day_count_basis varchar not null,
    accrued_amount bigint not null,
    is_posted boolean not null default false,
    posted_at timestamptz,
    posting_transaction_id uuid references transactions(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint uq_interest_accruals_date unique (tenant_id, account_id, accrual_date)
);

create index idx_interest_accruals_account
    on interest_accruals(tenant_id, account_id);

create index idx_interest_accruals_unposted
    on interest_accruals(tenant_id, account_type, is_posted)
    where is_posted = false;

create trigger interest_accruals_updated_at
    before update on interest_accruals
    for each row execute function update_updated_at();

comment on table interest_accruals is 'Daily interest accrual records';


create table interest_posting_batches (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete cascade,
    posting_date date not null,
    account_type varchar not null,
    total_accounts integer not null default 0,
    total_amount bigint not null default 0,
    status varchar not null check (status in ('PENDING','PROCESSING','COMPLETED','FAILED')),
    started_at timestamptz,
    completed_at timestamptz,
    created_by uuid references users(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_interest_posting_batches_tenant
    on interest_posting_batches(tenant_id, account_type);

create trigger interest_posting_batches_updated_at
    before update on interest_posting_batches
    for each row execute function update_updated_at();

comment on table interest_posting_batches is 'Batch posting records for accrued interest';

-- ============================================================
-- 2. FUNCTIONS
-- ============================================================

-- Function: calculate_daily_interest
create or replace function calculate_daily_interest(
    p_tenant_id uuid,
    p_account_id uuid,
    p_accrual_date date,
    p_account_type varchar
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_rate_bps integer;
    v_principal bigint;
    v_day_basis varchar := 'ACTUAL_365';
    v_accrued_amount bigint;
    v_accrual_id uuid;
begin
    -- 1. Check if it's already accrued
    if exists (
        select 1 from interest_accruals
        where tenant_id = p_tenant_id
          and account_id = p_account_id
          and accrual_date = p_accrual_date
    ) then
        return jsonb_build_object('status', 'ALREADY_ACCRUED', 'account_id', p_account_id);
    end if;

    -- 2. Get principal and default rate
    if p_account_type = 'DEPOSIT' then
        select a.ledger_balance, ap.interest_rate
        into v_principal, v_rate_bps
        from accounts a
        join account_products ap on a.product_id = ap.id
        where a.id = p_account_id and a.tenant_id = p_tenant_id;
    else
        -- 'LOAN' (using loan_products structure)
        select a.ledger_balance, lp.annual_interest_rate, lp.interest_calculation_basis
        into v_principal, v_rate_bps, v_day_basis
        from accounts a
        join loan_products lp on a.product_id = lp.id
        where a.id = p_account_id and a.tenant_id = p_tenant_id;
    end if;

    -- 3. Check for config override
    declare
        v_override integer;
    begin
        select annual_rate_bps into v_override
        from interest_accrual_configs
        where tenant_id = p_tenant_id
          and account_id = p_account_id
          and is_active = true
          and effective_from <= p_accrual_date
          and (effective_to is null or effective_to >= p_accrual_date)
        order by effective_from desc limit 1;

        if v_override is not null then
            v_rate_bps := v_override;
        end if;
    end;
    
    if v_rate_bps is null or v_rate_bps = 0 or v_principal = 0 then
        return jsonb_build_object('status', 'SKIPPED', 'reason', 'ZERO_RATE_OR_PRINCIPAL');
    end if;

    -- 4. Calculate amount
    v_accrued_amount := round((v_principal::numeric * v_rate_bps::numeric) / (10000.0 * 365.0));

    if v_accrued_amount = 0 then
        return jsonb_build_object('status', 'SKIPPED', 'reason', 'ZERO_AMOUNT');
    end if;

    -- 5. Insert
    insert into interest_accruals(
        tenant_id, account_id, account_type, accrual_date, 
        principal_amount, annual_rate_bps, day_count_basis, accrued_amount
    ) values (
        p_tenant_id, p_account_id, p_account_type, p_accrual_date,
        v_principal, v_rate_bps, v_day_basis, v_accrued_amount
    ) returning id into v_accrual_id;

    return jsonb_build_object(
        'status', 'ACCRUED',
        'accrual_id', v_accrual_id,
        'accrued_amount', v_accrued_amount
    );
end;
$$;
alter function calculate_daily_interest owner to postgres;


-- Function: accrue_interest_for_date
create or replace function accrue_interest_for_date(
    p_tenant_id uuid,
    p_accrual_date date,
    p_account_type varchar
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_account record;
    v_count integer := 0;
    v_total_amount bigint := 0;
    v_result jsonb;
begin
    for v_account in 
        select id from accounts 
        where tenant_id = p_tenant_id 
          and status = 'ACTIVE' 
    loop
        declare
            v_valid boolean := false;
        begin
            if p_account_type = 'DEPOSIT' then
                select true into v_valid from account_products p join accounts a on a.product_id = p.id where a.id = v_account.id;
            else
                select true into v_valid from loan_products p join accounts a on a.product_id = p.id where a.id = v_account.id;
            end if;

            if v_valid then
                v_result := calculate_daily_interest(p_tenant_id, v_account.id, p_accrual_date, p_account_type);
                if v_result->>'status' = 'ACCRUED' then
                    v_count := v_count + 1;
                    v_total_amount := v_total_amount + (v_result->>'accrued_amount')::bigint;
                end if;
            end if;
        end;
    end loop;

    return jsonb_build_object(
        'accounts_processed', v_count,
        'total_accrued', v_total_amount
    );
end;
$$;
alter function accrue_interest_for_date owner to postgres;


-- Function: post_accrued_interest
create or replace function post_accrued_interest(
    p_tenant_id uuid,
    p_posting_date date,
    p_account_type varchar,
    p_created_by uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch_id uuid;
    v_account record;
    v_total_amount bigint := 0;
    v_count integer := 0;
    v_dr_gl uuid;
    v_cr_gl uuid;
    v_tx_id uuid;
    v_tx_ref varchar;
begin
    -- Create batch
    insert into interest_posting_batches(
        tenant_id, posting_date, account_type, status, started_at, created_by
    ) values (
        p_tenant_id, p_posting_date, p_account_type, 'PROCESSING', now(), p_created_by
    ) returning id into v_batch_id;

    -- Aggregate unposted accruals
    for v_account in
        select account_id, sum(accrued_amount) as total_accrued
        from interest_accruals
        where tenant_id = p_tenant_id
          and account_type = p_account_type
          and accrual_date <= p_posting_date
          and is_posted = false
        group by account_id
        having sum(accrued_amount) > 0
    loop
        v_tx_ref := 'INT-' || p_account_type || '-' || to_char(p_posting_date, 'YYYYMMDD') || '-' || substring(v_account.account_id::text, 1, 8);

        if p_account_type = 'DEPOSIT' then
            v_dr_gl := get_product_gl_account(p_tenant_id, (select product_id from accounts where id = v_account.account_id), 'INTEREST_EXPENSE');
            if v_dr_gl is null then
                select id into v_dr_gl from ledger_accounts where tenant_id = p_tenant_id and account_code = '5020';
            end if;
            v_cr_gl := (select ledger_account_id from accounts where id = v_account.account_id);
        else
            v_dr_gl := get_loan_product_gl_account(p_tenant_id, (select product_id from accounts where id = v_account.account_id), 'INTEREST_RECEIVABLE');
            v_cr_gl := get_loan_product_gl_account(p_tenant_id, (select product_id from accounts where id = v_account.account_id), 'INTEREST_INCOME');
        end if;

        if v_dr_gl is not null and v_cr_gl is not null then
            insert into transactions (
                tenant_id, reference, transaction_type, status, currency, amount, description, posted_at, created_by
            ) values (
                p_tenant_id, v_tx_ref, 'INTEREST_POSTING', 'POSTED', 'GHS', v_account.total_accrued, 'Interest posting for ' || p_posting_date, now(), p_created_by
            ) returning id into v_tx_id;

            insert into transaction_entries(transaction_id, tenant_id, ledger_account_id, debit, credit, description)
            values (v_tx_id, p_tenant_id, v_dr_gl, v_account.total_accrued, 0, 'Interest Dr');

            insert into transaction_entries(transaction_id, tenant_id, ledger_account_id, debit, credit, description)
            values (v_tx_id, p_tenant_id, v_cr_gl, 0, v_account.total_accrued, 'Interest Cr');

            if p_account_type = 'DEPOSIT' then
                update accounts
                set ledger_balance = ledger_balance + v_account.total_accrued,
                    available_balance = available_balance + v_account.total_accrued
                where id = v_account.account_id;
            end if;

            update interest_accruals
            set is_posted = true, posted_at = now(), posting_transaction_id = v_tx_id
            where tenant_id = p_tenant_id
              and account_id = v_account.account_id
              and account_type = p_account_type
              and accrual_date <= p_posting_date
              and is_posted = false;

            v_count := v_count + 1;
            v_total_amount := v_total_amount + v_account.total_accrued;
        end if;
    end loop;

    update interest_posting_batches
    set status = 'COMPLETED', completed_at = now(), total_accounts = v_count, total_amount = v_total_amount
    where id = v_batch_id;

    return jsonb_build_object(
        'batch_id', v_batch_id,
        'accounts_posted', v_count,
        'total_posted', v_total_amount
    );
end;
$$;
alter function post_accrued_interest owner to postgres;

-- Function: get_account_accrued_interest
create or replace function get_account_accrued_interest(
    p_tenant_id uuid,
    p_account_id uuid,
    p_from_date date,
    p_to_date date
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_total_accrued bigint;
    v_total_posted bigint;
    v_total_unposted bigint;
    v_records jsonb;
begin
    select 
        coalesce(sum(accrued_amount), 0),
        coalesce(sum(case when is_posted then accrued_amount else 0 end), 0),
        coalesce(sum(case when not is_posted then accrued_amount else 0 end), 0)
    into v_total_accrued, v_total_posted, v_total_unposted
    from interest_accruals
    where tenant_id = p_tenant_id
      and account_id = p_account_id
      and accrual_date between p_from_date and p_to_date;

    select coalesce(jsonb_agg(
        jsonb_build_object(
            'accrual_date', accrual_date,
            'principal_amount', principal_amount,
            'annual_rate_bps', annual_rate_bps,
            'accrued_amount', accrued_amount,
            'is_posted', is_posted
        ) order by accrual_date
    ), '[]'::jsonb)
    into v_records
    from interest_accruals
    where tenant_id = p_tenant_id
      and account_id = p_account_id
      and accrual_date between p_from_date and p_to_date;

    return jsonb_build_object(
        'account_id', p_account_id,
        'from_date', p_from_date,
        'to_date', p_to_date,
        'total_accrued', v_total_accrued,
        'total_posted', v_total_posted,
        'total_unposted', v_total_unposted,
        'records', v_records
    );
end;
$$;
alter function get_account_accrued_interest owner to postgres;

commit;
