CREATE OR REPLACE FUNCTION public.post_teller_cash_withdrawal(
    p_tenant_id uuid,
    p_session_id uuid,
    p_account_id uuid,
    p_amount bigint,
    p_description text DEFAULT NULL,
    p_idempotency_key varchar DEFAULT NULL,
    p_created_by uuid DEFAULT NULL
)
RETURNS TABLE (
    transaction_id uuid,
    transaction_reference varchar,
    account_id uuid,
    session_id uuid,
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
    v_customer_ledger_id uuid;
    v_teller_ledger_id uuid;
    v_existing_transaction_id uuid;
    v_existing_reference varchar;
    v_existing_amount bigint;
    v_account_balance bigint;
    v_available_balance bigint;
    v_teller_balance bigint;
    v_account_currency varchar;
    v_teller_currency varchar;
    v_account_status public.account_status;
    v_session_status public.teller_session_status;
    v_transaction_amount bigint;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Withdrawal amount must be greater than zero.';
    END IF;

    /*
     * Idempotency check
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
          AND t.transaction_type = 'WITHDRAWAL'
        ORDER BY t.created_at DESC
        LIMIT 1;

        IF v_existing_transaction_id IS NOT NULL THEN
            RETURN QUERY
            SELECT
                v_existing_transaction_id,
                v_existing_reference,
                p_account_id,
                p_session_id,
                v_existing_amount,
                'POSTED'::public.transaction_status,
                'Duplicate teller withdrawal request'::text;
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
            RAISE EXCEPTION 'Created-by user is not active in this tenant.';
        END IF;
    END IF;

    /*
     * Lock teller session
     */
    SELECT
        tcs.status
    INTO
        v_session_status
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
     * Ensure creator owns the teller session
     */
    IF p_created_by IS NOT NULL THEN
        PERFORM 1
        FROM public.teller_cash_sessions AS tcs
        WHERE tcs.id = p_session_id
          AND tcs.teller_user_id = p_created_by;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'User is not the teller assigned to this session.';
        END IF;
    END IF;

    /*
     * Lock and validate customer account
     */
    SELECT
        a.status,
        a.currency,
        a.ledger_balance,
        a.available_balance,
        a.ledger_account_id
    INTO
        v_account_status,
        v_account_currency,
        v_account_balance,
        v_available_balance,
        v_customer_ledger_id
    FROM public.accounts AS a
    WHERE a.id = p_account_id
      AND a.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Customer account not found.';
    END IF;

    IF v_account_status <> 'ACTIVE' THEN
        RAISE EXCEPTION
            'Customer account must be ACTIVE. Current status: %',
            v_account_status;
    END IF;

    IF v_account_currency <> 'GHS' THEN
        RAISE EXCEPTION
            'Teller withdrawal currently supports GHS accounts only.';
    END IF;

    IF v_customer_ledger_id IS NULL THEN
        RAISE EXCEPTION 'Customer account has no linked ledger account.';
    END IF;

    IF v_available_balance < p_amount
       OR v_account_balance < p_amount THEN
        RAISE EXCEPTION
            'Insufficient available balance. Available: %, Requested: %',
            v_available_balance,
            p_amount;
    END IF;

    /*
     * Get teller cashbox GL
     */
    SELECT
        cb.ledger_account_id
    INTO
        v_teller_ledger_id
    FROM public.cashboxes AS cb
    WHERE cb.id = (
        SELECT tcs.cashbox_id
        FROM public.teller_cash_sessions AS tcs
        WHERE tcs.id = p_session_id
    )
      AND cb.tenant_id = p_tenant_id
      AND cb.is_active = true;

    IF v_teller_ledger_id IS NULL THEN
        RAISE EXCEPTION 'Teller cashbox has no active ledger account.';
    END IF;

    /*
     * Lock both GL accounts
     */
    PERFORM 1
    FROM public.ledger_accounts AS la
    WHERE la.id = v_customer_ledger_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;

    PERFORM 1
    FROM public.ledger_accounts AS la
    WHERE la.id = v_teller_ledger_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;

    /*
     * Verify teller cash balance
     */
    SELECT
        la.current_balance,
        la.currency
    INTO
        v_teller_balance,
        v_teller_currency
    FROM public.ledger_accounts AS la
    WHERE la.id = v_teller_ledger_id
      AND la.tenant_id = p_tenant_id;

    IF v_teller_currency <> 'GHS' THEN
        RAISE EXCEPTION 'Teller cashbox GL must use GHS.';
    END IF;

    IF v_teller_balance < p_amount THEN
        RAISE EXCEPTION
            'Insufficient teller cash. Available: %, Requested: %',
            v_teller_balance,
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
     * Generate transaction reference
     */
    v_transaction_reference :=
        public.generate_transaction_reference('WITHDRAWAL');

    v_transaction_amount := p_amount;

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
        'WITHDRAWAL',
        'POSTED',
        'GHS',
        v_transaction_amount,
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
     * Customer liability DEBIT
     * Teller cash ASSET CREDIT
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
        v_customer_ledger_id,
        p_amount,
        0,
        COALESCE(p_description, 'Teller cash withdrawal')
    ),
    (
        v_transaction_id,
        p_tenant_id,
        v_teller_ledger_id,
        0,
        p_amount,
        COALESCE(p_description, 'Teller cash withdrawal')
    );

    /*
     * Update customer ledger
     */
    UPDATE public.ledger_accounts AS la
    SET
        current_balance = la.current_balance - p_amount,
        updated_at = now()
    WHERE la.id = v_customer_ledger_id
      AND la.tenant_id = p_tenant_id;

    /*
     * Update teller cash ledger
     */
    UPDATE public.ledger_accounts AS la
    SET
        current_balance = la.current_balance - p_amount,
        updated_at = now()
    WHERE la.id = v_teller_ledger_id
      AND la.tenant_id = p_tenant_id;

    /*
     * Update customer account balances
     */
    UPDATE public.accounts AS a
    SET
        ledger_balance = a.ledger_balance - p_amount,
        available_balance = a.available_balance - p_amount,
        updated_at = now()
    WHERE a.id = p_account_id
      AND a.tenant_id = p_tenant_id;

    /*
     * Record teller movement
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
    SELECT
        p_tenant_id,
        p_session_id,
        tcs.cashbox_id,
        'WITHDRAWAL',
        p_amount,
        v_transaction_id,
        v_transaction_reference,
        p_description,
        p_created_by
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_session_id;

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
        'TELLER_CASH_WITHDRAWAL_POSTED',
        'TRANSACTION',
        v_transaction_id,
        jsonb_build_object(
            'transaction_reference', v_transaction_reference,
            'account_id', p_account_id,
            'session_id', p_session_id,
            'amount', p_amount,
            'channel', 'TELLER'
        )
    );

    RETURN QUERY
    SELECT
        v_transaction_id,
        v_transaction_reference,
        p_account_id,
        p_session_id,
        p_amount,
        'POSTED'::public.transaction_status,
        'Teller cash withdrawal posted successfully'::text;
END;
$$;

ALTER FUNCTION public.post_teller_cash_withdrawal(
    uuid,
    uuid,
    uuid,
    bigint,
    text,
    varchar,
    uuid
) OWNER TO postgres;