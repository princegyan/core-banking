-- ============================================================
-- Milestone 26: API Security & Production Hardening
-- ============================================================

BEGIN;

-- ----------------------------------------------------------
-- 1. Tables
-- ----------------------------------------------------------

CREATE TABLE api_rate_limits (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    endpoint_pattern varchar(255) NOT NULL,
    method varchar(10) NOT NULL,
    max_requests integer NOT NULL DEFAULT 100,
    window_seconds integer NOT NULL DEFAULT 60,
    is_active boolean DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_api_rate_limits_tenant_pattern_method UNIQUE (tenant_id, endpoint_pattern, method)
);

CREATE TRIGGER set_api_rate_limits_updated_at
    BEFORE UPDATE ON api_rate_limits
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

CREATE TABLE api_request_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE,
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    method varchar(10) NOT NULL,
    path varchar(500) NOT NULL,
    status_code integer,
    response_time_ms integer,
    ip_address varchar(45),
    user_agent text,
    idempotency_key varchar(255),
    request_body_size integer,
    error_message text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_api_request_log_tenant_created_at ON api_request_log(tenant_id, created_at DESC);
CREATE INDEX idx_api_request_log_created_at ON api_request_log(created_at);

CREATE TABLE idempotency_keys (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    key varchar(255) NOT NULL,
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    method varchar(10) NOT NULL,
    path varchar(500) NOT NULL,
    status_code integer,
    response_body jsonb,
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_idempotency_keys_tenant_key UNIQUE (tenant_id, key)
);

CREATE TRIGGER set_idempotency_keys_updated_at
    BEFORE UPDATE ON idempotency_keys
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

CREATE INDEX idx_idempotency_keys_expires_at ON idempotency_keys(expires_at);

-- ----------------------------------------------------------
-- 2. Functions
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION cleanup_expired_idempotency_keys()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_deleted_count integer;
BEGIN
    DELETE FROM idempotency_keys
    WHERE expires_at < now();
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    
    RETURN jsonb_build_object(
        'success', true,
        'deleted_count', v_deleted_count
    );
END;
$$;

ALTER FUNCTION cleanup_expired_idempotency_keys() OWNER TO postgres;

CREATE OR REPLACE FUNCTION cleanup_old_request_logs(p_retention_days integer DEFAULT 90)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_deleted_count integer;
BEGIN
    DELETE FROM api_request_log
    WHERE created_at < now() - (p_retention_days || ' days')::interval;
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    
    RETURN jsonb_build_object(
        'success', true,
        'deleted_count', v_deleted_count
    );
END;
$$;

ALTER FUNCTION cleanup_old_request_logs(integer) OWNER TO postgres;

-- ----------------------------------------------------------
-- 3. RLS Policies
-- ----------------------------------------------------------

ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE transaction_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_accounts ENABLE ROW LEVEL SECURITY;

-- Accounts
CREATE POLICY select_tenant_accounts ON accounts FOR SELECT USING (tenant_id = current_setting('app.tenant_id', true)::uuid);
CREATE POLICY insert_tenant_accounts ON accounts FOR INSERT WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
CREATE POLICY update_tenant_accounts ON accounts FOR UPDATE USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- Customers
CREATE POLICY select_tenant_customers ON customers FOR SELECT USING (tenant_id = current_setting('app.tenant_id', true)::uuid);
CREATE POLICY insert_tenant_customers ON customers FOR INSERT WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
CREATE POLICY update_tenant_customers ON customers FOR UPDATE USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- Transactions
CREATE POLICY select_tenant_transactions ON transactions FOR SELECT USING (tenant_id = current_setting('app.tenant_id', true)::uuid);
CREATE POLICY insert_tenant_transactions ON transactions FOR INSERT WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
CREATE POLICY update_tenant_transactions ON transactions FOR UPDATE USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- Transaction Entries
-- Assuming transaction_entries does not have tenant_id directly, join with transactions.
CREATE POLICY select_tenant_transaction_entries ON transaction_entries FOR SELECT USING (
    transaction_id IN (SELECT id FROM transactions WHERE tenant_id = current_setting('app.tenant_id', true)::uuid)
);
CREATE POLICY insert_tenant_transaction_entries ON transaction_entries FOR INSERT WITH CHECK (
    transaction_id IN (SELECT id FROM transactions WHERE tenant_id = current_setting('app.tenant_id', true)::uuid)
);
CREATE POLICY update_tenant_transaction_entries ON transaction_entries FOR UPDATE USING (
    transaction_id IN (SELECT id FROM transactions WHERE tenant_id = current_setting('app.tenant_id', true)::uuid)
);

-- Ledger Accounts
CREATE POLICY select_tenant_ledger_accounts ON ledger_accounts FOR SELECT USING (tenant_id = current_setting('app.tenant_id', true)::uuid);
CREATE POLICY insert_tenant_ledger_accounts ON ledger_accounts FOR INSERT WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
CREATE POLICY update_tenant_ledger_accounts ON ledger_accounts FOR UPDATE USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

COMMIT;
