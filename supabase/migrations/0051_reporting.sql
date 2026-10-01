-- ============================================================
-- REPORTING & STATEMENTS
-- Migration: 0051
-- Milestone: 21
--
-- 1. report_snapshots table
-- 2. Reporting functions (account statement, trial balance, etc.)
-- ============================================================

begin;

-- ============================================================
-- 1. REPORT SNAPSHOTS TABLE
-- ============================================================

create table report_snapshots (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete cascade,

    report_type varchar(100) not null,
    report_date date not null,
    parameters jsonb,
    result_data jsonb not null,

    generated_by uuid null
        references users(id)
        on delete set null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_report_snapshots_search
    on report_snapshots(tenant_id, report_type, report_date);

create trigger report_snapshots_updated_at
before update on report_snapshots
for each row
execute function update_updated_at();

comment on table report_snapshots is 'Stores historical or generated snapshots of reports for performance or audit purposes';


-- ============================================================
-- 2. GENERATE ACCOUNT STATEMENT
-- ============================================================

create or replace function generate_account_statement(
    p_tenant_id uuid,
    p_account_id uuid,
    p_from_date date,
    p_to_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_account record;
    v_opening_balance bigint := 0;
    v_closing_balance bigint := 0;
    v_total_debits bigint := 0;
    v_total_credits bigint := 0;
    v_transactions jsonb;
begin
    -- Get account details
    select a.account_number, a.currency, a.status, a.ledger_account_id,
           p.name as product_name, c.first_name, c.last_name, c.company_name, c.customer_type
    into v_account
    from accounts a
    left join account_products p on p.id = a.product_id
    left join customers c on c.id = a.customer_id
    where a.id = p_account_id
      and a.tenant_id = p_tenant_id;

    if not found then
        raise exception 'Account not found';
    end if;

    -- Calculate opening balance (all entries before p_from_date)
    select coalesce(sum(credit) - sum(debit), 0)
    into v_opening_balance
    from transaction_entries te
    join transactions t on t.id = te.transaction_id
    where te.ledger_account_id = v_account.ledger_account_id
      and t.tenant_id = p_tenant_id
      and t.status = 'POSTED'
      and t.value_date < p_from_date;

    -- Get transactions within date range
    with stmt_transactions as (
        select
            t.id,
            t.reference,
            t.transaction_type,
            t.value_date,
            t.amount,
            te.debit,
            te.credit,
            t.created_at
        from transaction_entries te
        join transactions t on t.id = te.transaction_id
        where te.ledger_account_id = v_account.ledger_account_id
          and t.tenant_id = p_tenant_id
          and t.status = 'POSTED'
          and t.value_date >= p_from_date
          and t.value_date <= p_to_date
        order by t.value_date asc, t.created_at asc
    ),
    calculated as (
        select
            id, reference, transaction_type, value_date, amount, debit, credit, created_at,
            v_opening_balance + sum(credit - debit) over (order by value_date asc, created_at asc rows between unbounded preceding and current row) as running_balance
        from stmt_transactions
    )
    select
        coalesce(jsonb_agg(jsonb_build_object(
            'id', id,
            'reference', reference,
            'transaction_type', transaction_type,
            'value_date', value_date,
            'amount', amount,
            'debit', debit,
            'credit', credit,
            'running_balance', running_balance,
            'created_at', created_at
        )), '[]'::jsonb),
        coalesce(sum(debit), 0),
        coalesce(sum(credit), 0)
    into v_transactions, v_total_debits, v_total_credits
    from calculated;

    v_closing_balance := v_opening_balance + v_total_credits - v_total_debits;

    return jsonb_build_object(
        'account_details', jsonb_build_object(
            'account_number', v_account.account_number,
            'currency', v_account.currency,
            'status', v_account.status,
            'product_name', v_account.product_name,
            'customer_name', case
                when v_account.customer_type = 'INDIVIDUAL' then v_account.first_name || ' ' || v_account.last_name
                else v_account.company_name
            end
        ),
        'statement_period', jsonb_build_object(
            'from_date', p_from_date,
            'to_date', p_to_date
        ),
        'summary', jsonb_build_object(
            'opening_balance', v_opening_balance,
            'closing_balance', v_closing_balance,
            'total_debits', v_total_debits,
            'total_credits', v_total_credits
        ),
        'transactions', v_transactions
    );
end;
$$;

alter function generate_account_statement(uuid, uuid, date, date) owner to postgres;
comment on function generate_account_statement is 'Generates an account statement with running balance for a given date range';


-- ============================================================
-- 3. GENERATE TRIAL BALANCE
-- ============================================================

create or replace function generate_trial_balance(
    p_tenant_id uuid,
    p_as_of_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_results jsonb;
    v_total_debits bigint := 0;
    v_total_credits bigint := 0;
begin
    with tb_data as (
        select
            la.account_code,
            la.account_name,
            la.account_type,
            coalesce(sum(te.debit), 0) as total_debit,
            coalesce(sum(te.credit), 0) as total_credit
        from ledger_accounts la
        left join transaction_entries te on te.ledger_account_id = la.id
        left join transactions t on t.id = te.transaction_id
            and t.tenant_id = p_tenant_id
            and t.status = 'POSTED'
            and t.value_date <= p_as_of_date
        where la.tenant_id = p_tenant_id
          -- Exclude sub-accounts for trial balance summary
          and la.parent_account_id is null
        group by la.id, la.account_code, la.account_name, la.account_type
        having coalesce(sum(te.debit), 0) > 0 or coalesce(sum(te.credit), 0) > 0
        order by la.account_code
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'account_code', account_code,
        'account_name', account_name,
        'account_type', account_type,
        'total_debit', total_debit,
        'total_credit', total_credit,
        'balance', case
            when account_type in ('ASSET', 'EXPENSE') then total_debit - total_credit
            else total_credit - total_debit
        end
    )), '[]'::jsonb),
    coalesce(sum(total_debit), 0),
    coalesce(sum(total_credit), 0)
    into v_results, v_total_debits, v_total_credits
    from tb_data;

    return jsonb_build_object(
        'as_of_date', p_as_of_date,
        'totals', jsonb_build_object(
            'total_debit', v_total_debits,
            'total_credit', v_total_credits,
            'is_balanced', v_total_debits = v_total_credits
        ),
        'accounts', v_results
    );
end;
$$;

alter function generate_trial_balance(uuid, date) owner to postgres;
comment on function generate_trial_balance is 'Generates a trial balance report summing debits and credits up to a specific date';


-- ============================================================
-- 4. GENERATE GL REPORT
-- ============================================================

create or replace function generate_gl_report(
    p_tenant_id uuid,
    p_account_code varchar,
    p_from_date date,
    p_to_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ledger_account record;
    v_opening_balance bigint := 0;
    v_entries jsonb;
begin
    select id, account_code, account_name, account_type, currency
    into v_ledger_account
    from ledger_accounts
    where tenant_id = p_tenant_id
      and account_code = p_account_code;

    if not found then
        raise exception 'Ledger account not found';
    end if;

    -- Calculate opening balance
    select coalesce(sum(debit), 0) - coalesce(sum(credit), 0)
    into v_opening_balance
    from transaction_entries te
    join transactions t on t.id = te.transaction_id
    where te.ledger_account_id = v_ledger_account.id
      and t.tenant_id = p_tenant_id
      and t.status = 'POSTED'
      and t.value_date < p_from_date;

    -- Note: for liabilities/equity/income, credit is positive. Let's return balance based on account type.
    if v_ledger_account.account_type in ('LIABILITY', 'EQUITY', 'INCOME') then
        v_opening_balance := -v_opening_balance;
    end if;

    with gl_entries as (
        select
            t.reference,
            t.transaction_type,
            t.value_date,
            te.debit,
            te.credit,
            t.created_at
        from transaction_entries te
        join transactions t on t.id = te.transaction_id
        where te.ledger_account_id = v_ledger_account.id
          and t.tenant_id = p_tenant_id
          and t.status = 'POSTED'
          and t.value_date >= p_from_date
          and t.value_date <= p_to_date
        order by t.value_date asc, t.created_at asc
    ),
    calculated as (
        select
            reference, transaction_type, value_date, debit, credit, created_at,
            case
                when v_ledger_account.account_type in ('ASSET', 'EXPENSE') then
                    v_opening_balance + sum(debit - credit) over (order by value_date asc, created_at asc rows between unbounded preceding and current row)
                else
                    v_opening_balance + sum(credit - debit) over (order by value_date asc, created_at asc rows between unbounded preceding and current row)
            end as running_balance
        from gl_entries
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'reference', reference,
        'transaction_type', transaction_type,
        'value_date', value_date,
        'debit', debit,
        'credit', credit,
        'running_balance', running_balance,
        'created_at', created_at
    )), '[]'::jsonb)
    into v_entries
    from calculated;

    return jsonb_build_object(
        'account_details', jsonb_build_object(
            'account_code', v_ledger_account.account_code,
            'account_name', v_ledger_account.account_name,
            'account_type', v_ledger_account.account_type,
            'currency', v_ledger_account.currency
        ),
        'period', jsonb_build_object(
            'from_date', p_from_date,
            'to_date', p_to_date
        ),
        'opening_balance', v_opening_balance,
        'entries', v_entries
    );
end;
$$;

alter function generate_gl_report(uuid, varchar, date, date) owner to postgres;
comment on function generate_gl_report is 'Generates detailed ledger entries for a specific GL account';


-- ============================================================
-- 5. GENERATE CASH POSITION
-- ============================================================

create or replace function generate_cash_position(
    p_tenant_id uuid,
    p_branch_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_results jsonb;
begin
    with cash_accounts as (
        select
            la.account_code,
            la.account_name,
            la.currency,
            la.current_balance as balance
        from ledger_accounts la
        where la.tenant_id = p_tenant_id
          and la.account_code like '1010%'
          and (
              p_branch_id is null
              or la.id in (
                  select cash_account_id from teller_cashboxes where branch_id = p_branch_id
              )
          )
        order by la.account_code
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'account_code', account_code,
        'account_name', account_name,
        'balance', balance,
        'currency', currency
    )), '[]'::jsonb)
    into v_results
    from cash_accounts;

    return jsonb_build_object(
        'branch_id', p_branch_id,
        'cash_accounts', v_results
    );
end;
$$;

alter function generate_cash_position(uuid, uuid) owner to postgres;
comment on function generate_cash_position is 'Generates current cash balances, optionally filtered by branch';


-- ============================================================
-- 6. GENERATE DAILY TRANSACTION REPORT
-- ============================================================

create or replace function generate_daily_transaction_report(
    p_tenant_id uuid,
    p_business_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_summary jsonb;
    v_transactions jsonb;
begin
    -- Summary by transaction type
    with summary_data as (
        select
            transaction_type,
            currency,
            count(*) as tx_count,
            sum(amount) as total_amount
        from transactions
        where tenant_id = p_tenant_id
          and value_date = p_business_date
          and status = 'POSTED'
        group by transaction_type, currency
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'transaction_type', transaction_type,
        'currency', currency,
        'count', tx_count,
        'total_amount', total_amount
    )), '[]'::jsonb)
    into v_summary
    from summary_data;

    -- Detailed transactions
    with detailed_data as (
        select
            id,
            reference,
            transaction_type,
            amount,
            currency,
            created_at
        from transactions
        where tenant_id = p_tenant_id
          and value_date = p_business_date
          and status = 'POSTED'
        order by created_at desc
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', id,
        'reference', reference,
        'transaction_type', transaction_type,
        'amount', amount,
        'currency', currency,
        'created_at', created_at
    )), '[]'::jsonb)
    into v_transactions
    from detailed_data;

    return jsonb_build_object(
        'business_date', p_business_date,
        'summary', v_summary,
        'transactions', v_transactions
    );
end;
$$;

alter function generate_daily_transaction_report(uuid, date) owner to postgres;
comment on function generate_daily_transaction_report is 'Generates a summary and detail of all posted transactions for a business date';


-- ============================================================
-- 7. GENERATE INCOME REPORT
-- ============================================================

create or replace function generate_income_report(
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
    v_results jsonb;
    v_total_income bigint := 0;
begin
    with income_data as (
        select
            la.account_code,
            la.account_name,
            la.currency,
            -- For income, credit increases balance
            coalesce(sum(te.credit - te.debit), 0) as income_amount
        from ledger_accounts la
        join transaction_entries te on te.ledger_account_id = la.id
        join transactions t on t.id = te.transaction_id
        where la.tenant_id = p_tenant_id
          and la.account_type = 'INCOME'
          and t.tenant_id = p_tenant_id
          and t.status = 'POSTED'
          and t.value_date >= p_from_date
          and t.value_date <= p_to_date
        group by la.id, la.account_code, la.account_name, la.currency
        having coalesce(sum(te.credit - te.debit), 0) <> 0
        order by la.account_code
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'account_code', account_code,
        'account_name', account_name,
        'income_amount', income_amount,
        'currency', currency
    )), '[]'::jsonb),
    coalesce(sum(income_amount), 0)
    into v_results, v_total_income
    from income_data;

    return jsonb_build_object(
        'period', jsonb_build_object(
            'from_date', p_from_date,
            'to_date', p_to_date
        ),
        'total_income', v_total_income,
        'income_accounts', v_results
    );
end;
$$;

alter function generate_income_report(uuid, date, date) owner to postgres;
comment on function generate_income_report is 'Generates a summary of all income within a date range';

commit;
