-- ============================================================
-- 0037_open_teller_session.sql
-- Milestone 16 — Teller & Cash Management
-- Step 3: Controlled Teller Session Opening
-- ============================================================

CREATE OR REPLACE FUNCTION open_teller_session(
    p_tenant_id UUID,
    p_cashbox_id UUID,
    p_teller_user_id UUID,
    p_opening_balance BIGINT
)
RETURNS TABLE (
    session_id UUID,
    cashbox_id UUID,
    teller_user_id UUID,
    status teller_session_status,
    opening_balance BIGINT,
    opened_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cashbox cashboxes%ROWTYPE;
    v_user users%ROWTYPE;
    v_session_id UUID;
    v_opened_at TIMESTAMPTZ;
BEGIN

    IF p_opening_balance < 0 THEN
        RAISE EXCEPTION
            'Opening balance cannot be negative';
    END IF;

    -- Validate teller
    SELECT u.*
    INTO v_user
    FROM users u
    WHERE u.id = p_teller_user_id
      AND u.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Teller user not found for tenant';
    END IF;

    IF NOT v_user.is_active THEN
        RAISE EXCEPTION
            'Teller user is inactive';
    END IF;

    -- Validate cashbox
    SELECT cb.*
    INTO v_cashbox
    FROM cashboxes cb
    WHERE cb.id = p_cashbox_id
      AND cb.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Cashbox not found for tenant';
    END IF;

    IF NOT v_cashbox.is_active THEN
        RAISE EXCEPTION
            'Cashbox is inactive';
    END IF;

    -- Teller must be assigned to this cashbox
    IF v_cashbox.assigned_user_id IS NULL THEN
        RAISE EXCEPTION
            'Cashbox is not assigned to a teller';
    END IF;

    IF v_cashbox.assigned_user_id <> p_teller_user_id THEN
        RAISE EXCEPTION
            'Teller is not assigned to this cashbox';
    END IF;

    -- Prevent another active session
    IF EXISTS (
        SELECT 1
        FROM teller_cash_sessions tcs
        WHERE tcs.cashbox_id = p_cashbox_id
          AND tcs.status IN ('OPEN', 'SUSPENDED')
    ) THEN
        RAISE EXCEPTION
            'Cashbox already has an active teller session';
    END IF;

    -- Create session
    INSERT INTO teller_cash_sessions (
        tenant_id,
        cashbox_id,
        teller_user_id,
        status,
        opening_balance
    )
    VALUES (
        p_tenant_id,
        p_cashbox_id,
        p_teller_user_id,
        'OPEN',
        p_opening_balance
    )
    RETURNING id, opened_at
    INTO v_session_id, v_opened_at;

    RETURN QUERY
    SELECT
        v_session_id,
        p_cashbox_id,
        p_teller_user_id,
        'OPEN'::teller_session_status,
        p_opening_balance,
        v_opened_at;

END;
$$;

ALTER FUNCTION open_teller_session(
    UUID,
    UUID,
    UUID,
    BIGINT
)
OWNER TO postgres;

REVOKE ALL
ON FUNCTION open_teller_session(
    UUID,
    UUID,
    UUID,
    BIGINT
)
FROM PUBLIC;