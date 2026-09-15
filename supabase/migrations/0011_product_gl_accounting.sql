-- ============================================================
-- CORE BANKING PRODUCT GL ACCOUNTING
-- Migration: 0011
-- ============================================================

begin;

-- ============================================================
-- 1. ADD MAPPING TYPE
-- ============================================================

alter table product_gl_mappings
  add column if not exists mapping_type varchar(50);


-- ============================================================
-- 2. VALIDATE MAPPING TYPE
-- ============================================================

alter table product_gl_mappings
  drop constraint if exists product_gl_mappings_mapping_type_check;

alter table product_gl_mappings
  add constraint product_gl_mappings_mapping_type_check
  check (
    mapping_type in (
      'CUSTOMER_DEPOSIT',
      'CASH',
      'BANK',
      'MOBILE_MONEY',
      'INTEREST_INCOME',
      'INTEREST_EXPENSE',
      'FEE_INCOME',
      'OTHER'
    )
  );


-- ============================================================
-- 3. MAPPING TYPE IS REQUIRED
-- ============================================================

alter table product_gl_mappings
  alter column mapping_type set not null;


-- ============================================================
-- 4. ONE ACTIVE MAPPING PER PRODUCT / TYPE
-- ============================================================

create unique index if not exists
  uq_product_gl_mappings_active_type
on product_gl_mappings (
  tenant_id,
  product_id,
  mapping_type
)
where is_active = true;


-- ============================================================
-- 5. TENANT CONSISTENCY VALIDATION
-- ============================================================

create or replace function validate_product_gl_mapping_tenant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_product_tenant uuid;
  v_ledger_tenant uuid;
begin

  select tenant_id
  into v_product_tenant
  from account_products
  where id = new.product_id;

  if v_product_tenant is null then
    raise exception 'Account product not found';
  end if;

  if v_product_tenant <> new.tenant_id then
    raise exception 'Product and GL mapping must belong to the same tenant';
  end if;


  select tenant_id
  into v_ledger_tenant
  from ledger_accounts
  where id = new.ledger_account_id;

  if v_ledger_tenant is null then
    raise exception 'Ledger account not found';
  end if;

  if v_ledger_tenant <> new.tenant_id then
    raise exception 'Ledger account and GL mapping must belong to the same tenant';
  end if;


  return new;
end;
$$;


drop trigger if exists trg_validate_product_gl_mapping_tenant
  on product_gl_mappings;

create trigger trg_validate_product_gl_mapping_tenant
before insert or update
on product_gl_mappings
for each row
execute function validate_product_gl_mapping_tenant();


-- ============================================================
-- 6. SEED SAVINGS PRODUCT GL MAPPINGS
-- ============================================================

insert into product_gl_mappings (
  tenant_id,
  product_id,
  mapping_code,
  mapping_type,
  ledger_account_id,
  is_active
)
select
  ap.tenant_id,
  ap.id,
  'CUSTOMER_DEPOSIT',
  'CUSTOMER_DEPOSIT',
  la.id,
  true
from account_products ap
join ledger_accounts la
  on la.tenant_id = ap.tenant_id
 and la.account_code = '2010'
where ap.tenant_id =
  '669d95bb-167c-483d-b652-898bb1e78ac7'
  and ap.code = 'SAVINGS'
on conflict (
  tenant_id,
  product_id,
  mapping_code
)
do update
set mapping_type = excluded.mapping_type,
    ledger_account_id = excluded.ledger_account_id,
    is_active = true,
    updated_at = now();


insert into product_gl_mappings (
  tenant_id,
  product_id,
  mapping_code,
  mapping_type,
  ledger_account_id,
  is_active
)
select
  ap.tenant_id,
  ap.id,
  'CASH',
  'CASH',
  la.id,
  true
from account_products ap
join ledger_accounts la
  on la.tenant_id = ap.tenant_id
 and la.account_code = '1010'
where ap.tenant_id =
  '669d95bb-167c-483d-b652-898bb1e78ac7'
  and ap.code = 'SAVINGS'
on conflict (
  tenant_id,
  product_id,
  mapping_code
)
do update
set mapping_type = excluded.mapping_type,
    ledger_account_id = excluded.ledger_account_id,
    is_active = true,
    updated_at = now();


-- ============================================================
-- 7. HELPER FUNCTION FOR GL RESOLUTION
-- ============================================================

create or replace function get_product_gl_account(
  p_tenant_id uuid,
  p_product_id uuid,
  p_mapping_type varchar
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ledger_account_id uuid;
begin

  select ledger_account_id
  into v_ledger_account_id
  from product_gl_mappings
  where tenant_id = p_tenant_id
    and product_id = p_product_id
    and mapping_type = p_mapping_type
    and is_active = true
  order by created_at desc
  limit 1;

  if v_ledger_account_id is null then
    raise exception
      'No active GL mapping found for product and mapping type';
  end if;

  return v_ledger_account_id;

end;
$$;


alter function get_product_gl_account(
  uuid,
  uuid,
  varchar
) owner to postgres;


-- ============================================================
-- 8. FUNCTION FOR CUSTOMER-SPECIFIC LEDGER ACCOUNTS
-- ============================================================

create or replace function get_customer_product_gl_account(
  p_tenant_id uuid,
  p_account_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ledger_account_id uuid;
begin

  select a.ledger_account_id
  into v_ledger_account_id
  from accounts a
  where a.id = p_account_id
    and a.tenant_id = p_tenant_id;

  if v_ledger_account_id is null then
    raise exception 'Customer account ledger not found';
  end if;

  return v_ledger_account_id;

end;
$$;


alter function get_customer_product_gl_account(
  uuid,
  uuid
) owner to postgres;


-- ============================================================
-- 9. COMMENTS
-- ============================================================

comment on table product_gl_mappings is
  'Maps banking products to accounting/control GL accounts by accounting purpose.';

comment on column product_gl_mappings.mapping_type is
  'Accounting purpose represented by the mapped GL account.';


commit;