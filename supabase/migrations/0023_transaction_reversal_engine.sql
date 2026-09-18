-- ============================================================
-- 0023_transaction_reversal_engine.sql
-- Transaction Reversal Engine
-- ============================================================

-- ============================================================
-- 1. Add REV prefix to transaction reference generation
-- ============================================================

CREATE OR REPLACE FUNCTION generate_transaction_reference(
    p_transaction_type varchar
)
RETURNS varchar
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_prefix varchar(10);
    v_sequence bigint;
BEGIN

    v_prefix :=
        CASE upper(p_transaction_type)
            WHEN 'DEPOSIT' THEN 'DEP'
            WHEN 'WITHDRAWAL' THEN 'WDL'
            WHEN 'TRANSFER' THEN 'TRF'
            WHEN 'FEE' THEN 'FEE'
            WHEN 'LOAN_DISBURSEMENT' THEN 'LND'
            WHEN 'LOAN_REPAYMENT' THEN 'LNR'
            WHEN 'REVERSAL' THEN 'REV'
            ELSE 'TXN'
        END;

    v_sequence :=
        nextval('transaction_reference_seq');

    RETURN
        v_prefix ||
        '-' ||
        lpad(v_sequence::text, 12, '0');

END;
$$;


-- ============================================================
-- 2. Internal reversal posting function
--
-- This function assumes authorization has already been
-- satisfied.
--
-- It:
--   - locks the original transaction
--   - verifies it is POSTED
--   - prevents double reversal
--   - creates a new REVERSAL transaction
--   - swaps every debit and credit
--   - reverses ledger balances
--   - reverses customer account balances where applicable
--   - marks original transaction REVERSED
--   - writes an audit record
-- ============================================================

CREATE OR REPLACE FUNCTION post_transaction_reversal(
    p_tenant_id uuid,
    p_transaction_id uuid,
    p_created_by uuid,
    p_description text DEFAULT NULL,
    p_idempotency_key varchar DEFAULT NULL
)
RETURNS TABLE (
    transaction_id uuid,
    reversal_transaction_id uuid,
    original_reference varchar,
    reversal_reference varchar,
    amount bigint,
    status transaction_status
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_original transactions%ROWTYPE;
    v_reversal_id uuid;
    v_reversal_reference varchar;
    v_idempotency_key varchar;
    v_description text;
    v_entry record;
    v_ledger ledger_accounts%ROWTYPE;
    v_customer_account accounts%ROWTYPE;
    v_delta bigint;
BEGIN

    -- --------------------------------------------------------
    -- 1. Validate creator
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_created_by
          AND tenant_id = p_tenant_id
          AND is_active = true
    ) THEN
        RAISE EXCEPTION
            'User does not belong to tenant or is inactive';
    END IF;


    -- --------------------------------------------------------
    -- 2. Idempotency
    --
    -- A repeated reversal request returns the already-created
    -- reversal instead of creating another one.
    -- --------------------------------------------------------

    IF p_idempotency_key IS NOT NULL THEN

        SELECT
            t.id,
            t.reversal_of_transaction_id,
            t.reference,
            t.amount,
            t.status
        INTO
            v_reversal_id,
            v_original.id,
            v_reversal_reference,
            v_original.amount,
            v_original.status
        FROM transactions t
        WHERE t.tenant_id = p_tenant_id
          AND t.idempotency_key = p_idempotency_key
          AND t.transaction_type = 'REVERSAL'
        LIMIT 1;

        IF FOUND THEN

            SELECT *
            INTO v_original
            FROM transactions
            WHERE id = (
                SELECT reversal_of_transaction_id
                FROM transactions
                WHERE id = v_reversal_id
            )
              AND tenant_id = p_tenant_id;

            RETURN QUERY
            SELECT
                v_original.id,
                v_reversal_id,
                v_original.reference,
                v_reversal_reference,
                v_original.amount,
                'REVERSED'::transaction_status;

            RETURN;

        END IF;

    END IF;


    -- --------------------------------------------------------
    -- 3. Lock original transaction
    -- --------------------------------------------------------

    SELECT *
    INTO v_original
    FROM transactions
    WHERE id = p_transaction_id
      AND tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Transaction not found for tenant';
    END IF;


    -- --------------------------------------------------------
    -- 4. Original transaction must be POSTED
    -- --------------------------------------------------------

    IF v_original.status <> 'POSTED' THEN

        RAISE EXCEPTION
            'Only POSTED transactions can be reversed. Current status: %',
            v_original.status;

    END IF;


    -- --------------------------------------------------------
    -- 5. Ensure transaction has not already been reversed
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM transactions
        WHERE tenant_id = p_tenant_id
          AND reversal_of_transaction_id = v_original.id
          AND status IN ('POSTED', 'REVERSED')
    ) THEN

        RAISE EXCEPTION
            'Transaction % has already been reversed',
            v_original.reference;

    END IF;


    -- --------------------------------------------------------
    -- 6. Verify original transaction has entries
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM transaction_entries
        WHERE transaction_id = v_original.id
          AND tenant_id = p_tenant_id
    ) THEN

        RAISE EXCEPTION
            'Transaction % has no ledger entries',
            v_original.reference;

    END IF;


    -- --------------------------------------------------------
    -- 7. Verify original entries balance
    -- --------------------------------------------------------

    IF (
        SELECT COALESCE(SUM(debit), 0)
        FROM transaction_entries
        WHERE transaction_id = v_original.id
          AND tenant_id = p_tenant_id
    ) <> (
        SELECT COALESCE(SUM(credit), 0)
        FROM transaction_entries
        WHERE transaction_id = v_original.id
          AND tenant_id = p_tenant_id
    ) THEN

        RAISE EXCEPTION
            'Transaction % is not balanced and cannot be reversed',
            v_original.reference;

    END IF;


    -- --------------------------------------------------------
    -- 8. Resolve idempotency key
    -- --------------------------------------------------------

    v_idempotency_key := COALESCE(
        p_idempotency_key,
        'REV-' || v_original.id::text
    );


    -- --------------------------------------------------------
    -- 9. Generate reversal reference
    -- --------------------------------------------------------

    v_reversal_reference :=
        generate_transaction_reference('REVERSAL');


    -- --------------------------------------------------------
    -- 10. Create reversal transaction
    -- --------------------------------------------------------

    INSERT INTO transactions (
        tenant_id,
        reference,
        transaction_type,
        status,
        currency,
        amount,
        description,
        idempotency_key,
        posted_at,
        created_by,
        business_date_id,
        accounting_period_id,
        value_date,
        channel,
        reversal_of_transaction_id
    )
    VALUES (
        p_tenant_id,
        v_reversal_reference,
        'REVERSAL',
        'POSTED',
        v_original.currency,
        v_original.amount,
        COALESCE(
            NULLIF(btrim(p_description), ''),
            'Reversal of ' || v_original.reference
        ),
        v_idempotency_key,
        now(),
        p_created_by,
        v_original.business_date_id,
        v_original.accounting_period_id,
        v_original.value_date,
        v_original.channel,
        v_original.id
    )
    RETURNING id
    INTO v_reversal_id;


    -- --------------------------------------------------------
    -- 11. Reverse every ledger entry
    --
    -- Original debit  → reversal credit
    -- Original credit → reversal debit
    -- --------------------------------------------------------

    FOR v_entry IN
        SELECT
            te.id,
            te.tenant_id,
            te.ledger_account_id,
            te.debit,
            te.credit,
            te.description
        FROM transaction_entries te
        WHERE te.transaction_id = v_original.id
          AND te.tenant_id = p_tenant_id
        ORDER BY te.id
    LOOP

        INSERT INTO transaction_entries (
            transaction_id,
            tenant_id,
            ledger_account_id,
            debit,
            credit,
            description
        )
        VALUES (
            v_reversal_id,
            p_tenant_id,
            v_entry.ledger_account_id,
            v_entry.credit,
            v_entry.debit,
            'Reversal of ' || v_original.reference
        );


        -- ----------------------------------------------------
        -- Lock ledger account
        -- ----------------------------------------------------

        SELECT *
        INTO v_ledger
        FROM ledger_accounts
        WHERE id = v_entry.ledger_account_id
          AND tenant_id = p_tenant_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Ledger account % not found for tenant',
                v_entry.ledger_account_id;
        END IF;


        -- ----------------------------------------------------
        -- Calculate reversal effect on ledger balance
        --
        -- Asset / Expense:
        --   Debit increases balance
        --   Credit decreases balance
        --
        -- Liability / Equity / Income:
        --   Credit increases balance
        --   Debit decreases balance
        -- ----------------------------------------------------

        IF v_ledger.account_type IN ('ASSET', 'EXPENSE') THEN

            v_delta :=
                v_entry.credit - v_entry.debit;

        ELSE

            v_delta :=
                v_entry.debit - v_entry.credit;

        END IF;


        UPDATE ledger_accounts
        SET
            current_balance = current_balance + v_delta,
            updated_at = now()
        WHERE id = v_ledger.id
          AND tenant_id = p_tenant_id;


        -- ----------------------------------------------------
        -- If this ledger account belongs to a customer account,
        -- reverse that account's balance as well.
        -- ----------------------------------------------------

        SELECT *
        INTO v_customer_account
        FROM accounts
        WHERE tenant_id = p_tenant_id
          AND ledger_account_id = v_ledger.id
        FOR UPDATE;

        IF FOUND THEN

            UPDATE accounts
            SET
                ledger_balance = ledger_balance + v_delta,
                available_balance = available_balance + v_delta,
                updated_at = now()
            WHERE id = v_customer_account.id
              AND tenant_id = p_tenant_id;

        END IF;

    END LOOP;


    -- --------------------------------------------------------
    -- 12. Mark original transaction as REVERSED
    -- --------------------------------------------------------

    UPDATE transactions
    SET
        status = 'REVERSED'
    WHERE id = v_original.id
      AND tenant_id = p_tenant_id;


    -- --------------------------------------------------------
    -- 13. Audit trail
    -- --------------------------------------------------------

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
        p_created_by,
        'TRANSACTION_REVERSED',
        'TRANSACTION',
        v_original.id,
        jsonb_build_object(
            'status', 'POSTED',
            'reference', v_original.reference,
            'amount', v_original.amount
        ),
        jsonb_build_object(
            'status', 'REVERSED',
            'reversal_transaction_id', v_reversal_id,
            'reversal_reference', v_reversal_reference
        )
    );


    -- --------------------------------------------------------
    -- 14. Return result
    -- --------------------------------------------------------

    RETURN QUERY
    SELECT
        v_original.id,
        v_reversal_id,
        v_original.reference,
        v_reversal_reference,
        v_original.amount,
        'REVERSED'::transaction_status;

END;
$$;


-- ============================================================
-- 15. Public authorization-aware entry point
--
-- If authorization permits direct/self-authorization:
--     execute reversal
--
-- Otherwise:
--     create approval request
--
-- No ledger mutation occurs when approval is required.
-- ============================================================

CREATE OR REPLACE FUNCTION execute_authorized_transaction_reversal(
    p_tenant_id uuid,
    p_transaction_id uuid,
    p_requested_by uuid,
    p_comment text DEFAULT NULL
)
RETURNS TABLE (
    result_status varchar,
    transaction_id uuid,
    authorization_mode authorization_mode,
    self_authorized boolean,
    approval_request_id uuid,
    reversal_transaction_id uuid,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_transaction transactions%ROWTYPE;
    v_decision RECORD;
    v_request approval_requests%ROWTYPE;
    v_posted record;
BEGIN

    -- --------------------------------------------------------
    -- 1. Validate requester
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_requested_by
          AND tenant_id = p_tenant_id
          AND is_active = true
    ) THEN
        RAISE EXCEPTION
            'Requester does not belong to tenant or is inactive';
    END IF;


    -- --------------------------------------------------------
    -- 2. Validate transaction
    -- --------------------------------------------------------

    SELECT *
    INTO v_transaction
    FROM transactions
    WHERE id = p_transaction_id
      AND tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Transaction not found for tenant';
    END IF;


    IF v_transaction.status <> 'POSTED' THEN
        RAISE EXCEPTION
            'Only POSTED transactions can be submitted for reversal. Current status: %',
            v_transaction.status;
    END IF;


    -- --------------------------------------------------------
    -- 3. Resolve authorization
    -- --------------------------------------------------------

    SELECT *
    INTO v_decision
    FROM get_authorization_decision(
        p_tenant_id,
        p_requested_by,
        'TRANSACTION_REVERSE',
        v_transaction.amount,
        NULL
    );


    -- --------------------------------------------------------
    -- 4. Direct execution
    -- --------------------------------------------------------

    IF v_decision.authorization_mode =
        'DIRECT'::authorization_mode THEN

        SELECT *
        INTO v_posted
        FROM post_transaction_reversal(
            p_tenant_id,
            p_transaction_id,
            p_requested_by,
            p_comment,
            NULL
        );

        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            p_transaction_id,
            v_decision.authorization_mode,
            false,
            NULL::uuid,
            v_posted.reversal_transaction_id,
            'Transaction reversed successfully'::text;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- 5. User-choice self-authorization
    -- --------------------------------------------------------

    IF v_decision.authorization_mode =
        'USER_CHOICE'::authorization_mode
       AND v_decision.policy_allow_self_authorization = true
       AND v_decision.user_can_self_authorize = true THEN

        SELECT *
        INTO v_posted
        FROM post_transaction_reversal(
            p_tenant_id,
            p_transaction_id,
            p_requested_by,
            p_comment,
            NULL
        );

        RETURN QUERY
        SELECT
            'EXECUTED'::varchar,
            p_transaction_id,
            v_decision.authorization_mode,
            true,
            NULL::uuid,
            v_posted.reversal_transaction_id,
            'Transaction reversed through self-authorization'::text;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- 6. Approval required
    -- --------------------------------------------------------

    SELECT *
    INTO v_request
    FROM create_approval_request(
        p_tenant_id,
        'TRANSACTION_REVERSE',
        'TRANSACTION',
        p_transaction_id,
        p_requested_by,
        p_comment
    );


    RETURN QUERY
    SELECT
        'PENDING_APPROVAL'::varchar,
        p_transaction_id,
        v_decision.authorization_mode,
        false,
        v_request.id,
        NULL::uuid,
        'Transaction reversal requires authorization'::text;

END;
$$;


-- ============================================================
-- 16. Security
-- ============================================================

REVOKE ALL
ON FUNCTION post_transaction_reversal(
    uuid,
    uuid,
    uuid,
    text,
    varchar
)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION execute_authorized_transaction_reversal(
    uuid,
    uuid,
    uuid,
    text
)
FROM PUBLIC;


-- ============================================================
-- 17. Documentation
-- ============================================================

COMMENT ON FUNCTION post_transaction_reversal(
    uuid,
    uuid,
    uuid,
    text,
    varchar
)
IS
'Posts a balanced reversal transaction against an existing POSTED transaction and marks the original transaction REVERSED.';

COMMENT ON FUNCTION execute_authorized_transaction_reversal(
    uuid,
    uuid,
    uuid,
    text
)
IS
'Executes or submits a transaction reversal according to the authorization policy and requesting user authorization capability.';