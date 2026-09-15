create or replace function update_account_status(
  p_tenant_id uuid,
  p_account_id uuid,
  p_new_status varchar
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account accounts%rowtype;
begin

  -- 1. Lock and load account
  select *
  into v_account
  from accounts
  where id = p_account_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Account not found';
  end if;


  -- 2. Validate requested status
  if p_new_status not in (
    'ACTIVE',
    'FROZEN',
    'DORMANT',
    'CLOSED'
  ) then
    raise exception 'Invalid account status';
  end if;


  -- 3. Closed accounts are terminal
  if v_account.status = 'CLOSED' then
    raise exception 'Closed account cannot be modified';
  end if;


  -- 4. No-op
  if v_account.status = p_new_status then
    return jsonb_build_object(
      'account_id', v_account.id,
      'account_number', v_account.account_number,
      'previous_status', v_account.status,
      'status', v_account.status,
      'changed', false
    );
  end if;


  -- 5. Validate status transitions
  if v_account.status = 'ACTIVE'
     and p_new_status not in (
       'FROZEN',
       'DORMANT',
       'CLOSED'
     ) then

    raise exception
      'Invalid status transition from ACTIVE to %',
      p_new_status;

  elsif v_account.status = 'FROZEN'
     and p_new_status not in (
       'ACTIVE',
       'CLOSED'
     ) then

    raise exception
      'Invalid status transition from FROZEN to %',
      p_new_status;

  elsif v_account.status = 'DORMANT'
     and p_new_status not in (
       'ACTIVE',
       'CLOSED'
     ) then

    raise exception
      'Invalid status transition from DORMANT to %',
      p_new_status;

  end if;


  -- 6. Closing requires zero balance
  if p_new_status = 'CLOSED'
     and (
       v_account.ledger_balance <> 0
       or v_account.available_balance <> 0
     ) then

    raise exception
      'Account cannot be closed while balance is not zero';

  end if;


  -- 7. Update account
  update accounts
  set
    status = p_new_status,
    closed_at = case
      when p_new_status = 'CLOSED'
        then now()
      else null
    end,
    updated_at = now()
  where id = v_account.id
    and tenant_id = p_tenant_id;


  -- 8. Return result
  return jsonb_build_object(
    'account_id', v_account.id,
    'account_number', v_account.account_number,
    'previous_status', v_account.status,
    'status', p_new_status,
    'changed', true,
    'closed_at',
      case
        when p_new_status = 'CLOSED'
          then now()
        else null
      end
  );

end;
$$;