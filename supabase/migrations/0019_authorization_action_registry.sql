-- ============================================================
-- 0019_authorization_action_registry.sql
-- Canonical Authorization Action Registry
-- ============================================================

-- ------------------------------------------------------------
-- 1. Authorization action registry
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS authorization_actions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    action_code varchar(100) NOT NULL,
    action_name varchar(150) NOT NULL,
    description text,
    module varchar(100),

    is_active boolean NOT NULL DEFAULT true,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT authorization_actions_code_unique
        UNIQUE (action_code)
);

CREATE INDEX IF NOT EXISTS idx_authorization_actions_module
    ON authorization_actions(module);

CREATE INDEX IF NOT EXISTS idx_authorization_actions_active
    ON authorization_actions(is_active);


-- ------------------------------------------------------------
-- 2. Updated-at trigger
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_authorization_actions_updated_at
    ON authorization_actions;

CREATE TRIGGER trg_authorization_actions_updated_at
BEFORE UPDATE ON authorization_actions
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();


-- ------------------------------------------------------------
-- 3. Seed canonical authorization actions
-- ------------------------------------------------------------

INSERT INTO authorization_actions (
    action_code,
    action_name,
    description,
    module
)
VALUES
(
    'ACCOUNT_CLOSE',
    'Close Account',
    'Authorize closing a customer account.',
    'ACCOUNTS'
),
(
    'ACCOUNT_FREEZE',
    'Freeze Account',
    'Authorize freezing a customer account.',
    'ACCOUNTS'
),
(
    'ACCOUNT_UNFREEZE',
    'Unfreeze Account',
    'Authorize unfreezing a customer account.',
    'ACCOUNTS'
),
(
    'TRANSACTION_REVERSE',
    'Reverse Transaction',
    'Authorize reversal of a posted financial transaction.',
    'TRANSACTIONS'
),
(
    'LOAN_APPROVE',
    'Approve Loan',
    'Authorize approval of a loan application.',
    'LOANS'
),
(
    'LOAN_DISBURSE',
    'Disburse Loan',
    'Authorize loan disbursement.',
    'LOANS'
),
(
    'USER_ROLE_CHANGE',
    'Change User Role',
    'Authorize changing a user role or permissions.',
    'USERS'
),
(
    'GL_CONFIGURATION_CHANGE',
    'Change GL Configuration',
    'Authorize changes to general ledger configuration.',
    'ACCOUNTING'
)
ON CONFLICT (action_code) DO UPDATE
SET
    action_name = EXCLUDED.action_name,
    description = EXCLUDED.description,
    module = EXCLUDED.module,
    is_active = true;


-- ------------------------------------------------------------
-- 4. Add canonical action_code to approval requests
--
-- request_type is retained for historical compatibility.
-- New authorization logic will use action_code.
-- ------------------------------------------------------------

ALTER TABLE approval_requests
ADD COLUMN IF NOT EXISTS action_code varchar(100);


-- ------------------------------------------------------------
-- 5. Backfill existing approval requests
--
-- Preserve historical request_type values.
-- Map ACCOUNT_CLOSURE to canonical ACCOUNT_CLOSE.
-- ------------------------------------------------------------

UPDATE approval_requests
SET action_code =
    CASE
        WHEN request_type = 'ACCOUNT_CLOSURE'
            THEN 'ACCOUNT_CLOSE'
        ELSE request_type
    END
WHERE action_code IS NULL;


-- ------------------------------------------------------------
-- 6. Validate that all existing action codes are registered
-- ------------------------------------------------------------

DO $$
DECLARE
    v_unknown_action varchar(100);
BEGIN

    SELECT ar.action_code
    INTO v_unknown_action
    FROM approval_requests ar
    LEFT JOIN authorization_actions aa
        ON aa.action_code = ar.action_code
    WHERE aa.id IS NULL
    LIMIT 1;

    IF v_unknown_action IS NOT NULL THEN
        RAISE EXCEPTION
            'Unknown authorization action code found: %',
            v_unknown_action;
    END IF;

END $$;


-- ------------------------------------------------------------
-- 7. Make action_code mandatory
-- ------------------------------------------------------------

ALTER TABLE approval_requests
ALTER COLUMN action_code SET NOT NULL;


-- ------------------------------------------------------------
-- 8. Foreign key to canonical action registry
-- ------------------------------------------------------------

ALTER TABLE approval_requests
DROP CONSTRAINT IF EXISTS approval_requests_action_code_fkey;

ALTER TABLE approval_requests
ADD CONSTRAINT approval_requests_action_code_fkey
FOREIGN KEY (action_code)
REFERENCES authorization_actions(action_code);


-- ------------------------------------------------------------
-- 9. Ensure authorization policies use registered actions
-- ------------------------------------------------------------

DO $$
DECLARE
    v_unknown_action varchar(100);
BEGIN

    SELECT ap.action_code
    INTO v_unknown_action
    FROM authorization_policies ap
    LEFT JOIN authorization_actions aa
        ON aa.action_code = ap.action_code
    WHERE aa.id IS NULL
    LIMIT 1;

    IF v_unknown_action IS NOT NULL THEN
        RAISE EXCEPTION
            'Unknown authorization policy action code found: %',
            v_unknown_action;
    END IF;

END $$;


ALTER TABLE authorization_policies
DROP CONSTRAINT IF EXISTS authorization_policies_action_code_fkey;

ALTER TABLE authorization_policies
ADD CONSTRAINT authorization_policies_action_code_fkey
FOREIGN KEY (action_code)
REFERENCES authorization_actions(action_code);


-- ------------------------------------------------------------
-- 10. Index approval requests by canonical action
-- ------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_approval_requests_action_code
    ON approval_requests(tenant_id, action_code);


-- ------------------------------------------------------------
-- 11. Canonical action helper
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION canonicalize_authorization_action(
    p_action_code varchar
)
RETURNS varchar
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN

    IF p_action_code IS NULL OR btrim(p_action_code) = '' THEN
        RAISE EXCEPTION 'Authorization action code is required';
    END IF;

    -- Historical alias
    IF upper(btrim(p_action_code)) = 'ACCOUNT_CLOSURE' THEN
        RETURN 'ACCOUNT_CLOSE';
    END IF;

    RETURN upper(btrim(p_action_code));

END;
$$;


-- ------------------------------------------------------------
-- 12. Normalize new approval requests
--
-- Existing historical records are NOT rewritten.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION normalize_approval_request_action()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN

    IF NEW.action_code IS NULL THEN
        NEW.action_code :=
            canonicalize_authorization_action(NEW.request_type);
    ELSE
        NEW.action_code :=
            canonicalize_authorization_action(NEW.action_code);
    END IF;

    RETURN NEW;

END;
$$;


DROP TRIGGER IF EXISTS trg_normalize_approval_request_action
    ON approval_requests;

CREATE TRIGGER trg_normalize_approval_request_action
BEFORE INSERT OR UPDATE OF action_code
ON approval_requests
FOR EACH ROW
EXECUTE FUNCTION normalize_approval_request_action();


-- ------------------------------------------------------------
-- 13. Security
-- ------------------------------------------------------------

ALTER TABLE authorization_actions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS authorization_actions_read
    ON authorization_actions;

CREATE POLICY authorization_actions_read
ON authorization_actions
FOR SELECT
USING (true);


-- ------------------------------------------------------------
-- 14. Documentation
-- ------------------------------------------------------------

COMMENT ON TABLE authorization_actions IS
'Canonical registry of actions that may require authorization.';

COMMENT ON COLUMN authorization_actions.action_code IS
'Canonical machine-readable authorization action code.';

COMMENT ON COLUMN approval_requests.action_code IS
'Canonical authorization action associated with this request.';

COMMENT ON COLUMN approval_requests.request_type IS
'Legacy request type retained for historical compatibility. New authorization logic should use action_code.';