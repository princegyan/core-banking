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
  v_new_status account_status;
begin

  -- 1. Validate requested status
  begin
    v_new_status := p_new_status::account_status;
  exception
    when invalid_text_representation then
      raise exception 'Invalid account status';
  end;


  -- 2. Lock and load account
  select *
  into v_account
  from accounts
  where id = p_account_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Account not found';
  end if;


  -- 3. Closed accounts are terminal
  if v_account.status = 'CLOSED'::account_status then
    raise exception 'Closed account cannot be modified';
  end if;


  -- 4. No-op
  if v_account.status = v_new_status then
    return jsonb_build_object(
      'account_id', v_account.id,
      'account_number', v_account.account_number,
      'previous_status', v_account.status,
      'status', v_account.status,
      'changed', false
    );
  end if;


  -- 5. Validate status transitions
  if v_account.status = 'ACTIVE'::account_status
     and v_new_status not in (
       'FROZEN'::account_status,
       'DORMANT'::account_status,
       'CLOSED'::account_status
     ) then

    raise exception
      'Invalid status transition from ACTIVE to %',
      v_new_status;

  elsif v_account.status = 'FROZEN'::account_status
     and v_new_status not in (
       'ACTIVE'::account_status,
       'CLOSED'::account_status
     ) then

    raise exception
      'Invalid status transition from FROZEN to %',
      v_new_status;

  elsif v_account.status = 'DORMANT'::account_status
     and v_new_status not in (
       'ACTIVE'::account_status,
       'CLOSED'::account_status
     ) then

    raise exception
      'Invalid status transition from DORMANT to %',
      v_new_status;

  end if;


  -- 6. Closing requires zero balance
  if v_new_status = 'CLOSED'::account_status
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
    status = v_new_status,
    closed_at = case
      when v_new_status = 'CLOSED'::account_status
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
    'status', v_new_status,
    'changed', true,
    'closed_at',
      case
        when v_new_status = 'CLOSED'::account_status
          then now()
        else null
      end
  );

end;
$$;