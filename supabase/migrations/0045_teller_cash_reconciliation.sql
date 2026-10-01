CREATE OR REPLACE FUNCTION public.reconcile_teller_session(
    p_tenant_id uuid,
    p_session_id uuid,
    p_reconciled_by uuid DEFAULT NULL
)
RETURNS TABLE (
    session_id uuid,
    status text,
    expected_cash bigint,
    actual_cash bigint,
    physical_variance bigint,
    gl_cash_balance bigint,
    gl_variance bigint,
    reconciled boolean,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_session_status public.teller_session_status;
    v_cashbox_id uuid;
    v_teller_user_id uuid;
    v_ledger_account_id uuid;

    v_opening_balance bigint;
    v_expected_cash bigint;
    v_actual_cash bigint;
    v_physical_variance bigint;
    v_gl_cash_balance bigint;
    v_gl_variance bigint;

    v_reconciled boolean;
    v_business_date_id uuid;
BEGIN
    /*
     * Lock the session.
     */
    SELECT
        tcs.status,
        tcs.cashbox_id,
        tcs.teller_user_id,
        tcs.opening_balance,
        tcs.expected_closing_balance,
        tcs.actual_closing_balance
    INTO
        v_session_status,
        v_cashbox_id,
        v_teller_user_id,
        v_opening_balance,
        v_expected_cash,
        v_actual_cash
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_session_id
      AND tcs.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Teller session not found.';
    END IF;

    IF v_session_status <> 'CLOSED' THEN
        RAISE EXCEPTION
            'Only a CLOSED teller session can be reconciled. Current status: %',
            v_session_status;
    END IF;

    /*
     * Validate reconciler.
     */
    IF p_reconciled_by IS NOT NULL THEN
        PERFORM 1
        FROM public.users AS u
        WHERE u.id = p_reconciled_by
          AND u.tenant_id = p_tenant_id
          AND u.is_active = true;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Reconciliation user is not active in this tenant.';
        END IF;
    END IF;

    /*
     * Recalculate expected cash from movements.
     *
     * Opening
     * + deposits
     * + cash-in
     * + transfer-in
     * - withdrawals
     * - cash-out
     * - transfer-out
     */
    SELECT
        v_opening_balance
        + COALESCE(
            SUM(
                CASE
                    WHEN tcm.movement_type IN (
                        'DEPOSIT',
                        'CASH_IN',
                        'TRANSFER_IN'
                    )
                    THEN tcm.amount

                    WHEN tcm.movement_type IN (
                        'WITHDRAWAL',
                        'CASH_OUT',
                        'TRANSFER_OUT'
                    )
                    THEN -tcm.amount

                    ELSE 0
                END
            ),
            0
        )
    INTO
        v_expected_cash
    FROM public.teller_cash_movements AS tcm
    WHERE tcm.session_id = p_session_id
      AND tcm.tenant_id = p_tenant_id
      AND tcm.movement_type <> 'OPENING'
      AND tcm.movement_type <> 'CLOSING';

    /*
     * Actual physical cash.
     */
    SELECT
        tcs.actual_closing_balance
    INTO
        v_actual_cash
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_session_id
      AND tcs.tenant_id = p_tenant_id;

    IF v_actual_cash IS NULL THEN
        RAISE EXCEPTION
            'Actual closing cash has not been recorded.';
    END IF;

    /*
     * Physical variance.
     */
    v_physical_variance :=
        v_actual_cash - v_expected_cash;

    /*
     * Resolve cashbox GL.
     */
    SELECT
        cb.ledger_account_id
    INTO
        v_ledger_account_id
    FROM public.cashboxes AS cb
    WHERE cb.id = v_cashbox_id
      AND cb.tenant_id = p_tenant_id
      AND cb.is_active = true;

    IF v_ledger_account_id IS NULL THEN
        RAISE EXCEPTION
            'Cashbox has no active ledger account.';
    END IF;

    /*
     * Read GL balance.
     */
    SELECT
        la.current_balance
    INTO
        v_gl_cash_balance
    FROM public.ledger_accounts AS la
    WHERE la.id = v_ledger_account_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Teller cash GL account not found.';
    END IF;

    /*
     * GL variance compares physical closing cash
     * against the current teller GL balance.
     */
    v_gl_variance :=
        v_actual_cash - v_gl_cash_balance;

    v_reconciled :=
        v_physical_variance = 0
        AND v_gl_variance = 0;

    /*
     * Current business date for audit context.
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

    /*
     * Audit result.
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
        p_reconciled_by,
        CASE
            WHEN v_reconciled
                THEN 'TELLER_SESSION_RECONCILED'
            ELSE 'TELLER_SESSION_VARIANCE'
        END,
        'TELLER_SESSION',
        p_session_id,
        jsonb_build_object(
            'cashbox_id', v_cashbox_id,
            'expected_cash', v_expected_cash,
            'actual_cash', v_actual_cash,
            'physical_variance', v_physical_variance,
            'gl_cash_balance', v_gl_cash_balance,
            'gl_variance', v_gl_variance,
            'reconciled', v_reconciled,
            'business_date_id', v_business_date_id
        )
    );

    RETURN QUERY
    SELECT
        p_session_id,
        CASE
            WHEN v_reconciled THEN 'RECONCILED'
            ELSE 'VARIANCE'
        END,
        v_expected_cash,
        v_actual_cash,
        v_physical_variance,
        v_gl_cash_balance,
        v_gl_variance,
        v_reconciled,
        CASE
            WHEN v_reconciled
                THEN 'Teller session reconciled successfully'
            ELSE 'Teller session has a cash variance'
        END;
END;
$$;

ALTER FUNCTION public.reconcile_teller_session(
    uuid,
    uuid,
    uuid
) OWNER TO postgres;