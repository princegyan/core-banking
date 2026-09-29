-- ============================================================
-- MIGRATION 0030
-- Internal Transfer Posting Engine
-- ============================================================
--
-- Purpose:
-- Create the authoritative database posting engine for
-- customer-to-customer internal transfers.
--
-- Accounting:
--
-- Source customer ledger:
--     DEBIT
--
-- Destination customer ledger:
--     CREDIT
--
-- Customer account balances:
--     Source      -> decrease
--     Destination -> increase
--
-- Requirements:
--   - Same tenant
--   - Both accounts must exist
--   - Both accounts must be ACTIVE
--   - Same currency
--   - Source must have sufficient balance
--   - Source and destination cannot be the same account
--   - Customer-specific ledger accounts required
--   - Open business date required
--   - Open accounting period required
--   - Idempotency supported
--   - Atomic execution
--   - Balanced double-entry transaction
--   - Audit record
--
-- Authorization is intentionally NOT implemented here.
-- Authorization will sit above this posting engine.
-- ============================================================


-- ============================================================
-- 1. Internal transfer posting function
-- ============================================================

CREATE OR REPLACE FUNCTION post_internal_transfer(
    p_tenant_id uuid,
    p_source_account_id uuid,
    p_destination_account_id uuid,
    p_amount bigint,
    p_description text DEFAULT NULL,
    p_idempotency_key varchar DEFAULT NULL,
    p_created_by uuid DEFAULT NULL
)
RETURNS TABLE (
    transaction_id uuid,
    transaction_reference varchar,
    source_account_id uuid,
    destination_account_id uuid,
    amount bigint,
    status transaction_status,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_source_account accounts%ROWTYPE;
    v_destination_account accounts%ROWTYPE;

    v_source_ledger ledger_accounts%ROWTYPE;
    v_destination_ledger ledger_accounts%ROWTYPE;

    v_transaction_id uuid;
    v_transaction_reference varchar;

    v_business_date business_dates%ROWTYPE;
    v_accounting_period accounting_periods%ROWTYPE;

    v_description text;

    v_source_new_balance bigint;
    v_destination_new_balance bigint;

    v_existing_transaction transactions%ROWTYPE;
BEGIN

    -- ========================================================
    -- 2. Validate amount
    -- ========================================================

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION
            'Transfer amount must be greater than zero';
    END IF;


    -- ========================================================
    -- 3. Validate creator
    -- ========================================================

    IF p_created_by IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM users u
            WHERE u.id = p_created_by
              AND u.tenant_id = p_tenant_id
              AND u.is_active = true
        ) THEN
            RAISE EXCEPTION
                'Creator is not an active user in this tenant';
        END IF;

    END IF;


    -- ========================================================
    -- 4. Validate source and destination are different
    -- ========================================================

    IF p_source_account_id = p_destination_account_id THEN
        RAISE EXCEPTION
            'Source and destination accounts must be different';
    END IF;


    -- ========================================================
    -- 5. Idempotency
    -- ========================================================

    IF p_idempotency_key IS NOT NULL THEN

        SELECT *
        INTO v_existing_transaction
        FROM transactions t
        WHERE t.tenant_id = p_tenant_id
          AND t.idempotency_key = p_idempotency_key
        LIMIT 1;

        IF FOUND THEN

            RETURN QUERY
            SELECT
                v_existing_transaction.id,
                v_existing_transaction.reference,
                p_source_account_id,
                p_destination_account_id,
                v_existing_transaction.amount,
                v_existing_transaction.status,
                'Duplicate transfer request'::text;

            RETURN;

        END IF;

    END IF;


    -- ========================================================
    -- 6. Lock both accounts
    --
    -- Lock in deterministic UUID order to reduce deadlock risk
    -- when concurrent transfers involve the same accounts.
    -- ========================================================

    PERFORM a.id
    FROM accounts a
    WHERE a.tenant_id = p_tenant_id
      AND a.id IN (
          p_source_account_id,
          p_destination_account_id
      )
    ORDER BY a.id
    FOR UPDATE;


    -- ========================================================
    -- 7. Load source account
    -- ========================================================

    SELECT *
    INTO v_source_account
    FROM accounts a
    WHERE a.id = p_source_account_id
      AND a.tenant_id = p_tenant_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Source account not found for tenant';
    END IF;


    -- ========================================================
    -- 8. Load destination account
    -- ========================================================

    SELECT *
    INTO v_destination_account
    FROM accounts a
    WHERE a.id = p_destination_account_id
      AND a.tenant_id = p_tenant_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Destination account not found for tenant';
    END IF;


    -- ========================================================
    -- 9. Both accounts must be ACTIVE
    -- ========================================================

    IF v_source_account.status <> 'ACTIVE' THEN
        RAISE EXCEPTION
            'Source account must be ACTIVE. Current status: %',
            v_source_account.status;
    END IF;


    IF v_destination_account.status <> 'ACTIVE' THEN
        RAISE EXCEPTION
            'Destination account must be ACTIVE. Current status: %',
            v_destination_account.status;
    END IF;


    -- ========================================================
    -- 10. Currency validation
    -- ========================================================

    IF v_source_account.currency <> v_destination_account.currency THEN
        RAISE EXCEPTION
            'Source and destination accounts must use the same currency';
    END IF;


    -- ========================================================
    -- 11. Source balance validation
    -- ========================================================

    IF v_source_account.available_balance < p_amount THEN
        RAISE EXCEPTION
            'Insufficient available balance. Available: %, Requested: %',
            v_source_account.available_balance,
            p_amount;
    END IF;


    IF v_source_account.ledger_balance < p_amount THEN
        RAISE EXCEPTION
            'Insufficient ledger balance. Ledger: %, Requested: %',
            v_source_account.ledger_balance,
            p_amount;
    END IF;


    -- ========================================================
    -- 12. Customer ledger validation
    -- ========================================================

    IF v_source_account.ledger_account_id IS NULL THEN
        RAISE EXCEPTION
            'Source account is not linked to a customer ledger account';
    END IF;


    IF v_destination_account.ledger_account_id IS NULL THEN
        RAISE EXCEPTION
            'Destination account is not linked to a customer ledger account';
    END IF;


    -- ========================================================
    -- 13. Load source ledger
    -- ========================================================

    SELECT *
    INTO v_source_ledger
    FROM ledger_accounts la
    WHERE la.id = v_source_account.ledger_account_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Source customer ledger account not found';
    END IF;


    -- ========================================================
    -- 14. Load destination ledger
    -- ========================================================

    SELECT *
    INTO v_destination_ledger
    FROM ledger_accounts la
    WHERE la.id = v_destination_account.ledger_account_id
      AND la.tenant_id = p_tenant_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Destination customer ledger account not found';
    END IF;


    -- ========================================================
    -- 15. Both ledgers must belong to customer accounts
    -- ========================================================

    IF v_source_ledger.account_type <> 'LIABILITY' THEN
        RAISE EXCEPTION
            'Source customer ledger must be a LIABILITY ledger account';
    END IF;


    IF v_destination_ledger.account_type <> 'LIABILITY' THEN
        RAISE EXCEPTION
            'Destination customer ledger must be a LIABILITY ledger account';
    END IF;


    -- ========================================================
    -- 16. Business date
    -- ========================================================

    SELECT *
    INTO v_business_date
    FROM business_dates bd
    WHERE bd.tenant_id = p_tenant_id
      AND bd.status = 'OPEN'
    ORDER BY bd.business_date DESC
    LIMIT 1
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No OPEN business date exists for this tenant';
    END IF;


    -- ========================================================
    -- 17. Accounting period
    -- ========================================================

    SELECT *
    INTO v_accounting_period
    FROM accounting_periods ap
    WHERE ap.tenant_id = p_tenant_id
      AND ap.status = 'OPEN'
      AND v_business_date.business_date
          BETWEEN ap.start_date AND ap.end_date
    ORDER BY ap.start_date DESC
    LIMIT 1
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No OPEN accounting period exists for the current business date';
    END IF;


    -- ========================================================
    -- 18. Description
    -- ========================================================

    v_description := NULLIF(
        btrim(COALESCE(p_description, '')),
        ''
    );


    IF v_description IS NULL THEN
        v_description :=
            'Internal transfer from '
            || v_source_account.account_number
            || ' to '
            || v_destination_account.account_number;
    END IF;


    -- ========================================================
    -- 19. Generate transaction reference
    -- ========================================================

    v_transaction_reference :=
        generate_transaction_reference('TRANSFER');


    -- ========================================================
    -- 20. Create transaction
    -- ========================================================

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
        channel
    )
    VALUES (
        p_tenant_id,
        v_transaction_reference,
        'TRANSFER',
        'POSTED',
        v_source_account.currency,
        p_amount,
        v_description,
        p_idempotency_key,
        now(),
        p_created_by,
        v_business_date.id,
        v_accounting_period.id,
        v_business_date.business_date,
        'INTERNAL_TRANSFER'
    )
    RETURNING id
    INTO v_transaction_id;


    -- ========================================================
    -- 21. Create source ledger entry
    --
    -- Liability decreases:
    --     DEBIT source customer ledger
    -- ========================================================

    INSERT INTO transaction_entries (
        transaction_id,
        tenant_id,
        ledger_account_id,
        debit,
        credit,
        description
    )
    VALUES (
        v_transaction_id,
        p_tenant_id,
        v_source_ledger.id,
        p_amount,
        0,
        'Internal transfer debit from '
        || v_source_account.account_number
    );


    -- ========================================================
    -- 22. Create destination ledger entry
    --
    -- Liability increases:
    --     CREDIT destination customer ledger
    -- ========================================================

    INSERT INTO transaction_entries (
        transaction_id,
        tenant_id,
        ledger_account_id,
        debit,
        credit,
        description
    )
    VALUES (
        v_transaction_id,
        p_tenant_id,
        v_destination_ledger.id,
        0,
        p_amount,
        'Internal transfer credit to '
        || v_destination_account.account_number
    );


    -- ========================================================
    -- 23. Calculate new customer ledger balances
    -- ========================================================

    v_source_new_balance :=
        v_source_ledger.current_balance - p_amount;

    v_destination_new_balance :=
        v_destination_ledger.current_balance + p_amount;


    IF v_source_new_balance < 0 THEN
        RAISE EXCEPTION
            'Transfer would create negative source ledger balance';
    END IF;


    -- ========================================================
    -- 24. Update source ledger
    -- ========================================================

    UPDATE ledger_accounts
    SET
        current_balance = v_source_new_balance,
        updated_at = now()
    WHERE id = v_source_ledger.id
      AND tenant_id = p_tenant_id;


    -- ========================================================
    -- 25. Update destination ledger
    -- ========================================================

    UPDATE ledger_accounts
    SET
        current_balance = v_destination_new_balance,
        updated_at = now()
    WHERE id = v_destination_ledger.id
      AND tenant_id = p_tenant_id;


    -- ========================================================
    -- 26. Update source customer account
    -- ========================================================

    UPDATE accounts
    SET
        ledger_balance = ledger_balance - p_amount,
        available_balance = available_balance - p_amount,
        updated_at = now()
    WHERE id = v_source_account.id
      AND tenant_id = p_tenant_id;


    -- ========================================================
    -- 27. Update destination customer account
    -- ========================================================

    UPDATE accounts
    SET
        ledger_balance = ledger_balance + p_amount,
        available_balance = available_balance + p_amount,
        updated_at = now()
    WHERE id = v_destination_account.id
      AND tenant_id = p_tenant_id;


    -- ========================================================
    -- 28. Audit
    -- ========================================================

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
        'TRANSFER_POSTED',
        'TRANSACTION',
        v_transaction_id,
        jsonb_build_object(
            'source_account_id',
                v_source_account.id,
            'destination_account_id',
                v_destination_account.id,
            'source_balance',
                v_source_account.ledger_balance,
            'destination_balance',
                v_destination_account.ledger_balance
        ),
        jsonb_build_object(
            'transaction_id',
                v_transaction_id,
            'reference',
                v_transaction_reference,
            'transaction_type',
                'TRANSFER',
            'amount',
                p_amount,
            'source_account_id',
                v_source_account.id,
            'destination_account_id',
                v_destination_account.id,
            'source_balance',
                v_source_account.ledger_balance - p_amount,
            'destination_balance',
                v_destination_account.ledger_balance + p_amount
        )
    );


    -- ========================================================
    -- 29. Return result
    -- ========================================================

    RETURN QUERY
    SELECT
        v_transaction_id,
        v_transaction_reference,
        v_source_account.id,
        v_destination_account.id,
        p_amount,
        'POSTED'::transaction_status,
        'Internal transfer posted successfully'::text;

END;
$$;


-- ============================================================
-- 30. Ownership
-- ============================================================

ALTER FUNCTION post_internal_transfer(
    uuid,
    uuid,
    uuid,
    bigint,
    text,
    varchar,
    uuid
) OWNER TO postgres;


-- ============================================================
-- 31. Security
-- ============================================================

REVOKE ALL
ON FUNCTION post_internal_transfer(
    uuid,
    uuid,
    uuid,
    bigint,
    text,
    varchar,
    uuid
)
FROM PUBLIC;


-- ============================================================
-- 32. Documentation
-- ============================================================

COMMENT ON FUNCTION post_internal_transfer(
    uuid,
    uuid,
    uuid,
    bigint,
    text,
    varchar,
    uuid
)
IS
'Posts an atomic internal customer-to-customer transfer using double-entry accounting. Debits the source customer liability ledger and credits the destination customer liability ledger.';