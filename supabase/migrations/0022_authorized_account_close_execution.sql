-- ============================================================
-- 0022_authorized_account_close_execution.sql
-- Authorized Account Closure Execution
-- ============================================================

-- ============================================================
-- 1. Execute an account closure after authorization has been
--    resolved.
--
-- Behavior:
--
-- DIRECT
--   -> closes account immediately
--
-- USER_CHOICE + self-authorized
--   -> closes account immediately
--
-- USER_CHOICE + not self-authorized
--   -> creates approval request
--
-- MAKER_CHECKER
--   -> creates approval request
--
-- No financial balance movement occurs when an approval
-- request is created.
-- ============================================================

CREATE OR REPLACE FUNCTION execute_authorized_account_close(
    p_tenant_id uuid,
    p_account_id uuid,
    p_requested_by uuid,
    p_comment text DEFAULT NULL
)
RETURNS TABLE (
    result_status varchar,
    account_id uuid,
    authorization_mode authorization_mode,
    self_authorized boolean,
    approval_request_id uuid,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_account accounts%ROWTYPE;

    v_decision RECORD;

    v_request approval_requests%ROWTYPE;

    v_comment text;
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
    -- 2. Lock account
    -- --------------------------------------------------------

    SELECT *
    INTO v_account
    FROM accounts
    WHERE id = p_account_id
      AND tenant_id = p_tenant_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Account not found for tenant';
    END IF;


    -- --------------------------------------------------------
    -- 3. Validate current account status
    -- --------------------------------------------------------

    IF v_account.status = 'CLOSED' THEN

        RETURN QUERY
        SELECT
            'ALREADY_CLOSED'::varchar,
            v_account.id,
            'DIRECT'::authorization_mode,
            false,
            NULL::uuid,
            'Account is already closed'::text;

        RETURN;

    END IF;


    IF v_account.status NOT IN (
        'ACTIVE',
        'FROZEN',
        'DORMANT'
    ) THEN

        RAISE EXCEPTION
            'Account cannot be closed from status %',
            v_account.status;

    END IF;


    -- --------------------------------------------------------
    -- 4. Account must have zero balances before closure
    -- --------------------------------------------------------

    IF v_account.ledger_balance <> 0
       OR v_account.available_balance <> 0 THEN

        RAISE EXCEPTION
            'Account cannot be closed while balance is not zero. Ledger: %, Available: %',
            v_account.ledger_balance,
            v_account.available_balance;

    END IF;


    -- --------------------------------------------------------
    -- 5. Resolve authorization decision
    -- --------------------------------------------------------

    SELECT *
    INTO v_decision
    FROM get_authorization_decision(
        p_tenant_id,
        p_requested_by,
        'ACCOUNT_CLOSE',
        NULL,
        NULL
    );


    -- --------------------------------------------------------
    -- 6. Direct authorization
    -- --------------------------------------------------------

    IF v_decision.authorization_mode =
        'DIRECT'::authorization_mode THEN

        UPDATE accounts
        SET
            status = 'CLOSED',
            closed_at = now(),
            updated_at = now()
        WHERE id = v_account.id
          AND tenant_id = p_tenant_id;

        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            v_account.id,
            v_decision.authorization_mode,
            false,
            NULL::uuid,
            'Account closed successfully'::text;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- 7. User-choice with permitted self-authorization
    -- --------------------------------------------------------

    IF v_decision.authorization_mode =
        'USER_CHOICE'::authorization_mode
       AND v_decision.user_can_self_authorize = true
       AND v_decision.policy_allow_self_authorization = true THEN

        UPDATE accounts
        SET
            status = 'CLOSED',
            closed_at = now(),
            updated_at = now()
        WHERE id = v_account.id
          AND tenant_id = p_tenant_id;

        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            v_account.id,
            v_decision.authorization_mode,
            true,
            NULL::uuid,
            'Account closed through self-authorization'::text;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- 8. All other authorization modes require approval.
    --
    -- USER_CHOICE without self-authorization
    -- MAKER_CHECKER
    --
    -- No account mutation occurs here.
    -- --------------------------------------------------------

    v_comment := NULLIF(
        btrim(COALESCE(p_comment, '')),
        ''
    );


    SELECT *
    INTO v_request
    FROM create_approval_request(
        p_tenant_id,
        'ACCOUNT_CLOSE',
        'ACCOUNT',
        v_account.id,
        p_requested_by,
        v_comment
    );


    RETURN QUERY
    SELECT
        'PENDING_APPROVAL'::varchar,
        v_account.id,
        v_decision.authorization_mode,
        false,
        v_request.id,
        'Account closure requires authorization'::text;

END;
$$;


-- ============================================================
-- 2. Security
-- ============================================================

REVOKE ALL
ON FUNCTION execute_authorized_account_close(
    uuid,
    uuid,
    uuid,
    text
)
FROM PUBLIC;


-- ============================================================
-- 3. Documentation
-- ============================================================

COMMENT ON FUNCTION execute_authorized_account_close(
    uuid,
    uuid,
    uuid,
    text
)
IS
'Executes or submits an account closure according to the tenant authorization policy and the requesting user''s individual authorization capability.';