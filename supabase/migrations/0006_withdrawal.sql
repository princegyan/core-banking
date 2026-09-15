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
  v_cash_ledger_id uuid;
  v_transaction_id uuid;
  v_reference varchar(100);
  v_new_balance bigint;
begin

  -- ----------------------------------------------------------
  -- 1. Validate amount
  -- ----------------------------------------------------------

  if p_amount <= 0 then
    raise exception 'Withdrawal amount must be greater than zero';
  end if;


  -- ----------------------------------------------------------
  -- 2. Check idempotency
  -- ----------------------------------------------------------

  if p_idempotency_key is not null then

    select id
    into v_transaction_id
    from transactions
    where tenant_id = p_tenant_id
      and idempotency_key = p_idempotency_key;

    if v_transaction_id is not null then

      select ledger_balance
      into v_new_balance
      from accounts
      where id = p_account_id
        and tenant_id = p_tenant_id;

      return jsonb_build_object(
        'transaction_id', v_transaction_id,
        'status', 'POSTED',
        'duplicate', true,
        'balance', v_new_balance
      );

    end if;

  end if;


  -- ----------------------------------------------------------
  -- 3. Lock and load customer account
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


  -- ----------------------------------------------------------
  -- 4. Account must be ACTIVE
  -- ----------------------------------------------------------

  if v_account.status <> 'ACTIVE'::account_status then
    raise exception 'Account is not active';
  end if;


  -- ----------------------------------------------------------
  -- 5. Account must have a ledger account
  -- ----------------------------------------------------------

  if v_account.ledger_account_id is null then
    raise exception 'Account is not linked to a ledger account';
  end if;


  -- ----------------------------------------------------------
  -- 6. Check sufficient available balance
  -- ----------------------------------------------------------

  if v_account.available_balance < p_amount then
    raise exception 'Insufficient available balance';
  end if;


  -- ----------------------------------------------------------
  -- 7. Find cash ledger account
  -- ----------------------------------------------------------

  select id
  into v_cash_ledger_id
  from ledger_accounts
  where tenant_id = p_tenant_id
    and account_code = '1010'
    and is_active = true
  for update;

  if v_cash_ledger_id is null then
    raise exception 'Cash ledger account not found';
  end if;


  -- ----------------------------------------------------------
  -- 8. Lock customer ledger account
  -- ----------------------------------------------------------

  perform 1
  from ledger_accounts
  where id = v_account.ledger_account_id
    and tenant_id = p_tenant_id
    and is_active = true
  for update;

  if not found then
    raise exception 'Customer ledger account not found';
  end if;


  -- ----------------------------------------------------------
  -- 9. Generate transaction reference
  -- ----------------------------------------------------------

  v_reference :=
    generate_transaction_reference('WITHDRAWAL');


  -- ----------------------------------------------------------
  -- 10. Create transaction
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
    created_by
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
    p_created_by
  )
  returning id
  into v_transaction_id;


  -- ----------------------------------------------------------
  -- 11. Debit customer deposit liability
  -- ----------------------------------------------------------

  insert into transaction_entries (
    transaction_id,
    tenant_id,
    ledger_account_id,
    debit,
    credit,
    description
  )
  values (
    v_transaction_id,
    p_tenant_id,
    v_account.ledger_account_id,
    p_amount,
    0,
    p_description
  );


  -- ----------------------------------------------------------
  -- 12. Credit cash
  -- ----------------------------------------------------------

  insert into transaction_entries (
    transaction_id,
    tenant_id,
    ledger_account_id,
    debit,
    credit,
    description
  )
  values (
    v_transaction_id,
    p_tenant_id,
    v_cash_ledger_id,
    0,
    p_amount,
    p_description
  );


  -- ----------------------------------------------------------
  -- 13. Update customer ledger balance
  -- ----------------------------------------------------------

  update ledger_accounts
  set
    current_balance = current_balance - p_amount,
    updated_at = now()
  where id = v_account.ledger_account_id;


  -- ----------------------------------------------------------
  -- 14. Update cash ledger balance
  -- ----------------------------------------------------------

  update ledger_accounts
  set
    current_balance = current_balance - p_amount,
    updated_at = now()
  where id = v_cash_ledger_id;


  -- ----------------------------------------------------------
  -- 15. Update customer account balances
  -- ----------------------------------------------------------

  update accounts
  set
    ledger_balance = ledger_balance - p_amount,
    available_balance = available_balance - p_amount,
    updated_at = now()
  where id = p_account_id
    and tenant_id = p_tenant_id
  returning ledger_balance
  into v_new_balance;


  -- ----------------------------------------------------------
  -- 16. Return result
  -- ----------------------------------------------------------

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'reference', v_reference,
    'status', 'POSTED',
    'amount', p_amount,
    'currency', v_account.currency,
    'account_id', p_account_id,
    'account_number', v_account.account_number,
    'balance', v_new_balance,
    'duplicate', false
  );

end;
$$;