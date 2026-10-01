CREATE OR REPLACE FUNCTION public.close_teller_session(
    p_tenant_id uuid,
    p_session_id uuid,
    p_actual_closing_balance bigint,
    p_closing_notes text DEFAULT NULL,
    p_closed_by uuid DEFAULT NULL
)
RETURNS TABLE (
    session_id uuid,
    status public.teller_session_status,
    expected_closing_balance bigint,
    actual_closing_balance bigint,
    variance bigint,
    closed_at timestamptz,
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

    v_opening_balance bigint;
    v_expected_balance bigint;
    v_variance bigint;

    v_closed_at timestamptz;
BEGIN
    IF p_actual_closing_balance IS NULL
       OR p_actual_closing_balance < 0 THEN
        RAISE EXCEPTION
            'Actual closing cash cannot be negative.';
    END IF;

    /*
     * Lock session
     */
    SELECT
        tcs.status,
        tcs.cashbox_id,
        tcs.teller_user_id,
        tcs.opening_balance
    INTO
        v_session_status,
        v_cashbox_id,
        v_teller_user_id,
        v_opening_balance
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_session_id
      AND tcs.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Teller session not found.';
    END IF;

    IF v_session_status <> 'OPEN' THEN
        RAISE EXCEPTION
            'Only an OPEN teller session can be closed. Current status: %',
            v_session_status;
    END IF;

    /*
     * Validate closing user
     */
    IF p_closed_by IS NOT NULL THEN
        PERFORM 1
        FROM public.users AS u
        WHERE u.id = p_closed_by
          AND u.tenant_id = p_tenant_id
          AND u.is_active = true;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Closing user is not active in this tenant.';
        END IF;

        IF p_closed_by <> v_teller_user_id THEN
            RAISE EXCEPTION
                'User is not the teller assigned to this session.';
        END IF;
    END IF;

    /*
     * Expected closing balance
     *
     * Opening
     * + CASH_IN
     * + TRANSFER_IN
     * + DEPOSIT
     * - CASH_OUT
     * - TRANSFER_OUT
     * - WITHDRAWAL
     */
    SELECT
        v_opening_balance
        + COALESCE(
            SUM(
                CASE
                    WHEN tcm.movement_type IN (
                        'CASH_IN',
                        'TRANSFER_IN',
                        'DEPOSIT'
                    )
                    THEN tcm.amount

                    WHEN tcm.movement_type IN (
                        'CASH_OUT',
                        'TRANSFER_OUT',
                        'WITHDRAWAL'
                    )
                    THEN -tcm.amount

                    ELSE 0
                END
            ),
            0
        )
    INTO
        v_expected_balance
    FROM public.teller_cash_movements AS tcm
    WHERE tcm.session_id = p_session_id
      AND tcm.tenant_id = p_tenant_id
      AND tcm.movement_type <> 'OPENING';

    /*
     * Calculate variance
     */
    v_variance :=
        p_actual_closing_balance - v_expected_balance;

    /*
     * Close session
     */
    v_closed_at := now();

    UPDATE public.teller_cash_sessions AS tcs
    SET
        status = 'CLOSED',
        closed_at = v_closed_at,
        expected_closing_balance = v_expected_balance,
        actual_closing_balance = p_actual_closing_balance,
        variance = v_variance,
        closing_notes = p_closing_notes,
        updated_at = now()
    WHERE tcs.id = p_session_id
      AND tcs.tenant_id = p_tenant_id;

    /*
     * Closing movement
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
        'CLOSING',
        p_actual_closing_balance,
        NULL,
        NULL,
        COALESCE(
            p_closing_notes,
            'Teller session closing'
        ),
        p_closed_by
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
        p_closed_by,
        'TELLER_SESSION_CLOSED',
        'TELLER_SESSION',
        p_session_id,
        jsonb_build_object(
            'cashbox_id', v_cashbox_id,
            'expected_closing_balance', v_expected_balance,
            'actual_closing_balance', p_actual_closing_balance,
            'variance', v_variance,
            'closing_notes', p_closing_notes
        )
    );

    RETURN QUERY
    SELECT
        p_session_id,
        'CLOSED'::public.teller_session_status,
        v_expected_balance,
        p_actual_closing_balance,
        v_variance,
        v_closed_at,
        'Teller session closed successfully'::text;
END;
$$;

ALTER FUNCTION public.close_teller_session(
    uuid,
    uuid,
    bigint,
    text,
    uuid
) OWNER TO postgres;