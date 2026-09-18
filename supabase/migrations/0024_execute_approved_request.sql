-- 0024_execute_approved_request.sql

CREATE OR REPLACE FUNCTION execute_approved_request(
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
    v_idempotency_key varchar;
BEGIN
    -- Validate executor
    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_executed_by
          AND tenant_id = p_tenant_id
          AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Executor is not an active user in this tenant';
    END IF;

    -- Lock the approval request
    SELECT *
    INTO v_request
    FROM approval_requests
    WHERE id = p_approval_request_id
      AND tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Approval request not found';
    END IF;

    -- Only approved requests may be executed
    IF v_request.status <> 'APPROVED' THEN
        RAISE EXCEPTION
            'Approval request must be APPROVED before execution. Current status: %',
            v_request.status;
    END IF;

    -- Prevent the requester from executing their own approved request
    IF v_request.requested_by = p_executed_by THEN
        RAISE EXCEPTION
            'The requester cannot execute an approved maker-checker request';
    END IF;

    -- Currently supported action
    IF v_request.action_code = 'TRANSACTION_REVERSE' THEN

        v_original_transaction_id := v_request.entity_id;

        -- Use supplied idempotency key, otherwise derive one from approval request
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

        -- Return execution result
        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            p_approval_request_id,
            v_request.action_code,
            v_reversal_result.original_transaction_id,
            v_reversal_result.reversal_transaction_id,
            'Approved transaction reversal executed successfully'::text;

        RETURN;
    END IF;

    RAISE EXCEPTION
        'Unsupported approval action: %',
        v_request.action_code;
END;
$$;

ALTER FUNCTION execute_approved_request(
    uuid,
    uuid,
    uuid,
    text,
    varchar
) OWNER TO postgres;

REVOKE ALL ON FUNCTION execute_approved_request(
    uuid,
    uuid,
    uuid,
    text,
    varchar
) FROM PUBLIC;