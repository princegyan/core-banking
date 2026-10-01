-- ============================================================
-- 0035_teller_cashboxes.sql
-- Milestone 16 — Teller & Cash Management
-- Step 1: Cashbox Foundation
-- ============================================================

CREATE TABLE IF NOT EXISTS cashboxes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id UUID NOT NULL
        REFERENCES tenants(id) ON DELETE CASCADE,

    institution_id UUID NOT NULL
        REFERENCES institutions(id) ON DELETE RESTRICT,

    branch_id UUID NOT NULL
        REFERENCES branches(id) ON DELETE RESTRICT,

    code VARCHAR(50) NOT NULL,
    name VARCHAR(150) NOT NULL,

    ledger_account_id UUID NOT NULL
        REFERENCES ledger_accounts(id) ON DELETE RESTRICT,

    assigned_user_id UUID
        REFERENCES users(id) ON DELETE SET NULL,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT cashboxes_tenant_code_unique
        UNIQUE (tenant_id, code),

    CONSTRAINT cashboxes_tenant_ledger_unique
        UNIQUE (tenant_id, ledger_account_id)
);

CREATE INDEX IF NOT EXISTS idx_cashboxes_tenant
    ON cashboxes(tenant_id);

CREATE INDEX IF NOT EXISTS idx_cashboxes_branch
    ON cashboxes(tenant_id, branch_id);

CREATE INDEX IF NOT EXISTS idx_cashboxes_assigned_user
    ON cashboxes(tenant_id, assigned_user_id);

CREATE INDEX IF NOT EXISTS idx_cashboxes_active
    ON cashboxes(tenant_id, is_active);

-- ------------------------------------------------------------
-- Validate tenant relationships
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION validate_cashbox_tenant()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_institution_tenant UUID;
    v_branch_tenant UUID;
    v_ledger_tenant UUID;
    v_user_tenant UUID;
BEGIN
    SELECT tenant_id
    INTO v_institution_tenant
    FROM institutions
    WHERE id = NEW.institution_id;

    IF v_institution_tenant IS NULL
       OR v_institution_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION
            'Cashbox institution does not belong to tenant';
    END IF;

    SELECT tenant_id
    INTO v_branch_tenant
    FROM branches
    WHERE id = NEW.branch_id;

    IF v_branch_tenant IS NULL
       OR v_branch_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION
            'Cashbox branch does not belong to tenant';
    END IF;

    SELECT tenant_id
    INTO v_ledger_tenant
    FROM ledger_accounts
    WHERE id = NEW.ledger_account_id;

    IF v_ledger_tenant IS NULL
       OR v_ledger_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION
            'Cashbox ledger account does not belong to tenant';
    END IF;

    IF NEW.assigned_user_id IS NOT NULL THEN

        SELECT tenant_id
        INTO v_user_tenant
        FROM users
        WHERE id = NEW.assigned_user_id;

        IF v_user_tenant IS NULL
           OR v_user_tenant <> NEW.tenant_id THEN
            RAISE EXCEPTION
                'Cashbox assigned user does not belong to tenant';
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_cashbox_tenant
ON cashboxes;

CREATE TRIGGER trg_validate_cashbox_tenant
BEFORE INSERT OR UPDATE
ON cashboxes
FOR EACH ROW
EXECUTE FUNCTION validate_cashbox_tenant();

-- ------------------------------------------------------------
-- Updated-at trigger
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_cashboxes_updated_at
ON cashboxes;

CREATE TRIGGER trg_cashboxes_updated_at
BEFORE UPDATE
ON cashboxes
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- Seed Demo Cashbox
-- ============================================================

DO $$
DECLARE
    v_tenant_id UUID := '669d95bb-167c-483d-b652-898bb1e78ac7';
    v_institution_id UUID;
    v_branch_id UUID;
    v_cash_ledger_id UUID;
    v_cashbox_ledger_id UUID;
BEGIN

    SELECT id
    INTO v_institution_id
    FROM institutions
    WHERE tenant_id = v_tenant_id
      AND code = 'DEMO'
    LIMIT 1;

    SELECT id
    INTO v_branch_id
    FROM branches
    WHERE tenant_id = v_tenant_id
      AND code = 'HQ'
    LIMIT 1;

    SELECT id
    INTO v_cash_ledger_id
    FROM ledger_accounts
    WHERE tenant_id = v_tenant_id
      AND account_code = '1010';

    IF v_institution_id IS NULL THEN
        RAISE EXCEPTION 'Demo institution not found';
    END IF;

    IF v_branch_id IS NULL THEN
        RAISE EXCEPTION 'Demo HQ branch not found';
    END IF;

    IF v_cash_ledger_id IS NULL THEN
        RAISE EXCEPTION 'Demo Cash GL account 1010 not found';
    END IF;

    -- Create a dedicated GL account for the teller cashbox.
    INSERT INTO ledger_accounts (
        tenant_id,
        account_code,
        account_name,
        account_type,
        parent_account_id,
        currency,
        is_active
    )
    VALUES (
        v_tenant_id,
        '1010-TELLER-HQ-01',
        'Teller Cashbox - HQ 01',
        'ASSET',
        v_cash_ledger_id,
        'GHS',
        TRUE
    )
    ON CONFLICT (tenant_id, account_code)
    DO NOTHING;

    SELECT id
    INTO v_cashbox_ledger_id
    FROM ledger_accounts
    WHERE tenant_id = v_tenant_id
      AND account_code = '1010-TELLER-HQ-01';

    INSERT INTO cashboxes (
        tenant_id,
        institution_id,
        branch_id,
        code,
        name,
        ledger_account_id,
        is_active
    )
    VALUES (
        v_tenant_id,
        v_institution_id,
        v_branch_id,
        'HQ-TELLER-01',
        'Head Office Teller 01',
        v_cashbox_ledger_id,
        TRUE
    )
    ON CONFLICT (tenant_id, code)
    DO NOTHING;

END;
$$;