-- ============================================================
-- 16.12 Teller Controls & Final Hardening
-- ============================================================

/*
 * 1. Prevent duplicate OPENING movements per session.
 */
CREATE UNIQUE INDEX IF NOT EXISTS uq_teller_opening_movement
ON public.teller_cash_movements (session_id)
WHERE movement_type = 'OPENING';


/*
 * 2. Prevent duplicate CLOSING movements per session.
 */
CREATE UNIQUE INDEX IF NOT EXISTS uq_teller_closing_movement
ON public.teller_cash_movements (session_id)
WHERE movement_type = 'CLOSING';


/*
 * 3. Prevent the same transaction from being linked
 *    to multiple teller movements of the same session.
 */
CREATE UNIQUE INDEX IF NOT EXISTS uq_teller_transaction_movement
ON public.teller_cash_movements (
    session_id,
    transaction_id
)
WHERE transaction_id IS NOT NULL;


/*
 * 4. Additional amount protection.
 */
ALTER TABLE public.teller_cash_movements
DROP CONSTRAINT IF EXISTS teller_cash_movements_amount_check;

ALTER TABLE public.teller_cash_movements
ADD CONSTRAINT teller_cash_movements_amount_check
CHECK (amount > 0);


/*
 * 5. Teller session balance protection.
 */
ALTER TABLE public.teller_cash_sessions
DROP CONSTRAINT IF EXISTS teller_cash_sessions_opening_balance_check;

ALTER TABLE public.teller_cash_sessions
ADD CONSTRAINT teller_cash_sessions_opening_balance_check
CHECK (opening_balance >= 0);

ALTER TABLE public.teller_cash_sessions
DROP CONSTRAINT IF EXISTS teller_cash_sessions_expected_balance_check;

ALTER TABLE public.teller_cash_sessions
ADD CONSTRAINT teller_cash_sessions_expected_balance_check
CHECK (
    expected_closing_balance IS NULL
    OR expected_closing_balance >= 0
);

ALTER TABLE public.teller_cash_sessions
DROP CONSTRAINT IF EXISTS teller_cash_sessions_actual_balance_check;

ALTER TABLE public.teller_cash_sessions
ADD CONSTRAINT teller_cash_sessions_actual_balance_check
CHECK (
    actual_closing_balance IS NULL
    OR actual_closing_balance >= 0
);


/*
 * 6. Integrity checker.
 *
 * This does not modify financial data.
 * It checks whether the teller session's stored values,
 * movement history and cashbox GL agree.
 */
CREATE OR REPLACE FUNCTION public.check_teller_session_integrity(
    p_tenant_id uuid,
    p_session_id uuid
)
RETURNS TABLE (
    session_id uuid,
    session_status public.teller_session_status,
    expected_cash bigint,
    actual_cash bigint,
    cashbox_gl_balance bigint,
    movement_balance bigint,
    physical_variance bigint,
    gl_variance bigint,
    integrity_ok boolean,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_status public.teller_session_status;
    v_cashbox_id uuid;
    v_opening_balance bigint;
    v_expected_closing bigint;
    v_actual_closing bigint;
    v_cashbox_gl_id uuid;
    v_gl_balance bigint;
    v_movement_balance bigint;

    v_physical_variance bigint;
    v_gl_variance bigint;
    v_integrity_ok boolean;
BEGIN
    /*
     * Read session.
     */
    SELECT
        tcs.status,
        tcs.cashbox_id,
        tcs.opening_balance,
        tcs.expected_closing_balance,
        tcs.actual_closing_balance
    INTO
        v_status,
        v_cashbox_id,
        v_opening_balance,
        v_expected_closing,
        v_actual_closing
    FROM public.teller_cash_sessions AS tcs
    WHERE tcs.id = p_session_id
      AND tcs.tenant_id = p_tenant_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Teller session not found.';
    END IF;

    /*
     * Recalculate movement balance.
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
        v_movement_balance
    FROM public.teller_cash_movements AS tcm
    WHERE tcm.session_id = p_session_id
      AND tcm.tenant_id = p_tenant_id
      AND tcm.movement_type NOT IN ('OPENING', 'CLOSING');

    /*
     * Resolve cashbox GL.
     */
    SELECT
        cb.ledger_account_id
    INTO
        v_cashbox_gl_id
    FROM public.cashboxes AS cb
    WHERE cb.id = v_cashbox_id
      AND cb.tenant_id = p_tenant_id;

    IF v_cashbox_gl_id IS NULL THEN
        RAISE EXCEPTION 'Cashbox ledger account not found.';
    END IF;

    /*
     * Read GL balance.
     */
    SELECT
        la.current_balance
    INTO
        v_gl_balance
    FROM public.ledger_accounts AS la
    WHERE la.id = v_cashbox_gl_id
      AND la.tenant_id = p_tenant_id;

    IF v_gl_balance IS NULL THEN
        RAISE EXCEPTION 'Cashbox GL balance not found.';
    END IF;

    /*
     * For a closed session, actual cash must exist.
     */
    IF v_status = 'CLOSED'
       AND v_actual_closing IS NULL THEN
        RAISE EXCEPTION
            'Closed teller session has no actual closing balance.';
    END IF;

    /*
     * Physical variance.
     */
    IF v_actual_closing IS NOT NULL THEN
        v_physical_variance :=
            v_actual_closing - v_movement_balance;
    ELSE
        v_physical_variance := NULL;
    END IF;

    /*
     * GL variance.
     */
    IF v_actual_closing IS NOT NULL THEN
        v_gl_variance :=
            v_actual_closing - v_gl_balance;
    ELSE
        v_gl_variance := NULL;
    END IF;

    /*
     * Integrity result.
     */
    v_integrity_ok :=
        (
            (
                v_status <> 'CLOSED'
                AND v_movement_balance >= 0
            )
            OR
            (
                v_status = 'CLOSED'
                AND v_actual_closing IS NOT NULL
                AND v_physical_variance = 0
                AND v_gl_variance = 0
                AND (
                    v_expected_closing IS NULL
                    OR v_expected_closing = v_movement_balance
                )
            )
        );

    RETURN QUERY
    SELECT
        p_session_id,
        v_status,
        v_movement_balance,
        v_actual_closing,
        v_gl_balance,
        v_movement_balance,
        v_physical_variance,
        v_gl_variance,
        v_integrity_ok,
        CASE
            WHEN v_integrity_ok
                THEN 'Teller session integrity check passed'
            ELSE 'Teller session integrity check detected a variance'
        END;
END;
$$;

ALTER FUNCTION public.check_teller_session_integrity(
    uuid,
    uuid
) OWNER TO postgres;

