-- ============================================================
-- 16.9.1 Teller-to-Teller Cash Transfer
-- ============================================================

CREATE OR REPLACE FUNCTION public.post_teller_cash_transfer(
    p_tenant_id uuid,
    p_source_session_id uuid,
    p_destination_session_id uuid,
    p_amount bigint,
    p_description text DEFAULT NULL,
    p_idempotency_key varchar DEFAULT NULL,
    p_created_by uuid DEFAULT NULL
)
RETURNS TABLE (
    transaction_id uuid,
    transaction_reference varchar,
    source_session_id uuid,
    destination_session_id uuid,
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
    v_business_date_id uuid;
    v_accounting_period_id uuid;

    v_source_cashbox_id uuid;
    v_destination_cashbox_id uuid;

    v_source_ledger_id uuid;
    v_destination_ledger_id uuid;

    v_source_balance bigint;
    v_destination_balance bigint;

    v_source_status public.teller_session_status;
    v_destination_status public.teller_session_status;

    v_existing_transaction_id uuid;
    v_existing_reference varchar;
    v_existing_amount bigint;

    v_source_user_id uuid;
    v_destination_user_id uuid;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Cash transfer amount must be greater than zero.';
    END IF;

    IF p_source_session_id = p_destination_session_id THEN
        RAISE EXCEPTION
            'Source and destination teller sessions must be different.';
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
          AND t.transaction_type = 'TELLER_CASH_TRANSFER'
        ORDER BY t.created_at DESC
        LIMIT 1;

        IF v_existing_transaction_id IS NOT NULL THEN
            RETURN QUERY
            SELECT
                v_existing_transaction_id,
                v_existing_reference,
                p_source_session_id,
                p_destination_session_id,
                v_existing_amount,
                'POSTED'::public.transaction_status,
                'Duplicate teller cash transfer request'::text;

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
     * Lock source session
     */
    SELECT
        tcs.status,
        tcs.cashbox_id,
        tcs.teller_user_id
    INTO
        v_source_status,
        v_source_cashbox_id,
        v_source_user_id
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_source_session_id
      AND tcs.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source teller session not found.';
    END IF;

    /*
     * Lock destination session
     */
    SELECT
        tcs.status,
        tcs.cashbox_id,
        tcs.teller_user_id
    INTO
        v_destination_status,
        v_destination_cashbox_id,
        v_destination_user_id
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_destination_session_id
      AND tcs.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Destination teller session not found.';
    END IF;

    IF v_source_status <> 'OPEN' THEN
        RAISE EXCEPTION
            'Source teller session must be OPEN. Current status: %',
            v_source_status;
    END IF;

    IF v_destination_status <> 'OPEN' THEN
        RAISE EXCEPTION
            'Destination teller session must be OPEN. Current status: %',
            v_destination_status;
    END IF;

    IF v_source_cashbox_id = v_destination_cashbox_id THEN
        RAISE EXCEPTION
            'Source and destination cashboxes must be different.';
    END IF;

    /*
     * Creator must belong to source session.
     */
    IF p_created_by IS NOT NULL
       AND v_source_user_id <> p_created_by THEN
        RAISE EXCEPTION
            'User is not the teller assigned to the source session.';
    END IF;

    /*
     * Resolve cashbox GLs
     */
    SELECT
        cb.ledger_account_id
    INTO
        v_source_ledger_id
    FROM public.cashboxes AS cb
    WHERE cb.id = v_source_cashbox_id
      AND cb.tenant_id = p_tenant_id
      AND cb.is_active = true;

    IF v_source_ledger_id IS NULL THEN
        RAISE EXCEPTION
            'Source cashbox has no active ledger account.';
    END IF;

    SELECT
        cb.ledger_account_id
    INTO
        v_destination_ledger_id
    FROM public.cashboxes AS cb
    WHERE cb.id = v_destination_cashbox_id
      AND cb.tenant_id = p_tenant_id
      AND cb.is_active = true;

    IF v_destination_ledger_id IS NULL THEN
        RAISE EXCEPTION
            'Destination cashbox has no active ledger account.';
    END IF;

    /*
     * Lock source GL
     */
    SELECT
        la.current_balance
    INTO
        v_source_balance
    FROM public.ledger_accounts AS la
    WHERE la.id = v_source_ledger_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source cashbox ledger account not found.';
    END IF;

    /*
     * Lock destination GL
     */
    SELECT
        la.current_balance
    INTO
        v_destination_balance
    FROM public.ledger_accounts AS la
    WHERE la.id = v_destination_ledger_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Destination cashbox ledger account not found.';
    END IF;

    /*
     * Source must have enough physical cash.
     */
    IF v_source_balance < p_amount THEN
        RAISE EXCEPTION
            'Insufficient source teller cash. Available: %, Requested: %',
            v_source_balance,
            p_amount;
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
     * Generate reference
     */
    v_transaction_reference :=
        public.generate_transaction_reference('TELLER_CASH_TRANSFER');

    /*
     * Transaction
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
        'TELLER_CASH_TRANSFER',
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
     * GL:
     *
     * Destination Teller Cash = DEBIT
     * Source Teller Cash      = CREDIT
     */
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
        v_destination_ledger_id,
        p_amount,
        0,
        COALESCE(p_description, 'Teller cash transfer in')
    ),
    (
        v_transaction_id,
        p_tenant_id,
        v_source_ledger_id,
        0,
        p_amount,
        COALESCE(p_description, 'Teller cash transfer out')
    );

    /*
     * Update source cashbox
     */
    UPDATE public.ledger_accounts AS la
    SET
        current_balance = la.current_balance - p_amount,
        updated_at = now()
    WHERE la.id = v_source_ledger_id
      AND la.tenant_id = p_tenant_id;

    /*
     * Update destination cashbox
     */
    UPDATE public.ledger_accounts AS la
    SET
        current_balance = la.current_balance + p_amount,
        updated_at = now()
    WHERE la.id = v_destination_ledger_id
      AND la.tenant_id = p_tenant_id;

    /*
     * SOURCE movement
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
        p_source_session_id,
        v_source_cashbox_id,
        'TRANSFER_OUT',
        p_amount,
        v_transaction_id,
        v_transaction_reference,
        p_description,
        p_created_by
    );

    /*
     * DESTINATION movement
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
        p_destination_session_id,
        v_destination_cashbox_id,
        'TRANSFER_IN',
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
        'TELLER_CASH_TRANSFER_POSTED',
        'TRANSACTION',
        v_transaction_id,
        jsonb_build_object(
            'transaction_reference', v_transaction_reference,
            'source_session_id', p_source_session_id,
            'destination_session_id', p_destination_session_id,
            'source_cashbox_id', v_source_cashbox_id,
            'destination_cashbox_id', v_destination_cashbox_id,
            'amount', p_amount,
            'channel', 'TELLER'
        )
    );

    RETURN QUERY
    SELECT
        v_transaction_id,
        v_transaction_reference,
        p_source_session_id,
        p_destination_session_id,
        p_amount,
        'POSTED'::public.transaction_status,
        'Teller cash transfer posted successfully'::text;
END;
$$;

ALTER FUNCTION public.post_teller_cash_transfer(
    uuid,
    uuid,
    uuid,
    bigint,
    text,
    varchar,
    uuid
) OWNER TO postgres;