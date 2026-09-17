-- ============================================================
-- 0020_user_authorization_governance.sql
-- Per-User Authorization Governance
-- ============================================================

-- ------------------------------------------------------------
-- 1. User authorization settings
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS user_authorization_settings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL
        REFERENCES tenants(id)
        ON DELETE CASCADE,

    user_id uuid NOT NULL
        REFERENCES users(id)
        ON DELETE CASCADE,

    action_code varchar(100) NOT NULL
        REFERENCES authorization_actions(action_code)
        ON DELETE RESTRICT,

    allow_self_authorization boolean NOT NULL DEFAULT false,

    created_by uuid
        REFERENCES users(id)
        ON DELETE SET NULL,

    updated_by uuid
        REFERENCES users(id)
        ON DELETE SET NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_authorization_settings_unique
        UNIQUE (tenant_id, user_id, action_code)
);

-- ------------------------------------------------------------
-- 2. Indexes
-- ------------------------------------------------------------

CREATE INDEX IF NOT EXISTS
    idx_user_authorization_settings_user
ON user_authorization_settings (
    tenant_id,
    user_id
);

CREATE INDEX IF NOT EXISTS
    idx_user_authorization_settings_action
ON user_authorization_settings (
    tenant_id,
    action_code
);

CREATE INDEX IF NOT EXISTS
    idx_user_authorization_settings_self_auth
ON user_authorization_settings (
    tenant_id,
    user_id,
    allow_self_authorization
);

-- ------------------------------------------------------------
-- 3. Updated-at trigger
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS
    trg_user_authorization_settings_updated_at
ON user_authorization_settings;

CREATE TRIGGER
    trg_user_authorization_settings_updated_at
BEFORE UPDATE ON user_authorization_settings
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

-- ------------------------------------------------------------
-- 4. Tenant/user/action integrity validation
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION
validate_user_authorization_setting_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_tenant_id uuid;
BEGIN

    SELECT tenant_id
    INTO v_user_tenant_id
    FROM users
    WHERE id = NEW.user_id;

    IF v_user_tenant_id IS NULL THEN
        RAISE EXCEPTION
            'User % does not exist or has no tenant',
            NEW.user_id;
    END IF;

    IF v_user_tenant_id <> NEW.tenant_id THEN
        RAISE EXCEPTION
            'User % does not belong to tenant %',
            NEW.user_id,
            NEW.tenant_id;
    END IF;

    IF NEW.created_by IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM users
            WHERE id = NEW.created_by
              AND tenant_id = NEW.tenant_id
        ) THEN
            RAISE EXCEPTION
                'created_by user does not belong to tenant %',
                NEW.tenant_id;
        END IF;

    END IF;

    IF NEW.updated_by IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM users
            WHERE id = NEW.updated_by
              AND tenant_id = NEW.tenant_id
        ) THEN
            RAISE EXCEPTION
                'updated_by user does not belong to tenant %',
                NEW.tenant_id;
        END IF;

    END IF;

    RETURN NEW;

END;
$$;

DROP TRIGGER IF EXISTS
    trg_validate_user_authorization_setting_tenant
ON user_authorization_settings;

CREATE TRIGGER
    trg_validate_user_authorization_setting_tenant
BEFORE INSERT OR UPDATE
ON user_authorization_settings
FOR EACH ROW
EXECUTE FUNCTION
validate_user_authorization_setting_tenant();

-- ------------------------------------------------------------
-- 5. Helper:
--    Determine whether a specific user may self-authorize
--    a specific action.
--
-- Explicit user setting takes precedence.
-- If no user-specific setting exists, fall back to the
-- existing role permission.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION
user_can_self_authorize(
    p_tenant_id uuid,
    p_user_id uuid,
    p_action_code varchar
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_action_code varchar(100);
    v_setting boolean;
BEGIN

    v_action_code :=
        canonicalize_authorization_action(p_action_code);

    -- --------------------------------------------------------
    -- Verify user belongs to tenant
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
          AND tenant_id = p_tenant_id
          AND is_active = true
    ) THEN
        RETURN false;
    END IF;

    -- --------------------------------------------------------
    -- Explicit per-user setting
    -- --------------------------------------------------------

    SELECT allow_self_authorization
    INTO v_setting
    FROM user_authorization_settings
    WHERE tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND action_code = v_action_code;

    IF FOUND THEN
        RETURN v_setting;
    END IF;

    -- --------------------------------------------------------
    -- Backward-compatible fallback:
    -- user must have authorization.self_authorize permission
    -- --------------------------------------------------------

    RETURN user_has_permission(
        p_tenant_id,
        p_user_id,
        'authorization.self_authorize'
    );

END;
$$;

-- ------------------------------------------------------------
-- 6. Superuser helper
--
-- A user is considered a tenant Superuser if they hold an
-- active role marked is_superuser = true.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION
user_is_superuser(
    p_tenant_id uuid,
    p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM user_roles ur
        JOIN roles r
            ON r.id = ur.role_id
        WHERE ur.user_id = p_user_id
          AND r.tenant_id = p_tenant_id
          AND r.is_superuser = true
          AND r.is_system_role = true
    );
$$;

-- ------------------------------------------------------------
-- 7. Grant/revoke individual self-authorization capability
--
-- Only a Superuser may execute these functions.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION
set_user_self_authorization(
    p_tenant_id uuid,
    p_user_id uuid,
    p_action_code varchar,
    p_allow boolean,
    p_changed_by uuid
)
RETURNS user_authorization_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_action_code varchar(100);
    v_result user_authorization_settings;
BEGIN

    v_action_code :=
        canonicalize_authorization_action(p_action_code);

    -- --------------------------------------------------------
    -- Verify the administrator making the change
    -- --------------------------------------------------------

    IF NOT user_is_superuser(
        p_tenant_id,
        p_changed_by
    ) THEN
        RAISE EXCEPTION
            'Only a Superuser may change user self-authorization settings';
    END IF;

    -- --------------------------------------------------------
    -- Verify target user belongs to tenant
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
          AND tenant_id = p_tenant_id
    ) THEN
        RAISE EXCEPTION
            'Target user does not belong to tenant %',
            p_tenant_id;
    END IF;

    -- --------------------------------------------------------
    -- Upsert user authorization setting
    -- --------------------------------------------------------

    INSERT INTO user_authorization_settings (
        tenant_id,
        user_id,
        action_code,
        allow_self_authorization,
        created_by,
        updated_by
    )
    VALUES (
        p_tenant_id,
        p_user_id,
        v_action_code,
        p_allow,
        p_changed_by,
        p_changed_by
    )
    ON CONFLICT (
        tenant_id,
        user_id,
        action_code
    )
    DO UPDATE SET
        allow_self_authorization =
            EXCLUDED.allow_self_authorization,
        updated_by =
            EXCLUDED.updated_by,
        updated_at =
            now()
    RETURNING *
    INTO v_result;

    RETURN v_result;

END;
$$;

-- ------------------------------------------------------------
-- 8. Revoke function execution from PUBLIC
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION user_can_self_authorize(uuid, uuid, varchar)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION user_is_superuser(uuid, uuid)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION set_user_self_authorization(
    uuid,
    uuid,
    varchar,
    boolean,
    uuid
)
FROM PUBLIC;

-- ------------------------------------------------------------
-- 9. RLS
-- ------------------------------------------------------------

ALTER TABLE user_authorization_settings
ENABLE ROW LEVEL SECURITY;

-- Backend uses SECURITY DEFINER functions for changes.
-- Direct writes are intentionally not exposed through RLS.

DROP POLICY IF EXISTS
    user_authorization_settings_read
ON user_authorization_settings;

CREATE POLICY
    user_authorization_settings_read
ON user_authorization_settings
FOR SELECT
USING (true);

-- ------------------------------------------------------------
-- 10. Comments
-- ------------------------------------------------------------

COMMENT ON TABLE user_authorization_settings IS
'Per-user authorization governance. Allows a tenant Superuser to explicitly allow or deny self-authorization for individual actions.';

COMMENT ON COLUMN user_authorization_settings.allow_self_authorization IS
'Explicit per-user self-authorization setting. When present, this overrides the role-level self-authorization permission for the specified action.';

COMMENT ON FUNCTION user_can_self_authorize(uuid, uuid, varchar) IS
'Determines whether a specific user may self-authorize a specific canonical authorization action.';

COMMENT ON FUNCTION user_is_superuser(uuid, uuid) IS
'Determines whether a user holds an active Superuser role within a tenant.';

COMMENT ON FUNCTION set_user_self_authorization(uuid, uuid, varchar, boolean, uuid) IS
'Allows a tenant Superuser to grant or revoke self-authorization for a specific user and action.';