-- ============================================================
-- 0014_generic_authorization_framework.sql
-- Generic authorization framework
--
-- Supports:
--   DIRECT
--   MAKER_CHECKER
--   USER_CHOICE
--
-- Self-authorization is an explicit privilege.
-- SUPER_ADMIN does NOT automatically receive it.
-- ============================================================


-- ============================================================
-- 1. Authorization mode
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'authorization_mode'
    ) THEN
        CREATE TYPE authorization_mode AS ENUM (
            'DIRECT',
            'MAKER_CHECKER',
            'USER_CHOICE'
        );
    END IF;
END
$$;


-- ============================================================
-- 2. Authorization policies
-- ============================================================

CREATE TABLE IF NOT EXISTS authorization_policies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL
        REFERENCES tenants(id)
        ON DELETE CASCADE,

    action_code varchar(100) NOT NULL,

    authorization_mode authorization_mode NOT NULL
        DEFAULT 'DIRECT',

    allow_self_authorization boolean NOT NULL
        DEFAULT false,

    minimum_amount bigint,
    maximum_amount bigint,

    is_active boolean NOT NULL
        DEFAULT true,

    created_at timestamptz NOT NULL
        DEFAULT now(),

    updated_at timestamptz NOT NULL
        DEFAULT now(),

    CONSTRAINT authorization_policies_amount_check
        CHECK (
            (minimum_amount IS NULL OR minimum_amount >= 0)
            AND
            (maximum_amount IS NULL OR maximum_amount >= 0)
            AND
            (
                minimum_amount IS NULL
                OR maximum_amount IS NULL
                OR minimum_amount <= maximum_amount
            )
        ),

    CONSTRAINT authorization_policies_self_auth_check
        CHECK (
            allow_self_authorization = false
            OR authorization_mode = 'USER_CHOICE'
        ),

    CONSTRAINT authorization_policies_unique_action_range
        UNIQUE (
            tenant_id,
            action_code,
            minimum_amount,
            maximum_amount
        )
);


CREATE INDEX IF NOT EXISTS idx_authorization_policies_tenant
    ON authorization_policies(tenant_id);

CREATE INDEX IF NOT EXISTS idx_authorization_policies_action
    ON authorization_policies(
        tenant_id,
        action_code,
        is_active
    );


-- ============================================================
-- 3. Updated-at trigger
-- ============================================================

DROP TRIGGER IF EXISTS trg_authorization_policies_updated_at
ON authorization_policies;

CREATE TRIGGER trg_authorization_policies_updated_at
BEFORE UPDATE ON authorization_policies
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 4. Authorization permissions
-- ============================================================

INSERT INTO permissions (
    code,
    description
)
VALUES
(
    'authorization.self_authorize',
    'Authorize an action created by the same user when policy permits self-authorization'
),
(
    'authorization.manage_policies',
    'Create, update and manage authorization policies'
)
ON CONFLICT (code) DO NOTHING;


-- ============================================================
-- 5. Generic authorization policy lookup
-- ============================================================

CREATE OR REPLACE FUNCTION get_authorization_policy(
    p_tenant_id uuid,
    p_action_code varchar,
    p_amount bigint DEFAULT NULL
)
RETURNS authorization_policies
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_policy authorization_policies;
BEGIN

    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Tenant ID is required';
    END IF;

    IF p_action_code IS NULL
       OR trim(p_action_code) = '' THEN
        RAISE EXCEPTION 'Action code is required';
    END IF;

    IF p_amount IS NOT NULL AND p_amount < 0 THEN
        RAISE EXCEPTION 'Amount cannot be negative';
    END IF;

    /*
     * Find the most specific matching policy.
     *
     * A policy with amount boundaries takes precedence over
     * a general policy where both boundaries are NULL.
     */

    SELECT ap.*
    INTO v_policy
    FROM authorization_policies ap
    WHERE ap.tenant_id = p_tenant_id
      AND ap.action_code = p_action_code
      AND ap.is_active = true
      AND (
          p_amount IS NULL
          OR (
              (ap.minimum_amount IS NULL OR p_amount >= ap.minimum_amount)
              AND
              (ap.maximum_amount IS NULL OR p_amount <= ap.maximum_amount)
          )
      )
    ORDER BY
        CASE
            WHEN ap.minimum_amount IS NOT NULL
              OR ap.maximum_amount IS NOT NULL
            THEN 0
            ELSE 1
        END,
        ap.minimum_amount DESC NULLS LAST,
        ap.maximum_amount ASC NULLS LAST
    LIMIT 1;

    RETURN v_policy;

END;
$$;

ALTER FUNCTION get_authorization_policy(
    uuid,
    varchar,
    bigint
) OWNER TO postgres;


-- ============================================================
-- 6. Check whether a user has a permission
-- ============================================================

CREATE OR REPLACE FUNCTION user_has_permission(
    p_tenant_id uuid,
    p_user_id uuid,
    p_permission_code varchar
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    RETURN EXISTS (
        SELECT 1
        FROM users u
        JOIN user_roles ur
            ON ur.user_id = u.id
        JOIN roles r
            ON r.id = ur.role_id
        JOIN role_permissions rp
            ON rp.role_id = r.id
        JOIN permissions p
            ON p.id = rp.permission_id
        WHERE u.id = p_user_id
          AND u.tenant_id = p_tenant_id
          AND u.is_active = true
          AND p.code = p_permission_code
          AND (
              r.tenant_id = p_tenant_id
              OR r.tenant_id IS NULL
          )
    );

END;
$$;

ALTER FUNCTION user_has_permission(
    uuid,
    uuid,
    varchar
) OWNER TO postgres;


-- ============================================================
-- 7. Generic authorization decision
--
-- Returns:
--
--   DIRECT
--   MAKER_CHECKER
--   SELF_AUTHORIZATION
--   MAKER_CHECKER_OR_SELF
--
-- This function does NOT execute the action.
-- It only determines how the action must be authorized.
-- ============================================================

CREATE OR REPLACE FUNCTION get_authorization_decision(
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

    -- User must belong to tenant
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


    -- Get applicable policy
    SELECT *
    INTO v_policy
    FROM get_authorization_policy(
        p_tenant_id,
        p_action_code,
        p_amount
    );


    -- No policy means DIRECT
    IF NOT FOUND THEN

        RETURN QUERY
        SELECT
            p_action_code,
            'DIRECT'::authorization_mode,
            false,
            false;

        RETURN;

    END IF;


    -- Check explicit self-authorization privilege
    v_can_self :=
        v_policy.allow_self_authorization
        AND
        user_has_permission(
            p_tenant_id,
            p_user_id,
            'authorization.self_authorize'
        );


    /*
     * USER_CHOICE:
     *
     * The user may choose self-authorization or maker-checker,
     * provided they have the explicit self-authorization
     * permission.
     */

    IF v_policy.authorization_mode = 'USER_CHOICE' THEN

        RETURN QUERY
        SELECT
            v_policy.action_code,
            CASE
                WHEN p_requested_mode = 'SELF_AUTHORIZATION'
                     AND v_can_self
                THEN 'SELF_AUTHORIZATION'::authorization_mode

                ELSE 'MAKER_CHECKER'::authorization_mode
            END,
            v_policy.allow_self_authorization,
            v_can_self;

        RETURN;

    END IF;


    -- DIRECT
    IF v_policy.authorization_mode = 'DIRECT' THEN

        RETURN QUERY
        SELECT
            v_policy.action_code,
            'DIRECT'::authorization_mode,
            v_policy.allow_self_authorization,
            v_can_self;

        RETURN;

    END IF;


    -- MAKER_CHECKER
    RETURN QUERY
    SELECT
        v_policy.action_code,
        'MAKER_CHECKER'::authorization_mode,
        v_policy.allow_self_authorization,
        v_can_self;

END;
$$;

ALTER FUNCTION get_authorization_decision(
    uuid,
    uuid,
    varchar,
    bigint,
    authorization_mode
) OWNER TO postgres;


-- ============================================================
-- 8. Seed initial policies
--
-- Keep the existing system conservative:
-- critical actions default to MAKER_CHECKER.
-- No self-authorization is enabled yet.
-- ============================================================

INSERT INTO authorization_policies (
    tenant_id,
    action_code,
    authorization_mode,
    allow_self_authorization
)
VALUES
(
    '669d95bb-167c-483d-b652-898bb1e78ac7',
    'ACCOUNT_CLOSE',
    'MAKER_CHECKER',
    false
),
(
    '669d95bb-167c-483d-b652-898bb1e78ac7',
    'ACCOUNT_FREEZE',
    'MAKER_CHECKER',
    false
),
(
    '669d95bb-167c-483d-b652-898bb1e78ac7',
    'ACCOUNT_UNFREEZE',
    'MAKER_CHECKER',
    false
),
(
    '669d95bb-167c-483d-b652-898bb1e78ac7',
    'TRANSACTION_REVERSE',
    'MAKER_CHECKER',
    false
),
(
    '669d95bb-167c-483d-b652-898bb1e78ac7',
    'LOAN_APPROVE',
    'MAKER_CHECKER',
    false
),
(
    '669d95bb-167c-483d-b652-898bb1e78ac7',
    'LOAN_DISBURSE',
    'MAKER_CHECKER',
    false
),
(
    '669d95bb-167c-483d-b652-898bb1e78ac7',
    'USER_ROLE_CHANGE',
    'MAKER_CHECKER',
    false
),
(
    '669d95bb-167c-483d-b652-898bb1e78ac7',
    'GL_CONFIGURATION_CHANGE',
    'MAKER_CHECKER',
    false
)
ON CONFLICT (
    tenant_id,
    action_code,
    minimum_amount,
    maximum_amount
) DO NOTHING;


-- ============================================================
-- 9. Grant self-authorization privilege explicitly
--
-- DO NOT automatically grant this to SUPER_ADMIN.
--
-- We intentionally leave this unassigned.
-- The institution can explicitly assign:
--
--   authorization.self_authorize
--
-- to a role later.
-- ============================================================


-- ============================================================
-- 10. Enable RLS
--
-- Backend currently operates through controlled service-role
-- access. RLS is defense-in-depth and will be expanded with
-- proper tenant-aware policies as the security layer matures.
-- ============================================================

ALTER TABLE authorization_policies ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 11. Verification comments
-- ============================================================

COMMENT ON TABLE authorization_policies IS
'Generic tenant-level authorization policies controlling whether actions are direct, maker-checker, or user-choice.';

COMMENT ON COLUMN authorization_policies.action_code IS
'Generic business action identifier, independent of a specific module.';

COMMENT ON COLUMN authorization_policies.authorization_mode IS
'Authorization workflow: DIRECT, MAKER_CHECKER, or USER_CHOICE.';

COMMENT ON COLUMN authorization_policies.allow_self_authorization IS
'Explicit policy-level permission allowing a user with authorization.self_authorize to self-authorize an action.';