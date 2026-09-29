-- ============================================================
-- MIGRATION 0029
-- Execute Approved Account Closure
-- ============================================================
--
-- Purpose:
-- Complete the execution stage of the authorization framework.
--
-- Supports:
--   - TRANSACTION_REVERSE
--   - ACCOUNT_CLOSE
--
-- Adds:
--   - executed_at
--   - executed_by
--
-- Security:
--   - Executor must be active and belong to tenant
--   - Request must be APPROVED
--   - Requester cannot execute their own maker-checker request
--   - Self-authorized requests cannot be executed through this path
--   - Account closure rules are revalidated at execution time
--   - All execution occurs atomically
-- ============================================================


-- ============================================================
-- 1. Add execution tracking
-- ============================================================

ALTER TABLE approval_requests
ADD COLUMN IF NOT EXISTS executed_at timestamptz;

ALTER TABLE approval_requests
ADD COLUMN IF NOT EXISTS executed_by uuid;

ALTER TABLE approval_requests
DROP CONSTRAINT IF EXISTS approval_requests_execution_consistency;

ALTER TABLE approval_requests
ADD CONSTRAINT approval_requests_execution_consistency
CHECK (
    (executed_at IS NULL AND executed_by IS NULL)
    OR
    (executed_at IS NOT NULL AND executed_by IS NOT NULL)
);


CREATE INDEX IF NOT EXISTS idx_approval_requests_execution
ON approval_requests(tenant_id, executed_at);


-- ============================================================
-- 2. Replace approved-request execution engine
-- ============================================================

DROP FUNCTION IF EXISTS execute_approved_request(
    uuid,
    uuid,
    uuid,
    text,
    varchar
);


CREATE FUNCTION execute_approved_request(
    p_tenant_id uuid,
    p_approval_request_id uuid,
    p_executed_by uuid,
    p_description text DEFAULT NULL,
    p_idempotency_key varchar DEFAULT NULL
)
RETURNS TABLE (
    result_status varchar,
    approval_request_id uuid,
    action_code varchar,
    transaction_id uuid,
    reversal_transaction_id uuid,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_request approval_requests%ROWTYPE;

    v_original_transaction_id uuid;
    v_reversal_result record;

    v_account accounts%ROWTYPE;

    v_idempotency_key varchar;

    v_action_code varchar;
BEGIN

    -- ========================================================
    -- 1. Validate executor
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_executed_by
          AND tenant_id = p_tenant_id
          AND is_active = true
    ) THEN
        RAISE EXCEPTION
            'Executor is not an active user in this tenant';
    END IF;


    -- ========================================================
    -- 2. Lock approval request
    -- ========================================================

    SELECT *
    INTO v_request
    FROM approval_requests
    WHERE id = p_approval_request_id
      AND tenant_id = p_tenant_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Approval request not found';
    END IF;


    -- ========================================================
    -- 3. Request must be approved
    -- ========================================================

    IF v_request.status <> 'APPROVED' THEN
        RAISE EXCEPTION
            'Approval request must be APPROVED before execution. Current status: %',
            v_request.status;
    END IF;


    -- ========================================================
    -- 4. Prevent duplicate execution
    -- ========================================================

    IF v_request.executed_at IS NOT NULL THEN

        RETURN QUERY
        SELECT
            'ALREADY_EXECUTED'::varchar,
            v_request.id,
            v_request.action_code,
            NULL::uuid,
            NULL::uuid,
            'Approval request has already been executed'::text;

        RETURN;

    END IF;


    -- ========================================================
    -- 5. Prevent requester from executing own maker-checker
    -- ========================================================

    IF v_request.requested_by = p_executed_by THEN
        RAISE EXCEPTION
            'The requester cannot execute their own approved maker-checker request';
    END IF;


    -- ========================================================
    -- 6. Self-authorized requests should not reach this path
    -- ========================================================

    IF v_request.self_authorized = true THEN
        RAISE EXCEPTION
            'Self-authorized requests must execute through the authorization entry point';
    END IF;


    -- ========================================================
    -- 7. Canonical action code
    -- ========================================================

    v_action_code :=
        canonicalize_authorization_action(v_request.action_code);


    -- ========================================================
    -- 8. TRANSACTION_REVERSE
    -- ========================================================

    IF v_action_code = 'TRANSACTION_REVERSE' THEN

        v_original_transaction_id := v_request.entity_id;

        v_idempotency_key :=
            COALESCE(
                p_idempotency_key,
                'APPROVAL-' || p_approval_request_id::text
            );


        SELECT *
        INTO v_reversal_result
        FROM post_transaction_reversal(
            p_tenant_id,
            v_original_transaction_id,
            p_executed_by,
            COALESCE(
                p_description,
                'Reversal executed from approved authorization request'
            ),
            v_idempotency_key
        );


        -- ----------------------------------------------------
        -- Mark approval request as executed
        -- ----------------------------------------------------

        UPDATE approval_requests
        SET
            executed_at = now(),
            executed_by = p_executed_by,
            updated_at = now()
        WHERE id = v_request.id;


        -- ----------------------------------------------------
        -- Audit execution
        -- ----------------------------------------------------

        INSERT INTO audit_logs (
            tenant_id,
            user_id,
            action,
            entity_type,
            entity_id,
            old_values,
            new_values
        )
        VALUES (
            p_tenant_id,
            p_executed_by,
            'APPROVAL_REQUEST_EXECUTED',
            'APPROVAL_REQUEST',
            v_request.id,
            jsonb_build_object(
                'status', 'APPROVED',
                'action_code', v_action_code
            ),
            jsonb_build_object(
                'status', 'APPROVED',
                'action_code', v_action_code,
                'executed_by', p_executed_by,
                'executed_at', now(),
                'transaction_id',
                    v_original_transaction_id,
                'reversal_transaction_id',
                    v_reversal_result.reversal_transaction_id
            )
        );


        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            v_request.id,
            v_action_code,
            v_reversal_result.original_transaction_id,
            v_reversal_result.reversal_transaction_id,
            'Approved transaction reversal executed successfully'::text;

        RETURN;

    END IF;


    -- ========================================================
    -- 9. ACCOUNT_CLOSE
    -- ========================================================

    IF v_action_code = 'ACCOUNT_CLOSE' THEN

        -- ----------------------------------------------------
        -- Lock account
        -- ----------------------------------------------------

        SELECT *
        INTO v_account
        FROM accounts
        WHERE id = v_request.entity_id
          AND tenant_id = p_tenant_id
        FOR UPDATE;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Account requested for closure was not found';
        END IF;


        -- ----------------------------------------------------
        -- Revalidate account status
        -- ----------------------------------------------------

        IF v_account.status = 'CLOSED' THEN

            UPDATE approval_requests
            SET
                executed_at = now(),
                executed_by = p_executed_by,
                updated_at = now()
            WHERE id = v_request.id;


            INSERT INTO audit_logs (
                tenant_id,
                user_id,
                action,
                entity_type,
                entity_id,
                old_values,
                new_values
            )
            VALUES (
                p_tenant_id,
                p_executed_by,
                'APPROVAL_REQUEST_EXECUTED',
                'APPROVAL_REQUEST',
                v_request.id,
                jsonb_build_object(
                    'status', 'APPROVED',
                    'action_code', v_action_code
                ),
                jsonb_build_object(
                    'status', 'APPROVED',
                    'action_code', v_action_code,
                    'executed_by', p_executed_by,
                    'executed_at', now(),
                    'account_id', v_account.id,
                    'result', 'ALREADY_CLOSED'
                )
            );


            RETURN QUERY
            SELECT
                'ALREADY_CLOSED'::varchar,
                v_request.id,
                v_action_code,
                NULL::uuid,
                NULL::uuid,
                'Account was already closed'::text;

            RETURN;

        END IF;


        -- ----------------------------------------------------
        -- Account must be in a closable state
        -- ----------------------------------------------------

        IF v_account.status NOT IN (
            'ACTIVE',
            'FROZEN',
            'DORMANT'
        ) THEN

            RAISE EXCEPTION
                'Account cannot be closed from status %',
                v_account.status;

        END IF;


        -- ----------------------------------------------------
        -- Account must have zero balances
        -- ----------------------------------------------------

        IF v_account.ledger_balance <> 0
           OR v_account.available_balance <> 0 THEN

            RAISE EXCEPTION
                'Account cannot be closed while balance is not zero. Ledger: %, Available: %',
                v_account.ledger_balance,
                v_account.available_balance;

        END IF;


        -- ----------------------------------------------------
        -- Execute closure
        -- ----------------------------------------------------

        UPDATE accounts
        SET
            status = 'CLOSED',
            closed_at = now(),
            updated_at = now()
        WHERE id = v_account.id
          AND tenant_id = p_tenant_id;


        -- ----------------------------------------------------
        -- Mark approval request as executed
        -- ----------------------------------------------------

        UPDATE approval_requests
        SET
            executed_at = now(),
            executed_by = p_executed_by,
            updated_at = now()
        WHERE id = v_request.id;


        -- ----------------------------------------------------
        -- Audit execution
        -- ----------------------------------------------------

        INSERT INTO audit_logs (
            tenant_id,
            user_id,
            action,
            entity_type,
            entity_id,
            old_values,
            new_values
        )
        VALUES (
            p_tenant_id,
            p_executed_by,
            'APPROVAL_REQUEST_EXECUTED',
            'APPROVAL_REQUEST',
            v_request.id,
            jsonb_build_object(
                'status', 'APPROVED',
                'action_code', v_action_code,
                'account_status', v_account.status
            ),
            jsonb_build_object(
                'status', 'APPROVED',
                'action_code', v_action_code,
                'executed_by', p_executed_by,
                'executed_at', now(),
                'account_id', v_account.id,
                'account_status', 'CLOSED'
            )
        );


        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            v_request.id,
            v_action_code,
            NULL::uuid,
            NULL::uuid,
            'Approved account closure executed successfully'::text;

        RETURN;

    END IF;


    -- ========================================================
    -- 10. Unsupported action
    -- ========================================================

    RAISE EXCEPTION
        'Unsupported approval action: %',
        v_action_code;

END;
$$;


-- ============================================================
-- 3. Ownership
-- ============================================================

ALTER FUNCTION execute_approved_request(
    uuid,
    uuid,
    uuid,
    text,
    varchar
) OWNER TO postgres;


-- ============================================================
-- 4. Security
-- ============================================================

REVOKE ALL ON FUNCTION execute_approved_request(
    uuid,
    uuid,
    uuid,
    text,
    varchar
) FROM PUBLIC;


-- ============================================================
-- 5. Documentation
-- ============================================================

COMMENT ON FUNCTION execute_approved_request(
    uuid,
    uuid,
    uuid,
    text,
    varchar
)
IS
'Executes an approved authorization request for supported controlled operations including transaction reversal and account closure. Revalidates execution conditions and records execution audit data.';