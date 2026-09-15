-- ============================================================
-- 0016_fix_authorization_decision.sql
--
-- Fixes get_authorization_decision()
--
-- authorization_mode represents the POLICY mode:
--   DIRECT
--   MAKER_CHECKER
--   USER_CHOICE
--
-- Self-authorization is a decision within USER_CHOICE,
-- not an authorization_mode enum value.
-- ============================================================


DROP FUNCTION IF EXISTS get_authorization_decision(
    uuid,
    uuid,
    varchar,
    bigint,
    authorization_mode
);


CREATE FUNCTION get_authorization_decision(
    p_tenant_id uuid,
    p_user_id uuid,
    p_action_code varchar,
    p_amount bigint DEFAULT NULL,
    p_requested_mode authorization_mode DEFAULT NULL
)
RETURNS TABLE (
    action_code varchar,
    authorization_mode authorization_mode,
    allow_self_authorization boolean,
    user_can_self_authorize boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_policy authorization_policies;
    v_can_self boolean := false;
BEGIN

    -- --------------------------------------------------------
    -- Validate user
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
          AND tenant_id = p_tenant_id
          AND is_active = true
    ) THEN
        RAISE EXCEPTION
            'User does not belong to tenant or is inactive';
    END IF;


    -- --------------------------------------------------------
    -- Get applicable policy
    -- --------------------------------------------------------

    SELECT *
    INTO v_policy
    FROM get_authorization_policy(
        p_tenant_id,
        p_action_code,
        p_amount
    );


    -- --------------------------------------------------------
    -- No policy = DIRECT
    -- --------------------------------------------------------

    IF NOT FOUND THEN

        RETURN QUERY
        SELECT
            p_action_code,
            'DIRECT'::authorization_mode,
            false,
            false;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- Determine whether user has self-authorization privilege
    -- --------------------------------------------------------

    v_can_self :=
        v_policy.authorization_mode = 'USER_CHOICE'
        AND v_policy.allow_self_authorization
        AND user_has_permission(
            p_tenant_id,
            p_user_id,
            'authorization.self_authorize'
        );


    -- --------------------------------------------------------
    -- USER_CHOICE
    --
    -- The policy allows the user to choose the workflow.
    --
    -- We return USER_CHOICE as the policy mode and expose
    -- user_can_self_authorize separately.
    -- --------------------------------------------------------

    IF v_policy.authorization_mode = 'USER_CHOICE' THEN

        RETURN QUERY
        SELECT
            v_policy.action_code,
            'USER_CHOICE'::authorization_mode,
            v_policy.allow_self_authorization,
            v_can_self;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- DIRECT
    -- --------------------------------------------------------

    IF v_policy.authorization_mode = 'DIRECT' THEN

        RETURN QUERY
        SELECT
            v_policy.action_code,
            'DIRECT'::authorization_mode,
            v_policy.allow_self_authorization,
            false;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- MAKER_CHECKER
    -- --------------------------------------------------------

    RETURN QUERY
    SELECT
        v_policy.action_code,
        'MAKER_CHECKER'::authorization_mode,
        v_policy.allow_self_authorization,
        false;

END;
$$;


ALTER FUNCTION get_authorization_decision(
    uuid,
    uuid,
    varchar,
    bigint,
    authorization_mode
) OWNER TO postgres;


COMMENT ON FUNCTION get_authorization_decision(
    uuid,
    uuid,
    varchar,
    bigint,
    authorization_mode
)
IS
'Returns the applicable authorization policy and whether the requesting user has explicit self-authorization capability. USER_CHOICE represents a policy mode; self-authorization is exposed through user_can_self_authorize rather than authorization_mode.';