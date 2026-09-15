-- ============================================================
-- 0003_account_opening.sql
-- Atomic customer account opening
-- ============================================================

create or replace function open_customer_account(
  p_tenant_id uuid,
  p_customer_id uuid,
  p_product_id uuid,
  p_branch_id uuid,
  p_currency varchar
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_customer customers%rowtype;
  v_product account_products%rowtype;
  v_branch branches%rowtype;

  v_account_id uuid;
  v_ledger_account_id uuid;

  v_account_number varchar(50);
  v_ledger_code varchar(100);
  v_ledger_name varchar(255);
begin

  -- ----------------------------------------------------------
  -- 1. Verify customer belongs to tenant
  -- ----------------------------------------------------------

  select *
  into v_customer
  from customers
  where id = p_customer_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Customer not found';
  end if;

  if v_customer.status <> 'ACTIVE' then
    raise exception 'Customer is not active';
  end if;


  -- ----------------------------------------------------------
  -- 2. Verify account product belongs to tenant
  -- ----------------------------------------------------------

  select *
  into v_product
  from account_products
  where id = p_product_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Account product not found';
  end if;

  if not v_product.is_active then
    raise exception 'Account product is inactive';
  end if;


  -- ----------------------------------------------------------
  -- 3. Verify branch belongs to tenant
  -- ----------------------------------------------------------

  select *
  into v_branch
  from branches
  where id = p_branch_id
    and tenant_id = p_tenant_id
    and is_active = true
  for update;

  if not found then
    raise exception 'Branch not found or inactive';
  end if;


  -- ----------------------------------------------------------
  -- 4. Validate currency
  -- ----------------------------------------------------------

  if p_currency <> v_product.currency then
    raise exception
      'Currency does not match account product currency';
  end if;


  -- ----------------------------------------------------------
  -- 5. Generate account number
  -- ----------------------------------------------------------

  v_account_number :=
    nextval('customer_account_number_seq')::text;


  -- ----------------------------------------------------------
  -- 6. Generate customer ledger account code
  -- ----------------------------------------------------------

  v_ledger_code :=
    '2010-' ||
    v_customer.customer_number ||
    '-' ||
    v_account_number;


  v_ledger_name :=
    coalesce(
      nullif(
        trim(
          coalesce(v_customer.first_name, '') ||
          ' ' ||
          coalesce(v_customer.last_name, '')
        ),
        ''
      ),
      coalesce(
        v_customer.business_name,
        v_customer.customer_number
      )
    )
    || ' - ' ||
    v_product.name;


  -- ----------------------------------------------------------
  -- 7. Create customer-specific liability ledger account
  -- ----------------------------------------------------------

  insert into ledger_accounts (
    tenant_id,
    account_code,
    account_name,
    account_type,
    currency,
    is_active,
    current_balance
  )
  values (
    p_tenant_id,
    v_ledger_code,
    v_ledger_name,
    'LIABILITY',
    p_currency,
    true,
    0
  )
  returning id into v_ledger_account_id;


  -- ----------------------------------------------------------
  -- 8. Create customer bank account
  -- ----------------------------------------------------------

  insert into accounts (
    tenant_id,
    customer_id,
    product_id,
    branch_id,
    account_number,
    currency,
    status,
    ledger_balance,
    available_balance,
    opened_at,
    ledger_account_id
  )
  values (
    p_tenant_id,
    p_customer_id,
    p_product_id,
    p_branch_id,
    v_account_number,
    p_currency,
    'ACTIVE',
    0,
    0,
    now(),
    v_ledger_account_id
  )
  returning id into v_account_id;


  -- ----------------------------------------------------------
  -- 9. Return result
  -- ----------------------------------------------------------

  return jsonb_build_object(
    'account_id', v_account_id,
    'account_number', v_account_number,
    'ledger_account_id', v_ledger_account_id,
    'customer_id', p_customer_id,
    'customer_number', v_customer.customer_number,
    'product_id', p_product_id,
    'product_code', v_product.code,
    'branch_id', p_branch_id,
    'currency', p_currency,
    'status', 'ACTIVE',
    'balance', 0
  );

end;
$$;