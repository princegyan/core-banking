-- ============================================================
-- CORE BANKING ACCOUNTING PERIOD CONTROL
-- Migration: 0010
-- ============================================================

begin;

-- ============================================================
-- 1. CREATE CURRENT ACCOUNTING PERIOD
-- ============================================================

insert into accounting_periods (
  tenant_id,
  period_name,
  start_date,
  end_date,
  status
)
values (
  '669d95bb-167c-483d-b652-898bb1e78ac7',
  to_char(current_date, 'YYYY-MM'),
  date_trunc('month', current_date)::date,
  (
    date_trunc('month', current_date)
    + interval '1 month'
    - interval '1 day'
  )::date,
  'OPEN'
)
on conflict (tenant_id, period_name) do nothing;


-- ============================================================
-- 2. LINK BUSINESS DATE TO ACCOUNTING PERIOD
-- ============================================================

alter table business_dates
  add column if not exists accounting_period_id uuid
    references accounting_periods(id)
    on delete restrict;

create index if not exists idx_business_dates_accounting_period
  on business_dates(tenant_id, accounting_period_id);


update business_dates bd
set accounting_period_id = ap.id,
    updated_at = now()
from accounting_periods ap
where bd.tenant_id = ap.tenant_id
  and bd.business_date between ap.start_date and ap.end_date
  and bd.accounting_period_id is null;


-- ============================================================
-- 3. REQUIRE ACCOUNTING PERIOD FOR BUSINESS DATES
-- ============================================================

alter table business_dates
  alter column accounting_period_id set not null;


-- ============================================================
-- 4. LINK TRANSACTIONS TO ACCOUNTING PERIOD
-- ============================================================

update transactions tx
set accounting_period_id = bd.accounting_period_id
from business_dates bd
where tx.business_date_id = bd.id
  and tx.accounting_period_id is null;


-- ============================================================
-- 5. HARDEN DEPOSIT POSTING
-- ============================================================

create or replace function post_deposit(
  p_tenant_id uuid,
  p_account_id uuid,
  p_amount bigint,
  p_description text,
  p_idempotency_key varchar,
  p_created_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account accounts%rowtype;
  v_customer_ledger ledger_accounts%rowtype;
  v_cash_ledger ledger_accounts%rowtype;
  v_business_date business_dates%rowtype;
  v_accounting_period accounting_periods%rowtype;
  v_transaction_id uuid;
  v_reference varchar;
  v_duplicate_transaction transactions%rowtype;
  v_new_balance bigint;
begin

  if p_amount <= 0 then
    raise exception 'Deposit amount must be greater than zero';
  end if;


  -- ----------------------------------------------------------
  -- Idempotency
  -- ----------------------------------------------------------

  if p_idempotency_key is not null then

    select *
    into v_duplicate_transaction
    from transactions
    where tenant_id = p_tenant_id
      and idempotency_key = p_idempotency_key
    limit 1;

    if found then

      select a.available_balance
      into v_new_balance
      from accounts a
      where a.id = p_account_id
        and a.tenant_id = p_tenant_id;

      return jsonb_build_object(
        'transaction_id', v_duplicate_transaction.id,
        'reference', v_duplicate_transaction.reference,
        'status', v_duplicate_transaction.status,
        'amount', v_duplicate_transaction.amount,
        'currency', v_duplicate_transaction.currency,
        'balance', v_new_balance,
        'duplicate', true
      );

    end if;

  end if;


  -- ----------------------------------------------------------
  -- Account
  -- ----------------------------------------------------------

  select *
  into v_account
  from accounts
  where id = p_account_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Account not found';
  end if;

  if v_account.status <> 'ACTIVE' then
    raise exception 'Account is not active';
  end if;


  -- ----------------------------------------------------------
  -- Business Date
  -- ----------------------------------------------------------

  select *
  into v_business_date
  from business_dates
  where tenant_id = p_tenant_id
    and status = 'OPEN'
  order by business_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No open business date for tenant';
  end if;


  -- ----------------------------------------------------------
  -- Accounting Period
  -- ----------------------------------------------------------

  select *
  into v_accounting_period
  from accounting_periods
  where id = v_business_date.accounting_period_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Accounting period not found';
  end if;

  if v_accounting_period.status <> 'OPEN' then
    raise exception 'Accounting period is closed';
  end if;

  if v_business_date.business_date
     not between v_accounting_period.start_date
     and v_accounting_period.end_date then
    raise exception 'Business date is outside accounting period';
  end if;


  -- ----------------------------------------------------------
  -- Customer Ledger
  -- ----------------------------------------------------------

  select *
  into v_customer_ledger
  from ledger_accounts
  where id = v_account.ledger_account_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Customer ledger account not found';
  end if;


  -- ----------------------------------------------------------
  -- Cash Ledger
  -- ----------------------------------------------------------

  select *
  into v_cash_ledger
  from ledger_accounts
  where tenant_id = p_tenant_id
    and account_code = '1010'
    and is_active = true
  for update;

  if not found then
    raise exception 'Cash ledger account not found';
  end if;


  -- ----------------------------------------------------------
  -- Transaction Reference
  -- ----------------------------------------------------------

  v_reference :=
    generate_transaction_reference('DEPOSIT');


  -- ----------------------------------------------------------
  -- Create Transaction
  -- ----------------------------------------------------------

  insert into transactions (
    tenant_id,
    reference,
    transaction_type,
    status,
    currency,
    amount,
    description,
    idempotency_key,
    posted_at,
    created_by,
    business_date_id,
    accounting_period_id,
    value_date
  )
  values (
    p_tenant_id,
    v_reference,
    'DEPOSIT',
    'POSTED',
    v_account.currency,
    p_amount,
    p_description,
    p_idempotency_key,
    now(),
    p_created_by,
    v_business_date.id,
    v_accounting_period.id,
    v_business_date.business_date
  )
  returning id
  into v_transaction_id;


  -- ----------------------------------------------------------
  -- Ledger Entries
  -- ----------------------------------------------------------

  insert into transaction_entries (
    transaction_id,
    tenant_id,
    ledger_account_id,
    debit,
    credit,
    description
  )
  values
  (
    v_transaction_id,
    p_tenant_id,
    v_cash_ledger.id,
    p_amount,
    0,
    p_description
  ),
  (
    v_transaction_id,
    p_tenant_id,
    v_customer_ledger.id,
    0,
    p_amount,
    p_description
  );


  -- ----------------------------------------------------------
  -- Ledger Balances
  -- ----------------------------------------------------------

  update ledger_accounts
  set current_balance = current_balance + p_amount,
      updated_at = now()
  where id = v_cash_ledger.id;

  update ledger_accounts
  set current_balance = current_balance + p_amount,
      updated_at = now()
  where id = v_customer_ledger.id;


  -- ----------------------------------------------------------
  -- Account Balances
  -- ----------------------------------------------------------

  update accounts
  set ledger_balance = ledger_balance + p_amount,
      available_balance = available_balance + p_amount,
      updated_at = now()
  where id = v_account.id
  returning available_balance
  into v_new_balance;


  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'reference', v_reference,
    'status', 'POSTED',
    'amount', p_amount,
    'balance', v_new_balance,
    'currency', v_account.currency,
    'duplicate', false,
    'business_date', v_business_date.business_date,
    'business_date_id', v_business_date.id,
    'accounting_period', v_accounting_period.period_name,
    'accounting_period_id', v_accounting_period.id,
    'account_id', v_account.id,
    'account_number', v_account.account_number
  );

end;
$$;


-- ============================================================
-- 6. HARDEN WITHDRAWAL POSTING
-- ============================================================

create or replace function post_withdrawal(
  p_tenant_id uuid,
  p_account_id uuid,
  p_amount bigint,
  p_description text,
  p_idempotency_key varchar,
  p_created_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account accounts%rowtype;
  v_customer_ledger ledger_accounts%rowtype;
  v_cash_ledger ledger_accounts%rowtype;
  v_business_date business_dates%rowtype;
  v_accounting_period accounting_periods%rowtype;
  v_transaction_id uuid;
  v_reference varchar;
  v_duplicate_transaction transactions%rowtype;
  v_new_balance bigint;
begin

  if p_amount <= 0 then
    raise exception 'Withdrawal amount must be greater than zero';
  end if;


  -- ----------------------------------------------------------
  -- Idempotency
  -- ----------------------------------------------------------

  if p_idempotency_key is not null then

    select *
    into v_duplicate_transaction
    from transactions
    where tenant_id = p_tenant_id
      and idempotency_key = p_idempotency_key
    limit 1;

    if found then

      select a.available_balance
      into v_new_balance
      from accounts a
      where a.id = p_account_id
        and a.tenant_id = p_tenant_id;

      return jsonb_build_object(
        'transaction_id', v_duplicate_transaction.id,
        'reference', v_duplicate_transaction.reference,
        'status', v_duplicate_transaction.status,
        'amount', v_duplicate_transaction.amount,
        'currency', v_duplicate_transaction.currency,
        'balance', v_new_balance,
        'duplicate', true
      );

    end if;

  end if;


  -- ----------------------------------------------------------
  -- Account
  -- ----------------------------------------------------------

  select *
  into v_account
  from accounts
  where id = p_account_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Account not found';
  end if;

  if v_account.status <> 'ACTIVE' then
    raise exception 'Account is not active';
  end if;


  -- ----------------------------------------------------------
  -- Available Balance
  -- ----------------------------------------------------------

  if v_account.available_balance < p_amount then
    raise exception 'Insufficient available balance';
  end if;


  -- ----------------------------------------------------------
  -- Business Date
  -- ----------------------------------------------------------

  select *
  into v_business_date
  from business_dates
  where tenant_id = p_tenant_id
    and status = 'OPEN'
  order by business_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No open business date for tenant';
  end if;


  -- ----------------------------------------------------------
  -- Accounting Period
  -- ----------------------------------------------------------

  select *
  into v_accounting_period
  from accounting_periods
  where id = v_business_date.accounting_period_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Accounting period not found';
  end if;

  if v_accounting_period.status <> 'OPEN' then
    raise exception 'Accounting period is closed';
  end if;

  if v_business_date.business_date
     not between v_accounting_period.start_date
     and v_accounting_period.end_date then
    raise exception 'Business date is outside accounting period';
  end if;


  -- ----------------------------------------------------------
  -- Customer Ledger
  -- ----------------------------------------------------------

  select *
  into v_customer_ledger
  from ledger_accounts
  where id = v_account.ledger_account_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Customer ledger account not found';
  end if;


  -- ----------------------------------------------------------
  -- Cash Ledger
  -- ----------------------------------------------------------

  select *
  into v_cash_ledger
  from ledger_accounts
  where tenant_id = p_tenant_id
    and account_code = '1010'
    and is_active = true
  for update;

  if not found then
    raise exception 'Cash ledger account not found';
  end if;


  -- ----------------------------------------------------------
  -- Transaction Reference
  -- ----------------------------------------------------------

  v_reference :=
    generate_transaction_reference('WITHDRAWAL');


  -- ----------------------------------------------------------
  -- Create Transaction
  -- ----------------------------------------------------------

  insert into transactions (
    tenant_id,
    reference,
    transaction_type,
    status,
    currency,
    amount,
    description,
    idempotency_key,
    posted_at,
    created_by,
    business_date_id,
    accounting_period_id,
    value_date
  )
  values (
    p_tenant_id,
    v_reference,
    'WITHDRAWAL',
    'POSTED',
    v_account.currency,
    p_amount,
    p_description,
    p_idempotency_key,
    now(),
    p_created_by,
    v_business_date.id,
    v_accounting_period.id,
    v_business_date.business_date
  )
  returning id
  into v_transaction_id;


  -- ----------------------------------------------------------
  -- Ledger Entries
  -- ----------------------------------------------------------

  insert into transaction_entries (
    transaction_id,
    tenant_id,
    ledger_account_id,
    debit,
    credit,
    description
  )
  values
  (
    v_transaction_id,
    p_tenant_id,
    v_customer_ledger.id,
    p_amount,
    0,
    p_description
  ),
  (
    v_transaction_id,
    p_tenant_id,
    v_cash_ledger.id,
    0,
    p_amount,
    p_description
  );


  -- ----------------------------------------------------------
  -- Ledger Balances
  -- ----------------------------------------------------------

  update ledger_accounts
  set current_balance = current_balance - p_amount,
      updated_at = now()
  where id = v_customer_ledger.id;

  update ledger_accounts
  set current_balance = current_balance - p_amount,
      updated_at = now()
  where id = v_cash_ledger.id;


  -- ----------------------------------------------------------
  -- Account Balances
  -- ----------------------------------------------------------

  update accounts
  set ledger_balance = ledger_balance - p_amount,
      available_balance = available_balance - p_amount,
      updated_at = now()
  where id = v_account.id
  returning available_balance
  into v_new_balance;


  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'reference', v_reference,
    'status', 'POSTED',
    'amount', p_amount,
    'balance', v_new_balance,
    'currency', v_account.currency,
    'duplicate', false,
    'business_date', v_business_date.business_date,
    'business_date_id', v_business_date.id,
    'accounting_period', v_accounting_period.period_name,
    'accounting_period_id', v_accounting_period.id,
    'account_id', v_account.id,
    'account_number', v_account.account_number
  );

end;
$$;


-- ============================================================
-- 7. FUNCTION OWNERSHIP
-- ============================================================

alter function post_deposit(
  uuid,
  uuid,
  bigint,
  text,
  varchar,
  uuid
) owner to postgres;

alter function post_withdrawal(
  uuid,
  uuid,
  bigint,
  text,
  varchar,
  uuid
) owner to postgres;


-- ============================================================
-- 8. COMMENTS
-- ============================================================

comment on column business_dates.accounting_period_id is
  'Accounting period containing the banking business date.';

comment on column transactions.accounting_period_id is
  'Accounting period under which the transaction was posted.';


commit;