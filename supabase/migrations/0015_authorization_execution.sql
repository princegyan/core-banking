-- ============================================================
-- 0015_authorization_execution.sql
-- Integrate generic authorization policy with maker-checker
--
-- Rules:
--   1. Different user can approve through MAKER_CHECKER.
--   2. Maker can self-authorize only when:
--        - policy = USER_CHOICE
--        - allow_self_authorization = true
--        - user has authorization.self_authorize
--   3. SUPER_ADMIN has no automatic self-authorization bypass.
-- ============================================================


-- ============================================================
-- 1. Drop existing function
--
-- PostgreSQL cannot change the return type using
-- CREATE OR REPLACE FUNCTION.
-- ============================================================

DROP FUNCTION IF EXISTS approve_request(
    uuid,
    uuid,
    uuid,
    text
);


-- ============================================================
-- 2. Recreate approve_request()
-- ============================================================

CREATE FUNCTION approve_request(
    p_tenant_id uuid,
    p_request_id uuid,
    p_checker_id uuid,
    p_comment text DEFAULT NULL
)
RETURNS approval_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_request approval_requests;
    v_policy authorization_policies;
    v_can_self_authorize boolean := false;
    v_is_self_authorization boolean := false;
BEGIN

    -- --------------------------------------------------------
    -- Lock approval request
    -- --------------------------------------------------------

    SELECT *
    INTO v_request
    FROM approval_requests
    WHERE id = p_request_id
      AND tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Approval request not found';
    END IF;


    -- --------------------------------------------------------
    -- Request must still be pending
    -- --------------------------------------------------------

    IF v_request.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Approval request is not pending';
    END IF;


    -- --------------------------------------------------------
    -- Checker must belong to tenant and be active
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_checker_id
          AND tenant_id = p_tenant_id
          AND is_active = true
    ) THEN
        RAISE EXCEPTION
            'Checker does not belong to tenant or is inactive';
    END IF;


    -- --------------------------------------------------------
    -- Determine whether maker and checker are the same user
    -- --------------------------------------------------------

    v_is_self_authorization :=
        v_request.requested_by = p_checker_id;


    -- ========================================================
    -- SELF-AUTHORIZATION
    -- ========================================================

    IF v_is_self_authorization THEN

        -- Find applicable authorization policy
        SELECT *
        INTO v_policy
        FROM get_authorization_policy(
            p_tenant_id,
            v_request.request_type,
            NULL
        );

        -- Policy must exist
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'No authorization policy exists for action %',
                v_request.request_type;
        END IF;


        -- Policy must allow user choice
        IF v_policy.authorization_mode <> 'USER_CHOICE' THEN
            RAISE EXCEPTION
                'Self-authorization is not permitted for action %',
                v_request.request_type;
        END IF;


        -- Policy must explicitly allow self-authorization
        IF NOT v_policy.allow_self_authorization THEN
            RAISE EXCEPTION
                'Self-authorization is not permitted for action %',
                v_request.request_type;
        END IF;


        -- User must explicitly possess self-authorization privilege
        v_can_self_authorize :=
            user_has_permission(
                p_tenant_id,
                p_checker_id,
                'authorization.self_authorize'
            );


        IF NOT v_can_self_authorize THEN
            RAISE EXCEPTION
                'User does not have self-authorization permission';
        END IF;

    END IF;


    -- ========================================================
    -- NORMAL MAKER-CHECKER
    -- ========================================================

    /*
     * If maker != checker, the request follows the normal
     * maker-checker workflow.
     */


    -- --------------------------------------------------------
    -- Approve request
    -- --------------------------------------------------------

    UPDATE approval_requests
    SET
        status = 'APPROVED',
        approved_by = p_checker_id,
        approved_at = now(),
        checked_at = now(),
        checker_comment = p_comment,
        updated_at = now()
    WHERE id = p_request_id
    RETURNING *
    INTO v_request;


    -- --------------------------------------------------------
    -- Record approval history
    -- --------------------------------------------------------

    INSERT INTO approval_request_history (
        tenant_id,
        approval_request_id,
        action,
        performed_by,
        comment
    )
    VALUES (
        p_tenant_id,
        p_request_id,
        'APPROVED',
        p_checker_id,
        CASE
            WHEN v_is_self_authorization
            THEN COALESCE(p_comment, 'Self-authorized')
            ELSE p_comment
        END
    );


    RETURN v_request;

END;
$$;


ALTER FUNCTION approve_request(
    uuid,
    uuid,
    uuid,
    text
) OWNER TO postgres;


COMMENT ON FUNCTION approve_request(
    uuid,
    uuid,
    uuid,
    text
)
IS
'Approves a pending authorization request. Maker self-approval is permitted only when the applicable authorization policy is USER_CHOICE, explicitly allows self-authorization, and the user has authorization.self_authorize permission.';