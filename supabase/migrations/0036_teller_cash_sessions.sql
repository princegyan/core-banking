-- ============================================================
-- 0036_teller_cash_sessions.sql
-- Milestone 16 — Teller & Cash Management
-- Step 2: Teller Cash Sessions
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'teller_session_status'
    ) THEN
        CREATE TYPE teller_session_status AS ENUM (
            'OPEN',
            'SUSPENDED',
            'CLOSED'
        );
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS teller_cash_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id UUID NOT NULL
        REFERENCES tenants(id) ON DELETE CASCADE,

    cashbox_id UUID NOT NULL
        REFERENCES cashboxes(id) ON DELETE RESTRICT,

    teller_user_id UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    status teller_session_status NOT NULL DEFAULT 'OPEN',

    opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,

    opening_balance BIGINT NOT NULL DEFAULT 0,

    expected_closing_balance BIGINT,

    actual_closing_balance BIGINT,

    variance BIGINT,

    closing_notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT teller_session_opening_balance_nonnegative
        CHECK (opening_balance >= 0),

    CONSTRAINT teller_session_expected_balance_nonnegative
        CHECK (
            expected_closing_balance IS NULL
            OR expected_closing_balance >= 0
        ),

    CONSTRAINT teller_session_actual_balance_nonnegative
        CHECK (
            actual_closing_balance IS NULL
            OR actual_closing_balance >= 0
        ),

    CONSTRAINT teller_session_closed_fields_check
        CHECK (
            status <> 'CLOSED'
            OR closed_at IS NOT NULL
        )
);

CREATE INDEX IF NOT EXISTS idx_teller_sessions_tenant
    ON teller_cash_sessions(tenant_id);

CREATE INDEX IF NOT EXISTS idx_teller_sessions_cashbox
    ON teller_cash_sessions(tenant_id, cashbox_id);

CREATE INDEX IF NOT EXISTS idx_teller_sessions_teller
    ON teller_cash_sessions(tenant_id, teller_user_id);

CREATE INDEX IF NOT EXISTS idx_teller_sessions_status
    ON teller_cash_sessions(tenant_id, status);

-- Only one active session per cashbox.
CREATE UNIQUE INDEX IF NOT EXISTS uq_teller_cashbox_active_session
    ON teller_cash_sessions(cashbox_id)
    WHERE status IN ('OPEN', 'SUSPENDED');

-- ------------------------------------------------------------
-- Tenant validation
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION validate_teller_cash_session_tenant()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cashbox_tenant UUID;
    v_user_tenant UUID;
BEGIN

    SELECT tenant_id
    INTO v_cashbox_tenant
    FROM cashboxes
    WHERE id = NEW.cashbox_id;

    IF v_cashbox_tenant IS NULL
       OR v_cashbox_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION
            'Cashbox does not belong to tenant';
    END IF;

    SELECT tenant_id
    INTO v_user_tenant
    FROM users
    WHERE id = NEW.teller_user_id;

    IF v_user_tenant IS NULL
       OR v_user_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION
            'Teller user does not belong to tenant';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_teller_cash_session_tenant
ON teller_cash_sessions;

CREATE TRIGGER trg_validate_teller_cash_session_tenant
BEFORE INSERT OR UPDATE
ON teller_cash_sessions
FOR EACH ROW
EXECUTE FUNCTION validate_teller_cash_session_tenant();

-- ------------------------------------------------------------
-- Updated-at trigger
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_teller_cash_sessions_updated_at
ON teller_cash_sessions;

CREATE TRIGGER trg_teller_cash_sessions_updated_at
BEFORE UPDATE
ON teller_cash_sessions
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();