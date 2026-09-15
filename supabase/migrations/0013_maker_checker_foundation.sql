-- ============================================================
-- CORE BANKING MAKER-CHECKER FOUNDATION
-- Migration: 0013
-- ============================================================

begin;

-- ============================================================
-- 1. HARDEN APPROVAL REQUESTS
-- ============================================================

alter table approval_requests
  add column if not exists checked_at timestamptz;

alter table approval_requests
  add column if not exists checker_comment text;


-- ============================================================
-- 2. MAKER-CHECKER VALIDATION
-- ============================================================

alter table approval_requests
  drop constraint if exists approval_requests_checker_not_maker;

alter table approval_requests
  add constraint approval_requests_checker_not_maker
  check (
    approved_by is null
    or approved_by <> requested_by
  );


alter table approval_requests
  drop constraint if exists approval_requests_checked_at_consistency;

alter table approval_requests
  add constraint approval_requests_checked_at_consistency
  check (
    (
      status in ('APPROVED', 'REJECTED', 'CANCELLED')
      and checked_at is not null
    )
    or
    status = 'PENDING'
  );


-- ============================================================
-- 3. APPROVAL REQUEST UNIQUENESS
-- ============================================================

create unique index if not exists
  uq_approval_requests_pending_entity
on approval_requests (
  tenant_id,
  entity_type,
  entity_id,
  request_type
)
where status = 'PENDING';


-- ============================================================
-- 4. APPROVAL HISTORY
-- ============================================================

create table if not exists approval_request_history (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references tenants(id)
    on delete cascade,

  approval_request_id uuid not null
    references approval_requests(id)
    on delete cascade,

  action varchar(50) not null,

  performed_by uuid not null
    references users(id)
    on delete restrict,

  comment text,

  created_at timestamptz not null default now(),

  constraint approval_request_history_action_check
    check (
      action in (
        'CREATED',
        'APPROVED',
        'REJECTED',
        'CANCELLED'
      )
    )
);

create index if not exists
  idx_approval_request_history_request
on approval_request_history(
  approval_request_id,
  created_at
);

create index if not exists
  idx_approval_request_history_tenant
on approval_request_history(
  tenant_id,
  created_at desc
);


-- ============================================================
-- 5. APPROVAL CREATION FUNCTION
-- ============================================================

create or replace function create_approval_request(
  p_tenant_id uuid,
  p_request_type varchar,
  p_entity_type varchar,
  p_entity_id uuid,
  p_requested_by uuid,
  p_comment text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request_id uuid;
begin

  if p_request_type is null
     or trim(p_request_type) = '' then
    raise exception 'Request type is required';
  end if;

  if p_entity_type is null
     or trim(p_entity_type) = '' then
    raise exception 'Entity type is required';
  end if;


  -- ----------------------------------------------------------
  -- Verify maker belongs to tenant
  -- ----------------------------------------------------------

  if not exists (
    select 1
    from users
    where id = p_requested_by
      and tenant_id = p_tenant_id
      and is_active = true
  ) then
    raise exception 'Requesting user does not belong to tenant';
  end if;


  -- ----------------------------------------------------------
  -- Prevent duplicate pending request
  -- ----------------------------------------------------------

  select id
  into v_request_id
  from approval_requests
  where tenant_id = p_tenant_id
    and request_type = p_request_type
    and entity_type = p_entity_type
    and entity_id = p_entity_id
    and status = 'PENDING'
  limit 1;

  if found then
    raise exception 'A pending approval request already exists';
  end if;


  -- ----------------------------------------------------------
  -- Create request
  -- ----------------------------------------------------------

  insert into approval_requests (
    tenant_id,
    request_type,
    entity_type,
    entity_id,
    status,
    requested_by,
    requested_at,
    created_at,
    updated_at
  )
  values (
    p_tenant_id,
    p_request_type,
    p_entity_type,
    p_entity_id,
    'PENDING',
    p_requested_by,
    now(),
    now(),
    now()
  )
  returning id
  into v_request_id;


  -- ----------------------------------------------------------
  -- Create history
  -- ----------------------------------------------------------

  insert into approval_request_history (
    tenant_id,
    approval_request_id,
    action,
    performed_by,
    comment
  )
  values (
    p_tenant_id,
    v_request_id,
    'CREATED',
    p_requested_by,
    p_comment
  );


  return v_request_id;

end;
$$;


alter function create_approval_request(
  uuid,
  varchar,
  varchar,
  uuid,
  uuid,
  text
) owner to postgres;


-- ============================================================
-- 6. APPROVE REQUEST FUNCTION
-- ============================================================

create or replace function approve_request(
  p_tenant_id uuid,
  p_request_id uuid,
  p_checker_id uuid,
  p_comment text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request approval_requests%rowtype;
begin

  -- ----------------------------------------------------------
  -- Lock request
  -- ----------------------------------------------------------

  select *
  into v_request
  from approval_requests
  where id = p_request_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Approval request not found';
  end if;


  if v_request.status <> 'PENDING' then
    raise exception 'Approval request is not pending';
  end if;


  -- ----------------------------------------------------------
  -- Verify checker
  -- ----------------------------------------------------------

  if not exists (
    select 1
    from users
    where id = p_checker_id
      and tenant_id = p_tenant_id
      and is_active = true
  ) then
    raise exception 'Checker does not belong to tenant';
  end if;


  -- ----------------------------------------------------------
  -- Maker cannot approve own request
  -- ----------------------------------------------------------

  if p_checker_id = v_request.requested_by then
    raise exception 'Maker cannot approve their own request';
  end if;


  -- ----------------------------------------------------------
  -- Approve
  -- ----------------------------------------------------------

  update approval_requests
  set status = 'APPROVED',
      approved_by = p_checker_id,
      approved_at = now(),
      checked_at = now(),
      checker_comment = p_comment,
      updated_at = now()
  where id = v_request.id;


  -- ----------------------------------------------------------
  -- History
  -- ----------------------------------------------------------

  insert into approval_request_history (
    tenant_id,
    approval_request_id,
    action,
    performed_by,
    comment
  )
  values (
    p_tenant_id,
    v_request.id,
    'APPROVED',
    p_checker_id,
    p_comment
  );


  return jsonb_build_object(
    'approval_request_id', v_request.id,
    'status', 'APPROVED',
    'requested_by', v_request.requested_by,
    'approved_by', p_checker_id,
    'approved_at', now()
  );

end;
$$;


alter function approve_request(
  uuid,
  uuid,
  uuid,
  text
) owner to postgres;


-- ============================================================
-- 7. REJECT REQUEST FUNCTION
-- ============================================================

create or replace function reject_request(
  p_tenant_id uuid,
  p_request_id uuid,
  p_checker_id uuid,
  p_comment text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request approval_requests%rowtype;
begin

  if p_comment is null
     or trim(p_comment) = '' then
    raise exception 'Rejection comment is required';
  end if;


  -- ----------------------------------------------------------
  -- Lock request
  -- ----------------------------------------------------------

  select *
  into v_request
  from approval_requests
  where id = p_request_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Approval request not found';
  end if;


  if v_request.status <> 'PENDING' then
    raise exception 'Approval request is not pending';
  end if;


  -- ----------------------------------------------------------
  -- Verify checker
  -- ----------------------------------------------------------

  if not exists (
    select 1
    from users
    where id = p_checker_id
      and tenant_id = p_tenant_id
      and is_active = true
  ) then
    raise exception 'Checker does not belong to tenant';
  end if;


  -- ----------------------------------------------------------
  -- Maker cannot reject own request
  -- ----------------------------------------------------------

  if p_checker_id = v_request.requested_by then
    raise exception 'Maker cannot reject their own request';
  end if;


  -- ----------------------------------------------------------
  -- Reject
  -- ----------------------------------------------------------

  update approval_requests
  set status = 'REJECTED',
      approved_by = null,
      approved_at = null,
      rejected_at = now(),
      checked_at = now(),
      checker_comment = p_comment,
      rejection_reason = p_comment,
      updated_at = now()
  where id = v_request.id;


  -- ----------------------------------------------------------
  -- History
  -- ----------------------------------------------------------

  insert into approval_request_history (
    tenant_id,
    approval_request_id,
    action,
    performed_by,
    comment
  )
  values (
    p_tenant_id,
    v_request.id,
    'REJECTED',
    p_checker_id,
    p_comment
  );


  return jsonb_build_object(
    'approval_request_id', v_request.id,
    'status', 'REJECTED',
    'requested_by', v_request.requested_by,
    'rejected_by', p_checker_id,
    'rejected_at', now(),
    'reason', p_comment
  );

end;
$$;


alter function reject_request(
  uuid,
  uuid,
  uuid,
  text
) owner to postgres;


-- ============================================================
-- 8. CANCEL REQUEST FUNCTION
-- ============================================================

create or replace function cancel_approval_request(
  p_tenant_id uuid,
  p_request_id uuid,
  p_user_id uuid,
  p_comment text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request approval_requests%rowtype;
begin

  select *
  into v_request
  from approval_requests
  where id = p_request_id
    and tenant_id = p_tenant_id
  for update;

  if not found then
    raise exception 'Approval request not found';
  end if;


  if v_request.status <> 'PENDING' then
    raise exception 'Approval request is not pending';
  end if;


  if v_request.requested_by <> p_user_id then
    raise exception 'Only the maker can cancel this request';
  end if;


  update approval_requests
  set status = 'CANCELLED',
      checked_at = now(),
      checker_comment = p_comment,
      updated_at = now()
  where id = v_request.id;


  insert into approval_request_history (
    tenant_id,
    approval_request_id,
    action,
    performed_by,
    comment
  )
  values (
    p_tenant_id,
    v_request.id,
    'CANCELLED',
    p_user_id,
    p_comment
  );


  return jsonb_build_object(
    'approval_request_id', v_request.id,
    'status', 'CANCELLED',
    'cancelled_by', p_user_id,
    'cancelled_at', now()
  );

end;
$$;


alter function cancel_approval_request(
  uuid,
  uuid,
  uuid,
  text
) owner to postgres;


-- ============================================================
-- 9. COMMENTS
-- ============================================================

comment on table approval_requests is
  'Maker-checker approval requests for controlled banking operations.';

comment on table approval_request_history is
  'Historical record of maker-checker approval actions.';


commit;