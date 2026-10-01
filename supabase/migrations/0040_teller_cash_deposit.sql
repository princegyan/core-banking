-- ============================================================
-- 0040_teller_cash_deposit.sql
-- Milestone 16 — Teller & Cash Management
-- Step 7: Teller Cash-In / Customer Deposit
-- ============================================================

CREATE OR REPLACE FUNCTION public.post_teller_cash_deposit(
    p_tenant_id UUID,
    p_session_id UUID,
    p_account_id UUID,
    p_amount BIGINT,
    p_description TEXT DEFAULT NULL,
    p_idempotency_key VARCHAR DEFAULT NULL,
    p_created_by UUID DEFAULT NULL
)
RETURNS TABLE (
    transaction_id UUID,
    transaction_reference VARCHAR,
    account_id UUID,
    session_id UUID,
    amount BIGINT,
    status transaction_status,
    message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_session teller_cash_sessions%ROWTYPE;
    v_cashbox cashboxes%ROWTYPE;
    v_account accounts%ROWTYPE;

    v_teller_gl ledger_accounts%ROWTYPE;
    v_customer_gl ledger_accounts%ROWTYPE;

    v_transaction_id UUID;
    v_reference VARCHAR;

    v_business_date_id UUID;
    v_period_id UUID;

    v_existing_transaction_id UUID;
BEGIN

    -- --------------------------------------------------------
    -- Validate amount
    -- --------------------------------------------------------

    IF p_amount <= 0 THEN
        RAISE EXCEPTION
            'Deposit amount must be greater than zero';
    END IF;

    -- --------------------------------------------------------
    -- Validate creator
    -- --------------------------------------------------------

    IF p_created_by IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1
            FROM public.users AS u
            WHERE u.id = p_created_by
              AND u.tenant_id = p_tenant_id
              AND u.is_active = TRUE
        ) THEN
            RAISE EXCEPTION
                'Creating user is not active in tenant';
        END IF;
    END IF;

    -- --------------------------------------------------------
    -- Idempotency
    -- --------------------------------------------------------

    IF p_idempotency_key IS NOT NULL THEN

        SELECT t.id
        INTO v_existing_transaction_id
        FROM public.transactions AS t
        WHERE t.tenant_id = p_tenant_id
          AND t.idempotency_key = p_idempotency_key
        LIMIT 1;

        IF v_existing_transaction_id IS NOT NULL THEN

            RETURN QUERY
            SELECT
                t.id,
                t.reference,
                p_account_id,
                p_session_id,
                t.amount,
                t.status,
                'Duplicate teller deposit request'::TEXT
            FROM public.transactions AS t
            WHERE t.id = v_existing_transaction_id;

            RETURN;
        END IF;

    END IF;

    -- --------------------------------------------------------
    -- Lock teller session
    -- --------------------------------------------------------

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

    IF p_created_by IS NOT NULL
       AND v_session.teller_user_id <> p_created_by THEN
        RAISE EXCEPTION
            'User does not own this teller session';
    END IF;

    -- --------------------------------------------------------
    -- Lock cashbox
    -- --------------------------------------------------------

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

    IF NOT v_cashbox.is_active THEN
        RAISE EXCEPTION
            'Cashbox is inactive';
    END IF;

    -- --------------------------------------------------------
    -- Lock customer account
    -- --------------------------------------------------------

    SELECT a.*
    INTO v_account
    FROM public.accounts AS a
    WHERE a.id = p_account_id
      AND a.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Customer account not found for tenant';
    END IF;

    IF v_account.status <> 'ACTIVE' THEN
        RAISE EXCEPTION
            'Customer account must be ACTIVE. Current status: %',
            v_account.status;
    END IF;

    IF v_account.currency <> 'GHS' THEN
        RAISE EXCEPTION
            'Teller cash deposit currently supports GHS accounts only';
    END IF;

    IF v_account.ledger_account_id IS NULL THEN
        RAISE EXCEPTION
            'Customer account has no ledger account';
    END IF;

    -- --------------------------------------------------------
    -- Customer ledger
    -- --------------------------------------------------------

    SELECT la.*
    INTO v_customer_gl
    FROM public.ledger_accounts AS la
    WHERE la.id = v_account.ledger_account_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Customer ledger account not found';
    END IF;

    IF v_customer_gl.account_type <> 'LIABILITY' THEN
        RAISE EXCEPTION
            'Customer deposit ledger must be LIABILITY';
    END IF;

    -- --------------------------------------------------------
    -- Teller cash GL
    -- --------------------------------------------------------

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
            'Teller cash GL must be ASSET';
    END IF;

    -- --------------------------------------------------------
    -- Business date
    -- --------------------------------------------------------

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

    -- --------------------------------------------------------
    -- Accounting period
    -- --------------------------------------------------------

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

    -- --------------------------------------------------------
    -- Generate reference
    -- --------------------------------------------------------

    v_reference := generate_transaction_reference('DEPOSIT');

    -- --------------------------------------------------------
    -- Create transaction
    -- --------------------------------------------------------

    INSERT INTO public.transactions (
        tenant_id,
        reference,
        transaction_type,
        status,
        currency,
        amount,
        description,
        idempotency_key,
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
        'DEPOSIT',
        'POSTED',
        'GHS',
        p_amount,
        COALESCE(p_description, 'Teller cash deposit'),
        p_idempotency_key,
        v_business_date_id,
        v_period_id,
        CURRENT_DATE,
        'TELLER',
        p_created_by,
        NOW()
    )
    RETURNING id
    INTO v_transaction_id;

    -- --------------------------------------------------------
    -- Debit Teller Cash
    -- --------------------------------------------------------

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
        p_amount,
        0,
        'Teller cash received'
    );

    -- --------------------------------------------------------
    -- Credit Customer Deposit Liability
    -- --------------------------------------------------------

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
        v_customer_gl.id,
        0,
        p_amount,
        'Customer cash deposit'
    );

    -- --------------------------------------------------------
    -- Update teller GL
    -- --------------------------------------------------------

    UPDATE public.ledger_accounts
    SET current_balance = current_balance + p_amount,
        updated_at = NOW()
    WHERE id = v_teller_gl.id;

    -- --------------------------------------------------------
    -- Update customer GL
    -- --------------------------------------------------------

    UPDATE public.ledger_accounts
    SET current_balance = current_balance + p_amount,
        updated_at = NOW()
    WHERE id = v_customer_gl.id;

    -- --------------------------------------------------------
    -- Update customer account
    -- --------------------------------------------------------

    UPDATE public.accounts AS a
    SET ledger_balance = a.ledger_balance + p_amount,
        available_balance = a.available_balance + p_amount,
        updated_at = NOW()
    WHERE a.id = p_account_id;

    -- --------------------------------------------------------
    -- Record teller movement
    -- --------------------------------------------------------

    INSERT INTO public.teller_cash_movements (
        tenant_id,
        session_id,
        cashbox_id,
        movement_type,
        amount,
        transaction_id,
        reference,
        description,
        created_by
    )
    VALUES (
        p_tenant_id,
        p_session_id,
        v_session.cashbox_id,
        'DEPOSIT',
        p_amount,
        v_transaction_id,
        v_reference,
        COALESCE(p_description, 'Teller cash deposit'),
        p_created_by
    );

    -- --------------------------------------------------------
    -- Audit
    -- --------------------------------------------------------

    INSERT INTO public.audit_logs (
        tenant_id,
        user_id,
        action,
        entity_type,
        entity_id,
        new_values
    )
    VALUES (
        p_tenant_id,
        p_created_by,
        'TELLER_CASH_DEPOSIT_POSTED',
        'TRANSACTION',
        v_transaction_id,
        jsonb_build_object(
            'reference', v_reference,
            'account_id', p_account_id,
            'session_id', p_session_id,
            'cashbox_id', v_session.cashbox_id,
            'amount', p_amount
        )
    );

    RETURN QUERY
    SELECT
        v_transaction_id,
        v_reference,
        p_account_id,
        p_session_id,
        p_amount,
        'POSTED'::transaction_status,
        'Teller cash deposit posted successfully'::TEXT;

END;
$function$;

ALTER FUNCTION public.post_teller_cash_deposit(
    UUID,
    UUID,
    UUID,
    BIGINT,
    TEXT,
    VARCHAR,
    UUID
)
OWNER TO postgres;

REVOKE ALL
ON FUNCTION public.post_teller_cash_deposit(
    UUID,
    UUID,
    UUID,
    BIGINT,
    TEXT,
    VARCHAR,
    UUID
)
FROM PUBLIC;