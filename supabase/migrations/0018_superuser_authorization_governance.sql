-- ============================================================
-- 0018_superuser_authorization_governance.sql
--
-- Formalize institution-level Superuser capability.
--
-- Rules:
--
-- INSTITUTION_ADMIN
--     = Institution Superuser
--
-- SUPER_ADMIN
--     = Platform Superuser
--       (will be implemented separately)
--
-- This migration does NOT create SUPER_ADMIN.
-- ============================================================


-- ============================================================
-- 1. Add explicit superuser flag to roles
-- ============================================================

ALTER TABLE roles
ADD COLUMN IF NOT EXISTS is_superuser boolean
NOT NULL DEFAULT false;


COMMENT ON COLUMN roles.is_superuser IS
'Identifies whether the role represents a Superuser within its authorization scope.';


-- ============================================================
-- 2. Mark INSTITUTION_ADMIN as Superuser
-- ============================================================

UPDATE roles
SET is_superuser = true
WHERE name = 'INSTITUTION_ADMIN'
  AND tenant_id = '669d95bb-167c-483d-b652-898bb1e78ac7';


-- ============================================================
-- 3. Ensure authorization policy management permission exists
-- ============================================================

INSERT INTO permissions (
    code,
    description
)
VALUES (
    'authorization.manage_policies',
    'Create, update and manage authorization policies'
)
ON CONFLICT (code) DO NOTHING;


-- ============================================================
-- 4. Grant policy management to INSTITUTION_ADMIN
-- ============================================================

INSERT INTO role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM roles r
CROSS JOIN permissions p
WHERE r.name = 'INSTITUTION_ADMIN'
  AND r.tenant_id = '669d95bb-167c-483d-b652-898bb1e78ac7'
  AND p.code = 'authorization.manage_policies'
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ============================================================
-- 5. Ensure INSTITUTION_ADMIN retains self-authorization
-- ============================================================

INSERT INTO role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM roles r
CROSS JOIN permissions p
WHERE r.name = 'INSTITUTION_ADMIN'
  AND r.tenant_id = '669d95bb-167c-483d-b652-898bb1e78ac7'
  AND p.code = 'authorization.self_authorize'
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ============================================================
-- 6. Verification safeguards
-- ============================================================

DO $$
DECLARE
    v_is_superuser boolean;
    v_policy_permission boolean;
    v_self_authorize_permission boolean;
BEGIN

    SELECT is_superuser
    INTO v_is_superuser
    FROM roles
    WHERE name = 'INSTITUTION_ADMIN'
      AND tenant_id = '669d95bb-167c-483d-b652-898bb1e78ac7';

    IF COALESCE(v_is_superuser, false) = false THEN
        RAISE EXCEPTION
            'INSTITUTION_ADMIN was not configured as a Superuser';
    END IF;


    SELECT EXISTS (
        SELECT 1
        FROM role_permissions rp
        JOIN roles r
            ON r.id = rp.role_id
        JOIN permissions p
            ON p.id = rp.permission_id
        WHERE r.name = 'INSTITUTION_ADMIN'
          AND r.tenant_id = '669d95bb-167c-483d-b652-898bb1e78ac7'
          AND p.code = 'authorization.manage_policies'
    )
    INTO v_policy_permission;


    IF NOT v_policy_permission THEN
        RAISE EXCEPTION
            'INSTITUTION_ADMIN does not have authorization.manage_policies';
    END IF;


    SELECT EXISTS (
        SELECT 1
        FROM role_permissions rp
        JOIN roles r
            ON r.id = rp.role_id
        JOIN permissions p
            ON p.id = rp.permission_id
        WHERE r.name = 'INSTITUTION_ADMIN'
          AND r.tenant_id = '669d95bb-167c-483d-b652-898bb1e78ac7'
          AND p.code = 'authorization.self_authorize'
    )
    INTO v_self_authorize_permission;


    IF NOT v_self_authorize_permission THEN
        RAISE EXCEPTION
            'INSTITUTION_ADMIN does not have authorization.self_authorize';
    END IF;

END;
$$;