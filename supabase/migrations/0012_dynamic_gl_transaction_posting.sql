-- ============================================================
-- CORE BANKING DYNAMIC GL TRANSACTION POSTING
-- Migration: 0012
-- ============================================================

begin;

-- ============================================================
-- 1. DEPOSIT POSTING USING PRODUCT GL MAPPING
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

      select available_balance
      into v_new_balance
      from accounts
      where id = p_account_id
        and tenant_id = p_tenant_id;

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
  -- Lock account
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
  -- Business date
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
  -- Accounting period
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
  -- Customer-specific ledger
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
  -- Resolve CASH through product GL mapping
  -- ----------------------------------------------------------

  v_cash_ledger.id :=
    get_product_gl_account(
      p_tenant_id,
      v_account.product_id,
      'CASH'
    );

  select *
  into v_cash_ledger
  from ledger_accounts
  where id = v_cash_ledger.id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Mapped cash ledger account not found';
  end if;


  -- ----------------------------------------------------------
  -- Generate reference
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
  -- Double-entry posting
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
  -- Update GL balances
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
  -- Update customer account
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
    'accounting_period', v_accounting_period.period_name,
    'accounting_period_id', v_accounting_period.id,
    'gl_mapping_type', 'CASH',
    'gl_account_id', v_cash_ledger.id,
    'gl_account_code', v_cash_ledger.account_code,
    'account_id', v_account.id,
    'account_number', v_account.account_number
  );

end;
$$;


-- ============================================================
-- 2. WITHDRAWAL POSTING USING PRODUCT GL MAPPING
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

      select available_balance
      into v_new_balance
      from accounts
      where id = p_account_id
        and tenant_id = p_tenant_id;

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
  -- Lock account
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
  -- Business date
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
  -- Accounting period
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
  -- Customer-specific ledger
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
  -- Resolve CASH through product GL mapping
  -- ----------------------------------------------------------

  v_cash_ledger.id :=
    get_product_gl_account(
      p_tenant_id,
      v_account.product_id,
      'CASH'
    );

  select *
  into v_cash_ledger
  from ledger_accounts
  where id = v_cash_ledger.id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Mapped cash ledger account not found';
  end if;


  -- ----------------------------------------------------------
  -- Generate reference
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
  -- Double-entry posting
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
  -- Update GL balances
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
  -- Update customer account
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
    'accounting_period', v_accounting_period.period_name,
    'accounting_period_id', v_accounting_period.id,
    'gl_mapping_type', 'CASH',
    'gl_account_id', v_cash_ledger.id,
    'gl_account_code', v_cash_ledger.account_code,
    'account_id', v_account.id,
    'account_number', v_account.account_number
  );

end;
$$;


-- ============================================================
-- 3. FUNCTION OWNERSHIP
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
-- 4. COMMENTS
-- ============================================================

comment on function post_deposit(
  uuid,
  uuid,
  bigint,
  text,
  varchar,
  uuid
) is
  'Posts a deposit using the customer account and product-configured CASH GL mapping.';

comment on function post_withdrawal(
  uuid,
  uuid,
  bigint,
  text,
  varchar,
  uuid
) is
  'Posts a withdrawal using the customer account and product-configured CASH GL mapping.';


commit;