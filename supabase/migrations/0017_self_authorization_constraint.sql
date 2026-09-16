-- ============================================================
-- 0017_self_authorization_constraint.sql
--
-- Integrate self-authorization with approval_requests.
--
-- The original 0013 constraint prevented:
--
--     requested_by = approved_by
--
-- We now allow this only when the request explicitly records
-- that self-authorization was used.
-- ============================================================


-- ============================================================
-- 1. Add self-authorization indicator
-- ============================================================

ALTER TABLE approval_requests
ADD COLUMN IF NOT EXISTS self_authorized boolean
NOT NULL DEFAULT false;


-- ============================================================
-- 2. Replace old maker/checker constraint
-- ============================================================

ALTER TABLE approval_requests
DROP CONSTRAINT IF EXISTS approval_requests_checker_not_maker;


-- ============================================================
-- 3. Add new consistency constraint
--
-- If self_authorized = true:
--     maker and checker MUST be the same user.
--
-- If self_authorized = false:
--     maker and checker MUST be different users.
-- ============================================================

ALTER TABLE approval_requests
ADD CONSTRAINT approval_requests_checker_consistency
CHECK (
    approved_by IS NULL
    OR
    (
        self_authorized = true
        AND approved_by = requested_by
    )
    OR
    (
        self_authorized = false
        AND approved_by <> requested_by
    )
);


-- ============================================================
-- 4. Replace approve_request()
-- ============================================================

DROP FUNCTION IF EXISTS approve_request(
    uuid,
    uuid,
    uuid,
    text
);


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
    -- Lock request
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
    -- Request must be pending
    -- --------------------------------------------------------

    IF v_request.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Approval request is not pending';
    END IF;


    -- --------------------------------------------------------
    -- Approver must be active tenant user
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
    -- Determine maker/checker relationship
    -- --------------------------------------------------------

    v_is_self_authorization :=
        v_request.requested_by = p_checker_id;


    -- ========================================================
    -- SELF-AUTHORIZATION
    -- ========================================================

    IF v_is_self_authorization THEN

        SELECT *
        INTO v_policy
        FROM get_authorization_policy(
            p_tenant_id,
            v_request.request_type,
            NULL
        );


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'No authorization policy exists for action %',
                v_request.request_type;
        END IF;


        -- Self-authorization requires USER_CHOICE
        IF v_policy.authorization_mode <> 'USER_CHOICE' THEN
            RAISE EXCEPTION
                'Self-authorization is not permitted for action %',
                v_request.request_type;
        END IF;


        -- Policy must explicitly allow it
        IF NOT v_policy.allow_self_authorization THEN
            RAISE EXCEPTION
                'Self-authorization is not permitted for action %',
                v_request.request_type;
        END IF;


        -- User must have explicit permission
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
    -- APPROVE
    -- ========================================================

    UPDATE approval_requests
    SET
        status = 'APPROVED',
        approved_by = p_checker_id,
        approved_at = now(),
        checked_at = now(),
        checker_comment = p_comment,
        self_authorized = v_is_self_authorization,
        updated_at = now()
    WHERE id = p_request_id
    RETURNING *
    INTO v_request;


    -- ========================================================
    -- HISTORY
    -- ========================================================

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
            THEN COALESCE(
                p_comment,
                'Self-authorized'
            )
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


COMMENT ON COLUMN approval_requests.self_authorized IS
'Indicates that the maker approved their own request using the explicit self-authorization policy and permission.';


COMMENT ON CONSTRAINT approval_requests_checker_consistency
ON approval_requests
IS
'Ensures maker and checker are different for normal maker-checker approval, or identical only when self_authorized is true.';