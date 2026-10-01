-- ============================================================
-- LOAN PRODUCTS & CONFIGURATION
-- Migration: 0047
-- Milestone: 17.1
--
-- Establishes the foundation for the Loan Management module:
--   1. Loan product type enums
--   2. Loan products table
--   3. Loan product charges (bridge to fees)
--   4. Loan product GL mappings
--   5. CRUD functions
--   6. Validation & triggers
-- ============================================================

begin;


-- ============================================================
-- 1. ENUMS
-- ============================================================

create type loan_product_type as enum (
    'TERM_LOAN',
    'OVERDRAFT',
    'LINE_OF_CREDIT',
    'GROUP_LOAN',
    'SALARY_ADVANCE'
);

create type loan_interest_method as enum (
    'FLAT',
    'DECLINING_BALANCE'
);

create type loan_interest_calculation_basis as enum (
    'ACTUAL_365',
    'ACTUAL_360',
    'THIRTY_360'
);

create type loan_repayment_frequency as enum (
    'DAILY',
    'WEEKLY',
    'BIWEEKLY',
    'MONTHLY',
    'QUARTERLY',
    'SEMI_ANNUALLY',
    'ANNUALLY'
);

create type loan_amortization_type as enum (
    'EQUAL_INSTALLMENTS',
    'EQUAL_PRINCIPAL',
    'BULLET',
    'BALLOON'
);


-- ============================================================
-- 2. LOAN PRODUCTS TABLE
-- ============================================================

create table loan_products (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete restrict,

    -- -------------------------------------------------------
    -- Identity
    -- -------------------------------------------------------

    code varchar(50) not null,
    name varchar(150) not null,
    description text,

    product_type loan_product_type not null,

    currency char(3) not null default 'GHS',

    -- -------------------------------------------------------
    -- Principal limits (minor units)
    -- -------------------------------------------------------

    minimum_principal bigint not null default 0,
    maximum_principal bigint not null default 0,
    default_principal bigint null,

    -- -------------------------------------------------------
    -- Interest configuration
    -- -------------------------------------------------------

    -- Annual interest rate stored as basis points
    -- 100 = 1%, 250 = 2.5%, 10000 = 100%
    annual_interest_rate integer not null default 0,

    interest_method loan_interest_method not null
        default 'DECLINING_BALANCE',

    interest_calculation_basis loan_interest_calculation_basis not null
        default 'ACTUAL_365',

    -- -------------------------------------------------------
    -- Term configuration (in calendar days)
    -- -------------------------------------------------------

    minimum_term_days integer not null default 30,
    maximum_term_days integer not null default 365,
    default_term_days integer null,

    -- -------------------------------------------------------
    -- Repayment configuration
    -- -------------------------------------------------------

    repayment_frequency loan_repayment_frequency not null
        default 'MONTHLY',

    amortization_type loan_amortization_type not null
        default 'EQUAL_INSTALLMENTS',

    -- For BALLOON: percentage of principal due at maturity
    -- stored as basis points (5000 = 50%)
    balloon_percentage integer null,

    -- -------------------------------------------------------
    -- Grace period
    -- -------------------------------------------------------

    -- Days before first repayment is due
    grace_period_days integer not null default 0,

    -- Whether interest accrues during grace period
    grace_period_interest boolean not null default true,

    -- -------------------------------------------------------
    -- Penalty / delinquency
    -- -------------------------------------------------------

    -- Penalty rate on overdue amount in basis points
    -- (annual rate, e.g. 500 = 5%)
    penalty_rate integer not null default 0,

    -- Days after due date before penalty applies
    penalty_grace_days integer not null default 0,

    -- Days past due thresholds for arrears classification
    arrears_days_threshold_1 integer not null default 30,
    arrears_days_threshold_2 integer not null default 60,
    arrears_days_threshold_3 integer not null default 90,

    -- -------------------------------------------------------
    -- Collateral
    -- -------------------------------------------------------

    requires_collateral boolean not null default false,

    -- Minimum collateral coverage ratio in basis points
    -- 10000 = 100%, 15000 = 150%
    minimum_collateral_ratio integer null,

    -- -------------------------------------------------------
    -- Guarantors
    -- -------------------------------------------------------

    requires_guarantor boolean not null default false,
    minimum_guarantors integer not null default 0,

    -- -------------------------------------------------------
    -- Prepayment
    -- -------------------------------------------------------

    allow_prepayment boolean not null default true,

    -- Prepayment penalty in basis points on prepaid amount
    prepayment_penalty_rate integer not null default 0,

    -- -------------------------------------------------------
    -- Status & audit
    -- -------------------------------------------------------

    is_active boolean not null default true,

    created_by uuid null
        references users(id)
        on delete set null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    -- -------------------------------------------------------
    -- Constraints
    -- -------------------------------------------------------

    constraint loan_products_code_unique
        unique (tenant_id, code),

    constraint loan_products_minimum_principal_nonneg
        check (minimum_principal >= 0),

    constraint loan_products_maximum_principal_nonneg
        check (maximum_principal >= 0),

    constraint loan_products_principal_range_valid
        check (
            maximum_principal = 0
            or minimum_principal <= maximum_principal
        ),

    constraint loan_products_default_principal_valid
        check (
            default_principal is null
            or (
                default_principal >= minimum_principal
                and (
                    maximum_principal = 0
                    or default_principal <= maximum_principal
                )
            )
        ),

    constraint loan_products_interest_rate_nonneg
        check (annual_interest_rate >= 0),

    constraint loan_products_minimum_term_positive
        check (minimum_term_days > 0),

    constraint loan_products_maximum_term_positive
        check (maximum_term_days > 0),

    constraint loan_products_term_range_valid
        check (minimum_term_days <= maximum_term_days),

    constraint loan_products_default_term_valid
        check (
            default_term_days is null
            or (
                default_term_days >= minimum_term_days
                and default_term_days <= maximum_term_days
            )
        ),

    constraint loan_products_grace_period_nonneg
        check (grace_period_days >= 0),

    constraint loan_products_penalty_rate_nonneg
        check (penalty_rate >= 0),

    constraint loan_products_penalty_grace_nonneg
        check (penalty_grace_days >= 0),

    constraint loan_products_arrears_thresholds_ascending
        check (
            arrears_days_threshold_1 > 0
            and arrears_days_threshold_2 > arrears_days_threshold_1
            and arrears_days_threshold_3 > arrears_days_threshold_2
        ),

    constraint loan_products_collateral_ratio_valid
        check (
            not requires_collateral
            or (
                minimum_collateral_ratio is not null
                and minimum_collateral_ratio > 0
            )
        ),

    constraint loan_products_guarantor_count_valid
        check (
            not requires_guarantor
            or minimum_guarantors > 0
        ),

    constraint loan_products_prepayment_penalty_nonneg
        check (prepayment_penalty_rate >= 0),

    constraint loan_products_balloon_valid
        check (
            amortization_type <> 'BALLOON'
            or (
                balloon_percentage is not null
                and balloon_percentage > 0
                and balloon_percentage <= 10000
            )
        )
);


-- ============================================================
-- 3. INDEXES
-- ============================================================

create index idx_loan_products_tenant
    on loan_products(tenant_id);

create index idx_loan_products_type
    on loan_products(tenant_id, product_type);

create index idx_loan_products_active
    on loan_products(tenant_id, is_active);

create index idx_loan_products_currency
    on loan_products(tenant_id, currency);


-- ============================================================
-- 4. UPDATED_AT TRIGGER
-- ============================================================

create trigger loan_products_updated_at
before update on loan_products
for each row
execute function update_updated_at();


-- ============================================================
-- 5. LOAN PRODUCT CHARGES (bridge to fees table)
-- ============================================================

create table loan_product_charges (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete cascade,

    loan_product_id uuid not null
        references loan_products(id)
        on delete cascade,

    fee_id uuid not null
        references fees(id)
        on delete restrict,

    -- When the charge applies
    charge_event varchar(50) not null,

    is_mandatory boolean not null default true,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint loan_product_charges_event_check
        check (
            charge_event in (
                'DISBURSEMENT',
                'REPAYMENT',
                'LATE_PAYMENT',
                'PREPAYMENT',
                'RESTRUCTURE',
                'INSURANCE',
                'APPLICATION'
            )
        ),

    constraint loan_product_charges_unique_fee
        unique (tenant_id, loan_product_id, fee_id, charge_event)
);

create index idx_loan_product_charges_product
    on loan_product_charges(tenant_id, loan_product_id);

create index idx_loan_product_charges_fee
    on loan_product_charges(fee_id);

create trigger loan_product_charges_updated_at
before update on loan_product_charges
for each row
execute function update_updated_at();


-- ============================================================
-- 6. LOAN PRODUCT GL MAPPINGS
-- ============================================================

create table loan_product_gl_mappings (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references tenants(id)
        on delete cascade,

    loan_product_id uuid not null
        references loan_products(id)
        on delete cascade,

    mapping_type varchar(50) not null,

    ledger_account_id uuid not null
        references ledger_accounts(id)
        on delete restrict,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint loan_product_gl_mapping_type_check
        check (
            mapping_type in (
                'LOAN_PORTFOLIO',
                'INTEREST_RECEIVABLE',
                'INTEREST_INCOME',
                'PENALTY_INCOME',
                'FUND_SOURCE',
                'PROVISION_EXPENSE',
                'WRITE_OFF',
                'SUSPENSE'
            )
        )
);

create unique index uq_loan_product_gl_active_type
    on loan_product_gl_mappings (
        tenant_id,
        loan_product_id,
        mapping_type
    )
    where is_active = true;

create index idx_loan_product_gl_product
    on loan_product_gl_mappings(tenant_id, loan_product_id);

create trigger loan_product_gl_mappings_updated_at
before update on loan_product_gl_mappings
for each row
execute function update_updated_at();


-- ============================================================
-- 7. TENANT CONSISTENCY VALIDATION
-- ============================================================

create or replace function validate_loan_product_gl_tenant()
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
    from loan_products
    where id = new.loan_product_id;

    if v_product_tenant is null then
        raise exception 'Loan product not found';
    end if;

    if v_product_tenant <> new.tenant_id then
        raise exception
            'Loan product and GL mapping must belong to the same tenant';
    end if;


    select tenant_id
    into v_ledger_tenant
    from ledger_accounts
    where id = new.ledger_account_id;

    if v_ledger_tenant is null then
        raise exception 'Ledger account not found';
    end if;

    if v_ledger_tenant <> new.tenant_id then
        raise exception
            'Ledger account and GL mapping must belong to the same tenant';
    end if;


    return new;
end;
$$;

drop trigger if exists trg_validate_loan_product_gl_tenant
    on loan_product_gl_mappings;

create trigger trg_validate_loan_product_gl_tenant
before insert or update
on loan_product_gl_mappings
for each row
execute function validate_loan_product_gl_tenant();


-- ============================================================
-- 8. LOAN PRODUCT CHARGE TENANT VALIDATION
-- ============================================================

create or replace function validate_loan_product_charge_tenant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_product_tenant uuid;
    v_fee_tenant uuid;
begin

    select tenant_id
    into v_product_tenant
    from loan_products
    where id = new.loan_product_id;

    if v_product_tenant is null then
        raise exception 'Loan product not found';
    end if;

    if v_product_tenant <> new.tenant_id then
        raise exception
            'Loan product and charge must belong to the same tenant';
    end if;


    select tenant_id
    into v_fee_tenant
    from fees
    where id = new.fee_id;

    if v_fee_tenant is null then
        raise exception 'Fee not found';
    end if;

    if v_fee_tenant <> new.tenant_id then
        raise exception
            'Fee and loan product charge must belong to the same tenant';
    end if;


    return new;
end;
$$;

drop trigger if exists trg_validate_loan_product_charge_tenant
    on loan_product_charges;

create trigger trg_validate_loan_product_charge_tenant
before insert or update
on loan_product_charges
for each row
execute function validate_loan_product_charge_tenant();


-- ============================================================
-- 9. CREATE LOAN PRODUCT FUNCTION
-- ============================================================

create or replace function create_loan_product(
    p_tenant_id uuid,
    p_code varchar,
    p_name varchar,
    p_description text,
    p_product_type varchar,
    p_currency varchar,
    p_minimum_principal bigint,
    p_maximum_principal bigint,
    p_annual_interest_rate integer,
    p_interest_method varchar,
    p_interest_calculation_basis varchar,
    p_minimum_term_days integer,
    p_maximum_term_days integer,
    p_repayment_frequency varchar,
    p_amortization_type varchar,
    p_grace_period_days integer default 0,
    p_grace_period_interest boolean default true,
    p_penalty_rate integer default 0,
    p_penalty_grace_days integer default 0,
    p_requires_collateral boolean default false,
    p_minimum_collateral_ratio integer default null,
    p_requires_guarantor boolean default false,
    p_minimum_guarantors integer default 0,
    p_allow_prepayment boolean default true,
    p_prepayment_penalty_rate integer default 0,
    p_default_principal bigint default null,
    p_default_term_days integer default null,
    p_balloon_percentage integer default null,
    p_created_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_product_id uuid;
begin

    -- ----------------------------------------------------------
    -- Verify tenant exists and is active
    -- ----------------------------------------------------------

    if not exists (
        select 1
        from tenants
        where id = p_tenant_id
          and status = 'ACTIVE'
    ) then
        raise exception 'Tenant not found or not active';
    end if;


    -- ----------------------------------------------------------
    -- Verify code uniqueness within tenant
    -- ----------------------------------------------------------

    if exists (
        select 1
        from loan_products
        where tenant_id = p_tenant_id
          and code = p_code
    ) then
        raise exception
            'Loan product code already exists for this tenant';
    end if;


    -- ----------------------------------------------------------
    -- Verify creator belongs to tenant
    -- ----------------------------------------------------------

    if p_created_by is not null then
        if not exists (
            select 1
            from users
            where id = p_created_by
              and tenant_id = p_tenant_id
              and is_active = true
        ) then
            raise exception
                'Creating user does not belong to tenant';
        end if;
    end if;


    -- ----------------------------------------------------------
    -- Insert loan product
    -- ----------------------------------------------------------

    insert into loan_products (
        tenant_id,
        code,
        name,
        description,
        product_type,
        currency,
        minimum_principal,
        maximum_principal,
        default_principal,
        annual_interest_rate,
        interest_method,
        interest_calculation_basis,
        minimum_term_days,
        maximum_term_days,
        default_term_days,
        repayment_frequency,
        amortization_type,
        balloon_percentage,
        grace_period_days,
        grace_period_interest,
        penalty_rate,
        penalty_grace_days,
        requires_collateral,
        minimum_collateral_ratio,
        requires_guarantor,
        minimum_guarantors,
        allow_prepayment,
        prepayment_penalty_rate,
        created_by
    )
    values (
        p_tenant_id,
        p_code,
        p_name,
        p_description,
        p_product_type::loan_product_type,
        p_currency,
        p_minimum_principal,
        p_maximum_principal,
        p_default_principal,
        p_annual_interest_rate,
        p_interest_method::loan_interest_method,
        p_interest_calculation_basis::loan_interest_calculation_basis,
        p_minimum_term_days,
        p_maximum_term_days,
        p_default_term_days,
        p_repayment_frequency::loan_repayment_frequency,
        p_amortization_type::loan_amortization_type,
        p_balloon_percentage,
        p_grace_period_days,
        p_grace_period_interest,
        p_penalty_rate,
        p_penalty_grace_days,
        p_requires_collateral,
        p_minimum_collateral_ratio,
        p_requires_guarantor,
        p_minimum_guarantors,
        p_allow_prepayment,
        p_prepayment_penalty_rate,
        p_created_by
    )
    returning id into v_product_id;


    return jsonb_build_object(
        'loan_product_id', v_product_id,
        'code', p_code,
        'name', p_name,
        'product_type', p_product_type,
        'currency', p_currency,
        'annual_interest_rate', p_annual_interest_rate,
        'interest_method', p_interest_method,
        'repayment_frequency', p_repayment_frequency,
        'is_active', true
    );

end;
$$;

alter function create_loan_product(
    uuid, varchar, varchar, text, varchar, varchar,
    bigint, bigint, integer, varchar, varchar,
    integer, integer, varchar, varchar,
    integer, boolean, integer, integer,
    boolean, integer, boolean, integer,
    boolean, integer, bigint, integer, integer, uuid
) owner to postgres;


-- ============================================================
-- 10. UPDATE LOAN PRODUCT FUNCTION
-- ============================================================

create or replace function update_loan_product(
    p_tenant_id uuid,
    p_product_id uuid,
    p_name varchar default null,
    p_description text default null,
    p_minimum_principal bigint default null,
    p_maximum_principal bigint default null,
    p_annual_interest_rate integer default null,
    p_minimum_term_days integer default null,
    p_maximum_term_days integer default null,
    p_grace_period_days integer default null,
    p_grace_period_interest boolean default null,
    p_penalty_rate integer default null,
    p_penalty_grace_days integer default null,
    p_requires_collateral boolean default null,
    p_minimum_collateral_ratio integer default null,
    p_requires_guarantor boolean default null,
    p_minimum_guarantors integer default null,
    p_allow_prepayment boolean default null,
    p_prepayment_penalty_rate integer default null,
    p_is_active boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_product loan_products%rowtype;
    v_has_active_loans boolean;
begin

    -- ----------------------------------------------------------
    -- Lock product
    -- ----------------------------------------------------------

    select *
    into v_product
    from loan_products
    where id = p_product_id
      and tenant_id = p_tenant_id
    for update;

    if not found then
        raise exception 'Loan product not found';
    end if;


    -- ----------------------------------------------------------
    -- Prevent structural changes if product has active loans
    -- (core fields like interest method, amortization, frequency
    --  are immutable once loans exist — those are not parameters)
    -- ----------------------------------------------------------

    select exists (
        select 1
        from loan_applications la
        where la.loan_product_id = p_product_id
          and la.tenant_id = p_tenant_id
          and la.status not in ('REJECTED', 'CANCELLED', 'WITHDRAWN')
    ) into v_has_active_loans;

    -- Allow v_has_active_loans check to fail gracefully
    -- if loan_applications table does not yet exist
    if v_has_active_loans is null then
        v_has_active_loans := false;
    end if;


    -- ----------------------------------------------------------
    -- Apply updates (only non-null parameters)
    -- ----------------------------------------------------------

    update loan_products
    set
        name = coalesce(p_name, name),
        description = coalesce(p_description, description),
        minimum_principal = coalesce(p_minimum_principal, minimum_principal),
        maximum_principal = coalesce(p_maximum_principal, maximum_principal),
        annual_interest_rate = coalesce(p_annual_interest_rate, annual_interest_rate),
        minimum_term_days = coalesce(p_minimum_term_days, minimum_term_days),
        maximum_term_days = coalesce(p_maximum_term_days, maximum_term_days),
        grace_period_days = coalesce(p_grace_period_days, grace_period_days),
        grace_period_interest = coalesce(p_grace_period_interest, grace_period_interest),
        penalty_rate = coalesce(p_penalty_rate, penalty_rate),
        penalty_grace_days = coalesce(p_penalty_grace_days, penalty_grace_days),
        requires_collateral = coalesce(p_requires_collateral, requires_collateral),
        minimum_collateral_ratio = coalesce(p_minimum_collateral_ratio, minimum_collateral_ratio),
        requires_guarantor = coalesce(p_requires_guarantor, requires_guarantor),
        minimum_guarantors = coalesce(p_minimum_guarantors, minimum_guarantors),
        allow_prepayment = coalesce(p_allow_prepayment, allow_prepayment),
        prepayment_penalty_rate = coalesce(p_prepayment_penalty_rate, prepayment_penalty_rate),
        is_active = coalesce(p_is_active, is_active)
    where id = p_product_id;


    return jsonb_build_object(
        'loan_product_id', p_product_id,
        'updated', true
    );

end;
$$;

alter function update_loan_product(
    uuid, uuid,
    varchar, text,
    bigint, bigint, integer,
    integer, integer,
    integer, boolean, integer, integer,
    boolean, integer, boolean, integer,
    boolean, integer, boolean
) owner to postgres;


-- ============================================================
-- 11. GL MAPPING HELPER FUNCTION
-- ============================================================

create or replace function get_loan_product_gl_account(
    p_tenant_id uuid,
    p_loan_product_id uuid,
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
    from loan_product_gl_mappings
    where tenant_id = p_tenant_id
      and loan_product_id = p_loan_product_id
      and mapping_type = p_mapping_type
      and is_active = true
    order by created_at desc
    limit 1;

    if v_ledger_account_id is null then
        raise exception
            'No active GL mapping found for loan product (%) and mapping type (%)',
            p_loan_product_id, p_mapping_type;
    end if;

    return v_ledger_account_id;

end;
$$;

alter function get_loan_product_gl_account(
    uuid, uuid, varchar
) owner to postgres;


-- ============================================================
-- 12. ADD LOAN PRODUCT GL MAPPING FUNCTION
-- ============================================================

create or replace function add_loan_product_gl_mapping(
    p_tenant_id uuid,
    p_loan_product_id uuid,
    p_mapping_type varchar,
    p_ledger_account_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_mapping_id uuid;
begin

    -- Validate loan product
    if not exists (
        select 1
        from loan_products
        where id = p_loan_product_id
          and tenant_id = p_tenant_id
    ) then
        raise exception 'Loan product not found';
    end if;

    -- Validate ledger account
    if not exists (
        select 1
        from ledger_accounts
        where id = p_ledger_account_id
          and tenant_id = p_tenant_id
          and is_active = true
    ) then
        raise exception 'Ledger account not found or inactive';
    end if;

    -- Validate mapping type
    if p_mapping_type not in (
        'LOAN_PORTFOLIO',
        'INTEREST_RECEIVABLE',
        'INTEREST_INCOME',
        'PENALTY_INCOME',
        'FUND_SOURCE',
        'PROVISION_EXPENSE',
        'WRITE_OFF',
        'SUSPENSE'
    ) then
        raise exception 'Invalid GL mapping type: %', p_mapping_type;
    end if;

    -- Deactivate existing mapping of same type
    update loan_product_gl_mappings
    set is_active = false,
        updated_at = now()
    where tenant_id = p_tenant_id
      and loan_product_id = p_loan_product_id
      and mapping_type = p_mapping_type
      and is_active = true;

    -- Create new mapping
    insert into loan_product_gl_mappings (
        tenant_id,
        loan_product_id,
        mapping_type,
        ledger_account_id,
        is_active
    )
    values (
        p_tenant_id,
        p_loan_product_id,
        p_mapping_type,
        p_ledger_account_id,
        true
    )
    returning id into v_mapping_id;

    return jsonb_build_object(
        'mapping_id', v_mapping_id,
        'loan_product_id', p_loan_product_id,
        'mapping_type', p_mapping_type,
        'ledger_account_id', p_ledger_account_id
    );

end;
$$;

alter function add_loan_product_gl_mapping(
    uuid, uuid, varchar, uuid
) owner to postgres;


-- ============================================================
-- 13. ADD LOAN PRODUCT CHARGE FUNCTION
-- ============================================================

create or replace function add_loan_product_charge(
    p_tenant_id uuid,
    p_loan_product_id uuid,
    p_fee_id uuid,
    p_charge_event varchar,
    p_is_mandatory boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_charge_id uuid;
begin

    -- Validate loan product
    if not exists (
        select 1
        from loan_products
        where id = p_loan_product_id
          and tenant_id = p_tenant_id
    ) then
        raise exception 'Loan product not found';
    end if;

    -- Validate fee
    if not exists (
        select 1
        from fees
        where id = p_fee_id
          and tenant_id = p_tenant_id
          and is_active = true
    ) then
        raise exception 'Fee not found or inactive';
    end if;

    -- Validate charge event
    if p_charge_event not in (
        'DISBURSEMENT',
        'REPAYMENT',
        'LATE_PAYMENT',
        'PREPAYMENT',
        'RESTRUCTURE',
        'INSURANCE',
        'APPLICATION'
    ) then
        raise exception 'Invalid charge event: %', p_charge_event;
    end if;

    -- Insert charge
    insert into loan_product_charges (
        tenant_id,
        loan_product_id,
        fee_id,
        charge_event,
        is_mandatory,
        is_active
    )
    values (
        p_tenant_id,
        p_loan_product_id,
        p_fee_id,
        p_charge_event,
        p_is_mandatory,
        true
    )
    returning id into v_charge_id;

    return jsonb_build_object(
        'charge_id', v_charge_id,
        'loan_product_id', p_loan_product_id,
        'fee_id', p_fee_id,
        'charge_event', p_charge_event
    );

end;
$$;

alter function add_loan_product_charge(
    uuid, uuid, uuid, varchar, boolean
) owner to postgres;


-- ============================================================
-- 14. COMMENTS
-- ============================================================

comment on table loan_products is
    'Loan product configuration defining terms, interest, repayment, and risk parameters.';

comment on column loan_products.annual_interest_rate is
    'Annual interest rate in basis points (100 = 1%).';

comment on column loan_products.minimum_principal is
    'Minimum loan principal in minor currency units.';

comment on column loan_products.maximum_principal is
    'Maximum loan principal in minor currency units (0 = unlimited).';

comment on column loan_products.penalty_rate is
    'Annual penalty rate on overdue amounts in basis points.';

comment on column loan_products.minimum_collateral_ratio is
    'Minimum collateral coverage as basis points of loan principal (10000 = 100%).';

comment on column loan_products.balloon_percentage is
    'For BALLOON amortization: percentage of principal due at maturity in basis points.';

comment on table loan_product_charges is
    'Links fee/charge configurations to loan products with event-based triggers.';

comment on table loan_product_gl_mappings is
    'Maps loan products to GL accounts for loan-specific accounting entries.';


commit;
