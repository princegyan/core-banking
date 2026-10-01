-- ============================================================
-- KYC Advanced Features
-- ============================================================

begin;

-- ----------------------------------------------------------
-- Tables
-- ----------------------------------------------------------

create table kyc_documents (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete restrict,
    customer_id uuid not null references customers(id) on delete restrict,
    document_type varchar not null check (document_type in ('NATIONAL_ID', 'PASSPORT', 'DRIVERS_LICENSE', 'VOTERS_ID', 'UTILITY_BILL', 'BANK_STATEMENT', 'TAX_CERTIFICATE', 'COMPANY_REGISTRATION', 'OTHER')),
    document_number varchar(100),
    file_path text,
    file_name varchar(255),
    file_mime_type varchar(100),
    file_size_bytes bigint,
    issue_date date,
    expiry_date date,
    issuing_authority varchar(200),
    status varchar not null default 'PENDING' check (status in ('PENDING', 'VERIFIED', 'REJECTED', 'EXPIRED')),
    verified_by uuid references users(id) on delete restrict,
    verified_at timestamptz,
    rejection_reason text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_kyc_documents_tenant_customer on kyc_documents(tenant_id, customer_id);
create index idx_kyc_documents_tenant_expiry on kyc_documents(tenant_id, expiry_date);

create trigger update_kyc_documents_updated_at
    before update on kyc_documents
    for each row
    execute function update_updated_at();

create table customer_risk_classifications (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete restrict,
    customer_id uuid not null references customers(id) on delete restrict,
    risk_level varchar not null check (risk_level in ('LOW', 'MEDIUM', 'HIGH', 'VERY_HIGH', 'PEP')),
    risk_score integer check (risk_score >= 0 and risk_score <= 1000),
    risk_factors jsonb,
    classified_by uuid references users(id) on delete restrict,
    classification_date date not null default current_date,
    next_review_date date,
    notes text,
    is_current boolean default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index idx_customer_risk_classifications_current on customer_risk_classifications(tenant_id, customer_id) where is_current = true;

create trigger update_customer_risk_classifications_updated_at
    before update on customer_risk_classifications
    for each row
    execute function update_updated_at();

create table customer_restrictions (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete restrict,
    customer_id uuid not null references customers(id) on delete restrict,
    restriction_type varchar not null check (restriction_type in ('DEBIT_FREEZE', 'CREDIT_FREEZE', 'FULL_FREEZE', 'WITHDRAWAL_LIMIT', 'NO_INTERNATIONAL', 'NO_ONLINE')),
    reason text not null,
    imposed_by uuid references users(id) on delete restrict,
    imposed_at timestamptz default now(),
    lifted_by uuid references users(id) on delete restrict,
    lifted_at timestamptz,
    is_active boolean default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create trigger update_customer_restrictions_updated_at
    before update on customer_restrictions
    for each row
    execute function update_updated_at();

create table customer_watchlist (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete restrict,
    identifier_type varchar not null check (identifier_type in ('NAME', 'ID_NUMBER', 'PHONE', 'EMAIL', 'TIN')),
    identifier_value varchar(255) not null,
    list_source varchar not null check (list_source in ('INTERNAL', 'SANCTIONS', 'PEP', 'LAW_ENFORCEMENT', 'REGULATORY')),
    reason text,
    added_by uuid references users(id) on delete restrict,
    is_active boolean default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (tenant_id, identifier_type, identifier_value, list_source)
);

create trigger update_customer_watchlist_updated_at
    before update on customer_watchlist
    for each row
    execute function update_updated_at();

create table customer_profile_history (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete restrict,
    customer_id uuid not null references customers(id) on delete restrict,
    field_name varchar(100) not null,
    old_value text,
    new_value text,
    changed_by uuid references users(id) on delete restrict,
    change_reason text,
    created_at timestamptz not null default now()
);

create index idx_customer_profile_history_lookup on customer_profile_history(tenant_id, customer_id, created_at desc);

-- ----------------------------------------------------------
-- Triggers
-- ----------------------------------------------------------

create or replace function log_customer_profile_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_changed_by uuid;
begin
    -- Attempt to get the user ID if set in current session, otherwise null
    begin
        v_changed_by := current_setting('request.jwt.claim.sub', true)::uuid;
    exception when others then
        v_changed_by := null;
    end;

    if OLD.first_name is distinct from NEW.first_name then
        insert into customer_profile_history (tenant_id, customer_id, field_name, old_value, new_value, changed_by)
        values (NEW.tenant_id, NEW.id, 'first_name', OLD.first_name, NEW.first_name, v_changed_by);
    end if;

    if OLD.last_name is distinct from NEW.last_name then
        insert into customer_profile_history (tenant_id, customer_id, field_name, old_value, new_value, changed_by)
        values (NEW.tenant_id, NEW.id, 'last_name', OLD.last_name, NEW.last_name, v_changed_by);
    end if;

    if OLD.email is distinct from NEW.email then
        insert into customer_profile_history (tenant_id, customer_id, field_name, old_value, new_value, changed_by)
        values (NEW.tenant_id, NEW.id, 'email', OLD.email, NEW.email, v_changed_by);
    end if;
    
    if OLD.phone is distinct from NEW.phone then
        insert into customer_profile_history (tenant_id, customer_id, field_name, old_value, new_value, changed_by)
        values (NEW.tenant_id, NEW.id, 'phone', OLD.phone, NEW.phone, v_changed_by);
    end if;
    
    if OLD.kyc_status is distinct from NEW.kyc_status then
        insert into customer_profile_history (tenant_id, customer_id, field_name, old_value, new_value, changed_by)
        values (NEW.tenant_id, NEW.id, 'kyc_status', OLD.kyc_status, NEW.kyc_status, v_changed_by);
    end if;
    
    return NEW;
end;
$$;
alter function log_customer_profile_changes() owner to postgres;

create trigger trg_log_customer_profile_changes
    after update on customers
    for each row
    execute function log_customer_profile_changes();

-- ----------------------------------------------------------
-- Functions
-- ----------------------------------------------------------

create or replace function add_kyc_document(
    p_tenant_id uuid,
    p_customer_id uuid,
    p_document_type varchar,
    p_document_number varchar,
    p_file_path text,
    p_file_name varchar,
    p_issue_date date,
    p_expiry_date date,
    p_issuing_authority varchar
)
returns jsonb
security definer
set search_path = public, pg_temp
as $$
declare
    v_doc_id uuid;
begin
    if not exists (select 1 from customers where id = p_customer_id and tenant_id = p_tenant_id) then
        return jsonb_build_object('success', false, 'error', 'Customer not found');
    end if;

    insert into kyc_documents (
        tenant_id, customer_id, document_type, document_number, file_path, file_name, issue_date, expiry_date, issuing_authority
    ) values (
        p_tenant_id, p_customer_id, p_document_type, p_document_number, p_file_path, p_file_name, p_issue_date, p_expiry_date, p_issuing_authority
    ) returning id into v_doc_id;

    return jsonb_build_object('success', true, 'document_id', v_doc_id);
end;
$$ language plpgsql;
alter function add_kyc_document(uuid, uuid, varchar, varchar, text, varchar, date, date, varchar) owner to postgres;

create or replace function verify_kyc_document(
    p_tenant_id uuid,
    p_document_id uuid,
    p_verified_by uuid,
    p_approved boolean,
    p_rejection_reason text default null
)
returns jsonb
security definer
set search_path = public, pg_temp
as $$
declare
    v_customer_id uuid;
    v_all_verified boolean;
begin
    if not exists (select 1 from kyc_documents where id = p_document_id and tenant_id = p_tenant_id) then
        return jsonb_build_object('success', false, 'error', 'Document not found');
    end if;

    if p_approved then
        update kyc_documents
        set status = 'VERIFIED',
            verified_by = p_verified_by,
            verified_at = now()
        where id = p_document_id
        returning customer_id into v_customer_id;
        
        -- Check if all required docs are verified (simplified logic: check if any PENDING/REJECTED docs exist)
        select not exists (
            select 1 from kyc_documents 
            where customer_id = v_customer_id 
            and tenant_id = p_tenant_id 
            and status in ('PENDING', 'REJECTED')
        ) into v_all_verified;
        
        if v_all_verified then
            update customers
            set kyc_status = 'VERIFIED'
            where id = v_customer_id and tenant_id = p_tenant_id;
        end if;
    else
        update kyc_documents
        set status = 'REJECTED',
            rejection_reason = p_rejection_reason,
            verified_by = p_verified_by,
            verified_at = now()
        where id = p_document_id;
    end if;

    return jsonb_build_object('success', true);
end;
$$ language plpgsql;
alter function verify_kyc_document(uuid, uuid, uuid, boolean, text) owner to postgres;

create or replace function classify_customer_risk(
    p_tenant_id uuid,
    p_customer_id uuid,
    p_risk_level varchar,
    p_risk_score integer,
    p_risk_factors jsonb,
    p_classified_by uuid,
    p_next_review_date date
)
returns jsonb
security definer
set search_path = public, pg_temp
as $$
declare
    v_class_id uuid;
begin
    if not exists (select 1 from customers where id = p_customer_id and tenant_id = p_tenant_id) then
        return jsonb_build_object('success', false, 'error', 'Customer not found');
    end if;

    update customer_risk_classifications
    set is_current = false
    where customer_id = p_customer_id and tenant_id = p_tenant_id and is_current = true;

    insert into customer_risk_classifications (
        tenant_id, customer_id, risk_level, risk_score, risk_factors, classified_by, next_review_date
    ) values (
        p_tenant_id, p_customer_id, p_risk_level, p_risk_score, p_risk_factors, p_classified_by, p_next_review_date
    ) returning id into v_class_id;

    return jsonb_build_object('success', true, 'classification_id', v_class_id);
end;
$$ language plpgsql;
alter function classify_customer_risk(uuid, uuid, varchar, integer, jsonb, uuid, date) owner to postgres;

create or replace function add_customer_restriction(
    p_tenant_id uuid,
    p_customer_id uuid,
    p_restriction_type varchar,
    p_reason text,
    p_imposed_by uuid
)
returns jsonb
security definer
set search_path = public, pg_temp
as $$
declare
    v_res_id uuid;
begin
    if not exists (select 1 from customers where id = p_customer_id and tenant_id = p_tenant_id) then
        return jsonb_build_object('success', false, 'error', 'Customer not found');
    end if;

    insert into customer_restrictions (
        tenant_id, customer_id, restriction_type, reason, imposed_by
    ) values (
        p_tenant_id, p_customer_id, p_restriction_type, p_reason, p_imposed_by
    ) returning id into v_res_id;

    return jsonb_build_object('success', true, 'restriction_id', v_res_id);
end;
$$ language plpgsql;
alter function add_customer_restriction(uuid, uuid, varchar, text, uuid) owner to postgres;

create or replace function lift_customer_restriction(
    p_tenant_id uuid,
    p_restriction_id uuid,
    p_lifted_by uuid
)
returns jsonb
security definer
set search_path = public, pg_temp
as $$
begin
    if not exists (select 1 from customer_restrictions where id = p_restriction_id and tenant_id = p_tenant_id) then
        return jsonb_build_object('success', false, 'error', 'Restriction not found');
    end if;

    update customer_restrictions
    set is_active = false,
        lifted_by = p_lifted_by,
        lifted_at = now()
    where id = p_restriction_id and tenant_id = p_tenant_id;

    return jsonb_build_object('success', true);
end;
$$ language plpgsql;
alter function lift_customer_restriction(uuid, uuid, uuid) owner to postgres;

create or replace function check_customer_watchlist(
    p_tenant_id uuid,
    p_identifier_type varchar,
    p_identifier_value varchar
)
returns jsonb
security definer
set search_path = public, pg_temp
as $$
declare
    v_matches jsonb;
begin
    select jsonb_agg(row_to_json(w))
    into v_matches
    from customer_watchlist w
    where w.tenant_id = p_tenant_id
      and w.identifier_type = p_identifier_type
      and w.identifier_value = p_identifier_value
      and w.is_active = true;

    return jsonb_build_object('success', true, 'matches', coalesce(v_matches, '[]'::jsonb));
end;
$$ language plpgsql;
alter function check_customer_watchlist(uuid, varchar, varchar) owner to postgres;

create or replace function get_expiring_documents(
    p_tenant_id uuid,
    p_days_ahead integer default 30
)
returns jsonb
security definer
set search_path = public, pg_temp
as $$
declare
    v_docs jsonb;
begin
    select jsonb_agg(row_to_json(d))
    into v_docs
    from kyc_documents d
    where d.tenant_id = p_tenant_id
      and d.expiry_date is not null
      and d.expiry_date <= (current_date + p_days_ahead)
      and d.status in ('VERIFIED', 'PENDING');

    return jsonb_build_object('success', true, 'documents', coalesce(v_docs, '[]'::jsonb));
end;
$$ language plpgsql;
alter function get_expiring_documents(uuid, integer) owner to postgres;

commit;
