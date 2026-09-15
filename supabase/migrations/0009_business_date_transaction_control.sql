-- ============================================================
-- CORE BANKING BUSINESS DATE TRANSACTION CONTROL
-- Migration: 0009
-- ============================================================

begin;

-- ============================================================
-- 1. CREATE THE INITIAL BUSINESS DATE
-- ============================================================

insert into business_dates (
  tenant_id,
  business_date,
  status
)
values (
  '669d95bb-167c-483d-b652-898bb1e78ac7',
  current_date,
  'OPEN'
)
on conflict (tenant_id, business_date) do nothing;


-- ============================================================
-- 2. HARDEN DEPOSIT POSTING
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
  v_transaction_id uuid;
  v_reference varchar;
  v_duplicate_transaction transactions%rowtype;
  v_new_balance bigint;
begin

  -- ----------------------------------------------------------
  -- Amount validation
  -- ----------------------------------------------------------

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
  -- Current business date
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
  -- Customer ledger
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
  -- Tenant cash ledger
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
  -- Transaction reference
  -- ----------------------------------------------------------

  v_reference :=
    generate_transaction_reference('DEPOSIT');


  -- ----------------------------------------------------------
  -- Create transaction
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
    v_business_date.business_date
  )
  returning id
  into v_transaction_id;


  -- ----------------------------------------------------------
  -- Ledger entries
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
  -- Ledger balances
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
  -- Customer account balances
  -- ----------------------------------------------------------

  update accounts
  set ledger_balance = ledger_balance + p_amount,
      available_balance = available_balance + p_amount,
      updated_at = now()
  where id = v_account.id
  returning available_balance
  into v_new_balance;


  -- ----------------------------------------------------------
  -- Response
  -- ----------------------------------------------------------

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
    'account_id', v_account.id,
    'account_number', v_account.account_number
  );

end;
$$;


-- ============================================================
-- 3. HARDEN WITHDRAWAL POSTING
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
  v_transaction_id uuid;
  v_reference varchar;
  v_duplicate_transaction transactions%rowtype;
  v_new_balance bigint;
begin

  -- ----------------------------------------------------------
  -- Amount validation
  -- ----------------------------------------------------------

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
  -- Current business date
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
  -- Available balance
  -- ----------------------------------------------------------

  if v_account.available_balance < p_amount then
    raise exception 'Insufficient available balance';
  end if;


  -- ----------------------------------------------------------
  -- Customer ledger
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
  -- Tenant cash ledger
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
  -- Transaction reference
  -- ----------------------------------------------------------

  v_reference :=
    generate_transaction_reference('WITHDRAWAL');


  -- ----------------------------------------------------------
  -- Create transaction
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
    v_business_date.business_date
  )
  returning id
  into v_transaction_id;


  -- ----------------------------------------------------------
  -- Ledger entries
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
  -- Ledger balances
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
  -- Customer account balances
  -- ----------------------------------------------------------

  update accounts
  set ledger_balance = ledger_balance - p_amount,
      available_balance = available_balance - p_amount,
      updated_at = now()
  where id = v_account.id
  returning available_balance
  into v_new_balance;


  -- ----------------------------------------------------------
  -- Response
  -- ----------------------------------------------------------

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
    'account_id', v_account.id,
    'account_number', v_account.account_number
  );

end;
$$;


-- ============================================================
-- 4. FUNCTION SECURITY
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
-- 5. COMMENTS
-- ============================================================

comment on column transactions.business_date_id is
  'Banking business date under which the transaction was posted.';

comment on column transactions.value_date is
  'Effective banking value date of the transaction.';


commit;