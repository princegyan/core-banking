-- =========================================================
-- MIGRATION 0028
-- Reversal Authorization Entry Hardening
-- =========================================================

DROP FUNCTION IF EXISTS public.execute_authorized_transaction_reversal(
    uuid,
    uuid,
    uuid,
    text
);

CREATE OR REPLACE FUNCTION public.execute_authorized_transaction_reversal(
    p_tenant_id uuid,
    p_transaction_id uuid,
    p_requested_by uuid,
    p_comment text DEFAULT NULL
)
RETURNS TABLE(
    result_status varchar,
    transaction_id uuid,
    authorization_mode authorization_mode,
    self_authorized boolean,
    approval_request_id uuid,
    reversal_transaction_id uuid,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_transaction transactions%ROWTYPE;
    v_decision RECORD;
    v_request approval_requests%ROWTYPE;
    v_posted record;
BEGIN

    -- --------------------------------------------------------
    -- 1. Validate requester
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_requested_by
          AND tenant_id = p_tenant_id
          AND is_active = true
    ) THEN
        RAISE EXCEPTION
            'Requester does not belong to tenant or is inactive';
    END IF;


    -- --------------------------------------------------------
    -- 2. Validate transaction and lock it
    -- --------------------------------------------------------

    SELECT *
    INTO v_transaction
    FROM transactions
    WHERE id = p_transaction_id
      AND tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Transaction not found for tenant';
    END IF;


    -- --------------------------------------------------------
    -- 3. Transaction must be POSTED
    -- --------------------------------------------------------

    IF v_transaction.status <> 'POSTED' THEN
        RAISE EXCEPTION
            'Only POSTED transactions can be submitted for reversal. Current status: %',
            v_transaction.status;
    END IF;


    -- --------------------------------------------------------
    -- 4. Reversal eligibility gate
    --
    -- IMPORTANT:
    -- Invalid reversal requests must be rejected BEFORE
    -- authorization or approval-request creation.
    -- --------------------------------------------------------

    IF v_transaction.transaction_type = 'WITHDRAWAL' THEN
        RAISE EXCEPTION
            'Withdrawal transactions cannot be reversed. Process a new deposit instead';
    END IF;


    IF v_transaction.transaction_type = 'REVERSAL' THEN
        RAISE EXCEPTION
            'Reversal transactions cannot be reversed';
    END IF;


    IF v_transaction.transaction_type <> 'DEPOSIT' THEN
        RAISE EXCEPTION
            'Transaction type % is not currently eligible for reversal',
            v_transaction.transaction_type;
    END IF;


    -- --------------------------------------------------------
    -- 5. Resolve authorization
    -- --------------------------------------------------------

    SELECT *
    INTO v_decision
    FROM get_authorization_decision(
        p_tenant_id,
        p_requested_by,
        'TRANSACTION_REVERSE',
        v_transaction.amount,
        NULL
    );


    -- --------------------------------------------------------
    -- 6. Direct execution
    -- --------------------------------------------------------

    IF v_decision.authorization_mode =
        'DIRECT'::authorization_mode THEN

        SELECT *
        INTO v_posted
        FROM post_transaction_reversal(
            p_tenant_id,
            p_transaction_id,
            p_requested_by,
            p_comment,
            NULL
        );

        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            p_transaction_id,
            v_decision.authorization_mode,
            false,
            NULL::uuid,
            v_posted.reversal_transaction_id,
            'Transaction reversed successfully'::text;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- 7. User-choice self-authorization
    -- --------------------------------------------------------

    IF v_decision.authorization_mode =
        'USER_CHOICE'::authorization_mode
       AND v_decision.policy_allow_self_authorization = true
       AND v_decision.user_can_self_authorize = true THEN

        SELECT *
        INTO v_posted
        FROM post_transaction_reversal(
            p_tenant_id,
            p_transaction_id,
            p_requested_by,
            p_comment,
            NULL
        );

        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            p_transaction_id,
            v_decision.authorization_mode,
            true,
            NULL::uuid,
            v_posted.reversal_transaction_id,
            'Transaction reversed through self-authorization'::text;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- 8. Approval required
    -- --------------------------------------------------------

    SELECT *
    INTO v_request
    FROM create_approval_request(
        p_tenant_id,
        'TRANSACTION_REVERSE',
        'TRANSACTION',
        p_transaction_id,
        p_requested_by,
        p_comment
    );


    RETURN QUERY
    SELECT
        'PENDING_APPROVAL'::varchar,
        p_transaction_id,
        v_decision.authorization_mode,
        false,
        v_request.id,
        NULL::uuid,
        'Transaction reversal requires authorization'::text;

END;
$function$;