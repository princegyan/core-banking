-- ============================================================
-- 0038_teller_cash_movements.sql
-- Milestone 16 — Teller & Cash Management
-- Step 4: Teller Cash Movement Ledger
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'teller_cash_movement_type'
    ) THEN
        CREATE TYPE teller_cash_movement_type AS ENUM (
            'OPENING',
            'DEPOSIT',
            'WITHDRAWAL',
            'CASH_IN',
            'CASH_OUT',
            'TRANSFER_IN',
            'TRANSFER_OUT',
            'ADJUSTMENT',
            'CLOSING'
        );
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS teller_cash_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id UUID NOT NULL
        REFERENCES tenants(id) ON DELETE CASCADE,

    session_id UUID NOT NULL
        REFERENCES teller_cash_sessions(id) ON DELETE RESTRICT,

    cashbox_id UUID NOT NULL
        REFERENCES cashboxes(id) ON DELETE RESTRICT,

    movement_type teller_cash_movement_type NOT NULL,

    amount BIGINT NOT NULL,

    transaction_id UUID
        REFERENCES transactions(id) ON DELETE RESTRICT,

    reference VARCHAR(100),

    description TEXT,

    created_by UUID
        REFERENCES users(id) ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT teller_cash_movement_amount_positive
        CHECK (amount > 0)
);

CREATE INDEX IF NOT EXISTS idx_teller_cash_movements_tenant
    ON teller_cash_movements(tenant_id);

CREATE INDEX IF NOT EXISTS idx_teller_cash_movements_session
    ON teller_cash_movements(session_id);

CREATE INDEX IF NOT EXISTS idx_teller_cash_movements_cashbox
    ON teller_cash_movements(cashbox_id);

CREATE INDEX IF NOT EXISTS idx_teller_cash_movements_transaction
    ON teller_cash_movements(transaction_id);

CREATE INDEX IF NOT EXISTS idx_teller_cash_movements_created_at
    ON teller_cash_movements(created_at);

-- ------------------------------------------------------------
-- Tenant consistency
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION validate_teller_cash_movement()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_session_tenant UUID;
    v_cashbox_tenant UUID;
    v_session_cashbox UUID;
    v_user_tenant UUID;
BEGIN

    SELECT tenant_id, cashbox_id
    INTO v_session_tenant, v_session_cashbox
    FROM teller_cash_sessions
    WHERE id = NEW.session_id;

    IF v_session_tenant IS NULL
       OR v_session_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION
            'Teller session does not belong to tenant';
    END IF;

    IF v_session_cashbox <> NEW.cashbox_id THEN
        RAISE EXCEPTION
            'Movement cashbox does not match session cashbox';
    END IF;

    SELECT tenant_id
    INTO v_cashbox_tenant
    FROM cashboxes
    WHERE id = NEW.cashbox_id;

    IF v_cashbox_tenant IS NULL
       OR v_cashbox_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION
            'Cashbox does not belong to tenant';
    END IF;

    IF NEW.created_by IS NOT NULL THEN

        SELECT tenant_id
        INTO v_user_tenant
        FROM users
        WHERE id = NEW.created_by;

        IF v_user_tenant IS NULL
           OR v_user_tenant <> NEW.tenant_id THEN
            RAISE EXCEPTION
                'Movement creator does not belong to tenant';
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_teller_cash_movement
ON teller_cash_movements;

CREATE TRIGGER trg_validate_teller_cash_movement
BEFORE INSERT OR UPDATE
ON teller_cash_movements
FOR EACH ROW
EXECUTE FUNCTION validate_teller_cash_movement();