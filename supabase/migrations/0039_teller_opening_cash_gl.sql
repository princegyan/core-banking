-- ============================================================
-- 0039_teller_opening_cash_gl.sql
-- Milestone 16 — Teller & Cash Management
-- Step 6: Opening Cash GL Posting
-- ============================================================

CREATE OR REPLACE FUNCTION public.post_teller_opening_cash(
    p_tenant_id UUID,
    p_session_id UUID,
    p_created_by UUID
)
RETURNS TABLE (
    transaction_id UUID,
    transaction_reference VARCHAR,
    session_id UUID,
    amount BIGINT,
    status transaction_status
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_session teller_cash_sessions%ROWTYPE;
    v_cashbox cashboxes%ROWTYPE;

    v_source_gl ledger_accounts%ROWTYPE;
    v_teller_gl ledger_accounts%ROWTYPE;

    v_transaction_id UUID;
    v_reference VARCHAR;
    v_business_date_id UUID;
    v_period_id UUID;

    v_amount BIGINT;
BEGIN

    -- Lock session
    SELECT tcs.*
    INTO v_session
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_session_id
      AND tcs.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Teller session not found for tenant';
    END IF;

    IF v_session.status <> 'OPEN' THEN
        RAISE EXCEPTION
            'Teller session is not OPEN';
    END IF;

    -- Opening cash must already be recorded
    SELECT COALESCE(SUM(tcm.amount), 0)
    INTO v_amount
    FROM public.teller_cash_movements AS tcm
    WHERE tcm.session_id = p_session_id
      AND tcm.movement_type = 'OPENING';

    IF v_amount = 0 THEN
        RAISE EXCEPTION
            'Opening cash movement has not been recorded';
    END IF;

    -- Prevent duplicate GL posting
    IF EXISTS (
        SELECT 1
        FROM public.teller_cash_movements AS tcm
        WHERE tcm.session_id = p_session_id
          AND tcm.movement_type = 'OPENING'
          AND tcm.transaction_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'Opening cash GL posting already exists';
    END IF;

    -- Cashbox
    SELECT cb.*
    INTO v_cashbox
    FROM public.cashboxes AS cb
    WHERE cb.id = v_session.cashbox_id
      AND cb.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Cashbox not found';
    END IF;

    -- Teller GL
    SELECT la.*
    INTO v_teller_gl
    FROM public.ledger_accounts AS la
    WHERE la.id = v_cashbox.ledger_account_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Teller cash GL account not found';
    END IF;

    IF v_teller_gl.account_type <> 'ASSET' THEN
        RAISE EXCEPTION
            'Teller cash GL must be an ASSET account';
    END IF;

    -- Main Cash GL
    SELECT la.*
    INTO v_source_gl
    FROM public.ledger_accounts AS la
    WHERE la.tenant_id = p_tenant_id
      AND la.account_code = '1010'
      AND la.is_active = TRUE
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Main Cash GL account 1010 not found';
    END IF;

    IF v_source_gl.current_balance < v_amount THEN
        RAISE EXCEPTION
            'Insufficient main cash balance';
    END IF;

    -- Business date
    SELECT bd.id
    INTO v_business_date_id
    FROM public.business_dates AS bd
    WHERE bd.tenant_id = p_tenant_id
      AND bd.status = 'OPEN'
    ORDER BY bd.business_date DESC
    LIMIT 1
    FOR UPDATE;

    IF v_business_date_id IS NULL THEN
        RAISE EXCEPTION
            'No OPEN business date found';
    END IF;

    -- Accounting period
    SELECT ap.id
    INTO v_period_id
    FROM public.accounting_periods AS ap
    WHERE ap.tenant_id = p_tenant_id
      AND ap.status = 'OPEN'
    ORDER BY ap.start_date DESC
    LIMIT 1
    FOR UPDATE;

    IF v_period_id IS NULL THEN
        RAISE EXCEPTION
            'No OPEN accounting period found';
    END IF;

    -- Generate reference
    v_reference := generate_transaction_reference(
        'TELLER_CASH_OPENING'
    );

    -- Transaction
    INSERT INTO public.transactions (
        tenant_id,
        reference,
        transaction_type,
        status,
        currency,
        amount,
        description,
        business_date_id,
        accounting_period_id,
        value_date,
        channel,
        created_by,
        posted_at
    )
    VALUES (
        p_tenant_id,
        v_reference,
        'TELLER_CASH_OPENING',
        'POSTED',
        'GHS',
        v_amount,
        'Teller opening cash',
        v_business_date_id,
        v_period_id,
        CURRENT_DATE,
        'TELLER',
        p_created_by,
        NOW()
    )
    RETURNING id
    INTO v_transaction_id;

    -- Debit Teller Cash
    INSERT INTO public.transaction_entries (
        transaction_id,
        tenant_id,
        ledger_account_id,
        debit,
        credit,
        description
    )
    VALUES (
        v_transaction_id,
        p_tenant_id,
        v_teller_gl.id,
        v_amount,
        0,
        'Teller opening cash'
    );

    -- Credit Main Cash
    INSERT INTO public.transaction_entries (
        transaction_id,
        tenant_id,
        ledger_account_id,
        debit,
        credit,
        description
    )
    VALUES (
        v_transaction_id,
        p_tenant_id,
        v_source_gl.id,
        0,
        v_amount,
        'Transfer to teller cashbox'
    );

    -- Update GL balances
    UPDATE public.ledger_accounts
    SET current_balance = current_balance + v_amount,
        updated_at = NOW()
    WHERE id = v_teller_gl.id;

    UPDATE public.ledger_accounts
    SET current_balance = current_balance - v_amount,
        updated_at = NOW()
    WHERE id = v_source_gl.id;

    -- Link movement to transaction
    UPDATE public.teller_cash_movements
    SET transaction_id = v_transaction_id,
        reference = v_reference
    WHERE session_id = p_session_id
      AND movement_type = 'OPENING'
      AND transaction_id IS NULL;

    RETURN QUERY
    SELECT
        v_transaction_id,
        v_reference,
        p_session_id,
        v_amount,
        'POSTED'::transaction_status;

END;
$function$;

ALTER FUNCTION public.post_teller_opening_cash(
    UUID,
    UUID,
    UUID
)
OWNER TO postgres;

REVOKE ALL
ON FUNCTION public.post_teller_opening_cash(
    UUID,
    UUID,
    UUID
)
FROM PUBLIC;