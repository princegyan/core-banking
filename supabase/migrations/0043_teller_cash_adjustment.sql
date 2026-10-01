CREATE OR REPLACE FUNCTION public.post_teller_cash_adjustment(
    p_tenant_id uuid,
    p_session_id uuid,
    p_movement_type public.teller_cash_movement_type,
    p_amount bigint,
    p_description text,
    p_idempotency_key varchar DEFAULT NULL,
    p_created_by uuid DEFAULT NULL
)
RETURNS TABLE (
    transaction_id uuid,
    transaction_reference varchar,
    session_id uuid,
    movement_type public.teller_cash_movement_type,
    amount bigint,
    status public.transaction_status,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_transaction_id uuid;
    v_transaction_reference varchar;

    v_cashbox_id uuid;
    v_teller_ledger_id uuid;
    v_main_cash_ledger_id uuid;

    v_teller_balance bigint;
    v_main_cash_balance bigint;

    v_session_status public.teller_session_status;

    v_business_date_id uuid;
    v_accounting_period_id uuid;

    v_existing_transaction_id uuid;
    v_existing_reference varchar;
    v_existing_amount bigint;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Adjustment amount must be greater than zero.';
    END IF;

    IF p_movement_type NOT IN ('CASH_IN', 'CASH_OUT') THEN
        RAISE EXCEPTION
            'Invalid adjustment movement type. Only CASH_IN or CASH_OUT is allowed.';
    END IF;

    IF p_description IS NULL OR btrim(p_description) = '' THEN
        RAISE EXCEPTION 'Adjustment description is required.';
    END IF;

    /*
     * Idempotency
     */
    IF p_idempotency_key IS NOT NULL THEN
        SELECT
            t.id,
            t.reference,
            t.amount
        INTO
            v_existing_transaction_id,
            v_existing_reference,
            v_existing_amount
        FROM public.transactions AS t
        WHERE t.tenant_id = p_tenant_id
          AND t.idempotency_key = p_idempotency_key
          AND t.transaction_type = 'TELLER_CASH_ADJUSTMENT'
        ORDER BY t.created_at DESC
        LIMIT 1;

        IF v_existing_transaction_id IS NOT NULL THEN
            RETURN QUERY
            SELECT
                v_existing_transaction_id,
                v_existing_reference,
                p_session_id,
                p_movement_type,
                v_existing_amount,
                'POSTED'::public.transaction_status,
                'Duplicate teller cash adjustment request'::text;

            RETURN;
        END IF;
    END IF;

    /*
     * Validate creator
     */
    IF p_created_by IS NOT NULL THEN
        PERFORM 1
        FROM public.users AS u
        WHERE u.id = p_created_by
          AND u.tenant_id = p_tenant_id
          AND u.is_active = true;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Created-by user is not active in this tenant.';
        END IF;
    END IF;

    /*
     * Lock teller session
     */
    SELECT
        tcs.status,
        tcs.cashbox_id
    INTO
        v_session_status,
        v_cashbox_id
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_session_id
      AND tcs.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Teller session not found.';
    END IF;

    IF v_session_status <> 'OPEN' THEN
        RAISE EXCEPTION
            'Teller session must be OPEN. Current status: %',
            v_session_status;
    END IF;

    /*
     * Resolve teller cashbox GL
     */
    SELECT
        cb.ledger_account_id
    INTO
        v_teller_ledger_id
    FROM public.cashboxes AS cb
    WHERE cb.id = v_cashbox_id
      AND cb.tenant_id = p_tenant_id
      AND cb.is_active = true;

    IF v_teller_ledger_id IS NULL THEN
        RAISE EXCEPTION
            'Teller cashbox has no active ledger account.';
    END IF;

    /*
     * Resolve main cash GL
     */
    SELECT
        la.id,
        la.current_balance
    INTO
        v_main_cash_ledger_id,
        v_main_cash_balance
    FROM public.ledger_accounts AS la
    WHERE la.tenant_id = p_tenant_id
      AND la.account_code = '1010'
      AND la.is_active = true
    FOR UPDATE;

    IF v_main_cash_ledger_id IS NULL THEN
        RAISE EXCEPTION 'Main Cash GL 1010 not found.';
    END IF;

    /*
     * Lock teller cash GL
     */
    SELECT
        la.current_balance
    INTO
        v_teller_balance
    FROM public.ledger_accounts AS la
    WHERE la.id = v_teller_ledger_id
      AND la.tenant_id = p_tenant_id
      AND la.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Teller cash GL not found.';
    END IF;

    /*
     * CASH_IN:
     *
     * Teller Cash  DEBIT
     * Main Cash    CREDIT
     */
    IF p_movement_type = 'CASH_IN' THEN

        IF v_main_cash_balance < p_amount THEN
            RAISE EXCEPTION
                'Insufficient main cash. Available: %, Requested: %',
                v_main_cash_balance,
                p_amount;
        END IF;

    /*
     * CASH_OUT:
     *
     * Main Cash    DEBIT
     * Teller Cash  CREDIT
     */
    ELSE

        IF v_teller_balance < p_amount THEN
            RAISE EXCEPTION
                'Insufficient teller cash. Available: %, Requested: %',
                v_teller_balance,
                p_amount;
        END IF;

    END IF;

    /*
     * Business date
     */
    SELECT
        bd.id
    INTO
        v_business_date_id
    FROM public.business_dates AS bd
    WHERE bd.tenant_id = p_tenant_id
      AND bd.status = 'OPEN'
    ORDER BY bd.business_date DESC
    LIMIT 1;

    IF v_business_date_id IS NULL THEN
        RAISE EXCEPTION 'No OPEN business date found.';
    END IF;

    /*
     * Accounting period
     */
    SELECT
        ap.id
    INTO
        v_accounting_period_id
    FROM public.accounting_periods AS ap
    WHERE ap.tenant_id = p_tenant_id
      AND ap.status = 'OPEN'
    ORDER BY ap.start_date DESC
    LIMIT 1;

    IF v_accounting_period_id IS NULL THEN
        RAISE EXCEPTION 'No OPEN accounting period found.';
    END IF;

    /*
     * Transaction reference
     */
    v_transaction_reference :=
        public.generate_transaction_reference('TELLER_CASH_ADJUSTMENT');

    /*
     * Create transaction
     */
    INSERT INTO public.transactions (
        tenant_id,
        reference,
        transaction_type,
        status,
        currency,
        amount,
        description,
        idempotency_key,
        posted_at,
        created_by,
        business_date_id,
        accounting_period_id,
        value_date,
        channel
    )
    VALUES (
        p_tenant_id,
        v_transaction_reference,
        'TELLER_CASH_ADJUSTMENT',
        'POSTED',
        'GHS',
        p_amount,
        p_description,
        p_idempotency_key,
        now(),
        p_created_by,
        v_business_date_id,
        v_accounting_period_id,
        CURRENT_DATE,
        'TELLER'
    )
    RETURNING public.transactions.id
    INTO v_transaction_id;

    /*
     * GL posting
     */
    IF p_movement_type = 'CASH_IN' THEN

        INSERT INTO public.transaction_entries (
            transaction_id,
            tenant_id,
            ledger_account_id,
            debit,
            credit,
            description
        )
        VALUES
        (
            v_transaction_id,
            p_tenant_id,
            v_teller_ledger_id,
            p_amount,
            0,
            p_description
        ),
        (
            v_transaction_id,
            p_tenant_id,
            v_main_cash_ledger_id,
            0,
            p_amount,
            p_description
        );

        UPDATE public.ledger_accounts AS la
        SET
            current_balance = la.current_balance + p_amount,
            updated_at = now()
        WHERE la.id = v_teller_ledger_id
          AND la.tenant_id = p_tenant_id;

        UPDATE public.ledger_accounts AS la
        SET
            current_balance = la.current_balance - p_amount,
            updated_at = now()
        WHERE la.id = v_main_cash_ledger_id
          AND la.tenant_id = p_tenant_id;

    ELSE

        INSERT INTO public.transaction_entries (
            transaction_id,
            tenant_id,
            ledger_account_id,
            debit,
            credit,
            description
        )
        VALUES
        (
            v_transaction_id,
            p_tenant_id,
            v_main_cash_ledger_id,
            p_amount,
            0,
            p_description
        ),
        (
            v_transaction_id,
            p_tenant_id,
            v_teller_ledger_id,
            0,
            p_amount,
            p_description
        );

        UPDATE public.ledger_accounts AS la
        SET
            current_balance = la.current_balance - p_amount,
            updated_at = now()
        WHERE la.id = v_teller_ledger_id
          AND la.tenant_id = p_tenant_id;

        UPDATE public.ledger_accounts AS la
        SET
            current_balance = la.current_balance + p_amount,
            updated_at = now()
        WHERE la.id = v_main_cash_ledger_id
          AND la.tenant_id = p_tenant_id;

    END IF;

    /*
     * Teller movement
     */
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
        v_cashbox_id,
        p_movement_type,
        p_amount,
        v_transaction_id,
        v_transaction_reference,
        p_description,
        p_created_by
    );

    /*
     * Audit
     */
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
        'TELLER_CASH_ADJUSTMENT_POSTED',
        'TRANSACTION',
        v_transaction_id,
        jsonb_build_object(
            'transaction_reference', v_transaction_reference,
            'session_id', p_session_id,
            'cashbox_id', v_cashbox_id,
            'movement_type', p_movement_type,
            'amount', p_amount,
            'channel', 'TELLER'
        )
    );

    RETURN QUERY
    SELECT
        v_transaction_id,
        v_transaction_reference,
        p_session_id,
        p_movement_type,
        p_amount,
        'POSTED'::public.transaction_status,
        'Teller cash adjustment posted successfully'::text;
END;
$$;

ALTER FUNCTION public.post_teller_cash_adjustment(
    uuid,
    uuid,
    public.teller_cash_movement_type,
    bigint,
    text,
    varchar,
    uuid
) OWNER TO postgres;