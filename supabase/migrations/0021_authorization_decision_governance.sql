-- ============================================================
-- 0021_authorization_decision_governance.sql
-- Authorization Decision Governance
-- ============================================================


-- ------------------------------------------------------------
-- 1. Drop the previous function because PostgreSQL does not
--    allow CREATE OR REPLACE to change a function's OUT
--    parameter / return-table structure.
-- ------------------------------------------------------------

DROP FUNCTION IF EXISTS get_authorization_decision(
    uuid,
    uuid,
    varchar,
    bigint,
    authorization_mode
);


-- ------------------------------------------------------------
-- 2. Recreate authorization decision engine
-- ------------------------------------------------------------

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
    policy_allow_self_authorization boolean,
    user_can_self_authorize boolean,
    requires_checker boolean,
    is_superuser boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_action_code varchar(100);
    v_policy authorization_policies%ROWTYPE;
    v_user_can_self_authorize boolean;
    v_is_superuser boolean;
    v_mode authorization_mode;
BEGIN

    -- --------------------------------------------------------
    -- 3. Canonicalize action
    -- --------------------------------------------------------

    v_action_code :=
        canonicalize_authorization_action(p_action_code);


    -- --------------------------------------------------------
    -- 4. Validate action exists
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM authorization_actions
        WHERE authorization_actions.action_code = v_action_code
          AND authorization_actions.is_active = true
    ) THEN
        RAISE EXCEPTION
            'Authorization action does not exist or is inactive: %',
            v_action_code;
    END IF;


    -- --------------------------------------------------------
    -- 5. Validate user belongs to tenant
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE users.id = p_user_id
          AND users.tenant_id = p_tenant_id
          AND users.is_active = true
    ) THEN
        RAISE EXCEPTION
            'User does not belong to tenant or is inactive';
    END IF;


    -- --------------------------------------------------------
    -- 6. Resolve authorization policy
    -- --------------------------------------------------------

    SELECT *
    INTO v_policy
    FROM get_authorization_policy(
        p_tenant_id,
        v_action_code,
        p_amount
    );


    -- --------------------------------------------------------
    -- 7. No policy
    --
    -- Fall back to requested mode or DIRECT.
    -- --------------------------------------------------------

    IF v_policy.id IS NULL THEN

        v_mode := COALESCE(
            p_requested_mode,
            'DIRECT'::authorization_mode
        );

        v_user_can_self_authorize :=
            user_can_self_authorize(
                p_tenant_id,
                p_user_id,
                v_action_code
            );

        v_is_superuser :=
            user_is_superuser(
                p_tenant_id,
                p_user_id
            );

        RETURN QUERY
        SELECT
            v_action_code,
            v_mode,
            false,
            false,
            (
                v_mode = 'MAKER_CHECKER'::authorization_mode
            ),
            v_is_superuser;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- 8. Determine individual user capability
    -- --------------------------------------------------------

    v_user_can_self_authorize :=
        user_can_self_authorize(
            p_tenant_id,
            p_user_id,
            v_action_code
        );


    -- --------------------------------------------------------
    -- 9. Determine Superuser status
    -- --------------------------------------------------------

    v_is_superuser :=
        user_is_superuser(
            p_tenant_id,
            p_user_id
        );


    -- --------------------------------------------------------
    -- 10. Start with tenant policy mode
    -- --------------------------------------------------------

    v_mode := v_policy.authorization_mode;


    -- --------------------------------------------------------
    -- 11. Respect explicitly requested workflow where valid
    -- --------------------------------------------------------

    IF p_requested_mode IS NOT NULL THEN

        IF p_requested_mode =
            'MAKER_CHECKER'::authorization_mode THEN

            v_mode :=
                'MAKER_CHECKER'::authorization_mode;


        ELSIF p_requested_mode =
            'DIRECT'::authorization_mode THEN

            IF v_policy.authorization_mode =
                'DIRECT'::authorization_mode THEN

                v_mode :=
                    'DIRECT'::authorization_mode;

            END IF;


        ELSIF p_requested_mode =
            'USER_CHOICE'::authorization_mode THEN

            IF v_policy.authorization_mode IN (
                'USER_CHOICE'::authorization_mode,
                'DIRECT'::authorization_mode
            ) THEN

                v_mode :=
                    'USER_CHOICE'::authorization_mode;

            END IF;

        END IF;

    END IF;


    -- --------------------------------------------------------
    -- 12. Return effective authorization decision
    --
    -- Self-authorization requires BOTH:
    --
    --   a) Policy allows self-authorization
    --   b) User is individually allowed
    --
    -- Superuser status is informational here and does not
    -- automatically grant self-authorization.
    -- --------------------------------------------------------

    RETURN QUERY
    SELECT
        v_action_code,
        v_mode,

        v_policy.allow_self_authorization,

        (
            v_policy.allow_self_authorization
            AND v_user_can_self_authorize
        ),

        (
            v_mode = 'MAKER_CHECKER'::authorization_mode
            AND NOT (
                v_policy.allow_self_authorization
                AND v_user_can_self_authorize
            )
        ),

        v_is_superuser;

END;
$$;


-- ------------------------------------------------------------
-- 13. Security
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION get_authorization_decision(
    uuid,
    uuid,
    varchar,
    bigint,
    authorization_mode
)
FROM PUBLIC;


-- ------------------------------------------------------------
-- 14. Documentation
-- ------------------------------------------------------------

COMMENT ON FUNCTION get_authorization_decision(
    uuid,
    uuid,
    varchar,
    bigint,
    authorization_mode
)
IS
'Resolves the effective authorization mode and self-authorization capability for a user and canonical authorization action.';