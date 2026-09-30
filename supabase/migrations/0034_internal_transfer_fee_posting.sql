-- ============================================================
-- 0034_internal_transfer_fee_posting.sql
-- Add optional configured fee to internal transfers
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
RETURNS TABLE(
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
AS $function$
DECLARE
    v_source_account accounts%ROWTYPE;
    v_destination_account accounts%ROWTYPE;

    v_source_ledger ledger_accounts%ROWTYPE;
    v_destination_ledger ledger_accounts%ROWTYPE;
    v_fee_income_ledger ledger_accounts%ROWTYPE;

    v_transaction_id uuid;
    v_transaction_reference varchar;

    v_business_date business_dates%ROWTYPE;
    v_accounting_period accounting_periods%ROWTYPE;

    v_description text;

    v_source_new_balance bigint;
    v_destination_new_balance bigint;

    v_existing_transaction transactions%ROWTYPE;

    v_fee_id uuid;
    v_fee_amount bigint := 0;
    v_total_source_debit bigint;
BEGIN

    -- ========================================================
    -- 1. Validate amount
    -- ========================================================

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION
            'Transfer amount must be greater than zero';
    END IF;


    -- ========================================================
    -- 2. Validate creator
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
    -- 3. Validate source and destination are different
    -- ========================================================

    IF p_source_account_id = p_destination_account_id THEN
        RAISE EXCEPTION
            'Source and destination accounts must be different';
    END IF;


    -- ========================================================
    -- 4. Idempotency
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
    -- 5. Lock both accounts
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
    -- 6. Load source account
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
    -- 7. Load destination account
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
    -- 8. Both accounts must be ACTIVE
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
    -- 9. Currency validation
    -- ========================================================

    IF v_source_account.currency <> v_destination_account.currency THEN
        RAISE EXCEPTION
            'Source and destination accounts must use the same currency';
    END IF;


    -- ========================================================
    -- 10. Resolve optional active transfer fee
    --
    -- If no active INTERNAL_TRANSFER_FEE exists,
    -- the transfer proceeds without a fee.
    -- ========================================================

    SELECT
        f.id
    INTO v_fee_id
    FROM fees f
    WHERE f.tenant_id = p_tenant_id
      AND f.code = 'INTERNAL_TRANSFER_FEE'
      AND f.transaction_type = 'TRANSFER'
      AND f.currency = v_source_account.currency
      AND f.is_active = true
    LIMIT 1;

    IF v_fee_id IS NOT NULL THEN

        v_fee_amount := calculate_fee(
            p_tenant_id,
            'INTERNAL_TRANSFER_FEE',
            p_amount
        );

        IF v_fee_amount < 0 THEN
            RAISE EXCEPTION
                'Calculated transfer fee cannot be negative';
        END IF;

        -- Fee must have an active GL mapping.
        SELECT la.*
        INTO v_fee_income_ledger
        FROM fee_gl_mappings fgm
        JOIN ledger_accounts la
            ON la.id = fgm.fee_income_ledger_account_id
        WHERE fgm.tenant_id = p_tenant_id
          AND fgm.fee_id = v_fee_id
          AND fgm.is_active = true
          AND la.tenant_id = p_tenant_id
          AND la.is_active = true
          AND la.account_type = 'INCOME'
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Active GL mapping not found for internal transfer fee';
        END IF;

    END IF;


    -- ========================================================
    -- 11. Total source debit
    --
    -- Transfer amount + fee
    -- ========================================================

    v_total_source_debit :=
        p_amount + v_fee_amount;


    -- ========================================================
    -- 12. Source balance validation
    -- ========================================================

    IF v_source_account.available_balance < v_total_source_debit THEN
        RAISE EXCEPTION
            'Insufficient available balance. Available: %, Requested: %',
            v_source_account.available_balance,
            v_total_source_debit;
    END IF;

    IF v_source_account.ledger_balance < v_total_source_debit THEN
        RAISE EXCEPTION
            'Insufficient ledger balance. Ledger: %, Requested: %',
            v_source_account.ledger_balance,
            v_total_source_debit;
    END IF;


    -- ========================================================
    -- 13. Customer ledger validation
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
    -- 14. Load source ledger
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
    -- 15. Load destination ledger
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
    -- 16. Both customer ledgers must be LIABILITY
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
    -- 17. Business date
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
    -- 18. Accounting period
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
    -- 19. Description
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
    -- 20. Generate transaction reference
    -- ========================================================

    v_transaction_reference :=
        generate_transaction_reference('TRANSFER');


    -- ========================================================
    -- 21. Create transaction
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
    -- 22. Debit source customer ledger
    --
    -- Transfer amount + fee
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
        v_total_source_debit,
        0,
        'Internal transfer debit from '
        || v_source_account.account_number
    );


    -- ========================================================
    -- 23. Credit destination customer ledger
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
    -- 24. Credit fee income ledger
    -- ========================================================

    IF v_fee_amount > 0 THEN

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
            v_fee_income_ledger.id,
            0,
            v_fee_amount,
            'Internal transfer fee'
        );

    END IF;


    -- ========================================================
    -- 25. Calculate new customer ledger balances
    -- ========================================================

    v_source_new_balance :=
        v_source_ledger.current_balance
        - v_total_source_debit;

    v_destination_new_balance :=
        v_destination_ledger.current_balance
        + p_amount;


    IF v_source_new_balance < 0 THEN
        RAISE EXCEPTION
            'Transfer would create negative source ledger balance';
    END IF;


    -- ========================================================
    -- 26. Update source ledger
    -- ========================================================

    UPDATE ledger_accounts
    SET
        current_balance = v_source_new_balance,
        updated_at = now()
    WHERE id = v_source_ledger.id
      AND tenant_id = p_tenant_id;


    -- ========================================================
    -- 27. Update destination ledger
    -- ========================================================

    UPDATE ledger_accounts
    SET
        current_balance = v_destination_new_balance,
        updated_at = now()
    WHERE id = v_destination_ledger.id
      AND tenant_id = p_tenant_id;


    -- ========================================================
    -- 28. Update fee income ledger
    -- ========================================================

    IF v_fee_amount > 0 THEN

        UPDATE ledger_accounts
        SET
            current_balance = current_balance + v_fee_amount,
            updated_at = now()
        WHERE id = v_fee_income_ledger.id
          AND tenant_id = p_tenant_id;

    END IF;


    -- ========================================================
    -- 29. Update source customer account
    -- ========================================================

    UPDATE accounts
    SET
        ledger_balance =
            ledger_balance - v_total_source_debit,
        available_balance =
            available_balance - v_total_source_debit,
        updated_at = now()
    WHERE id = v_source_account.id
      AND tenant_id = p_tenant_id;


    -- ========================================================
    -- 30. Update destination customer account
    -- ========================================================

    UPDATE accounts
    SET
        ledger_balance =
            ledger_balance + p_amount,
        available_balance =
            available_balance + p_amount,
        updated_at = now()
    WHERE id = v_destination_account.id
      AND tenant_id = p_tenant_id;


    -- ========================================================
    -- 31. Audit
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
            'fee_amount',
                v_fee_amount,
            'total_source_debit',
                v_total_source_debit,
            'source_account_id',
                v_source_account.id,
            'destination_account_id',
                v_destination_account.id,
            'source_balance',
                v_source_account.ledger_balance
                    - v_total_source_debit,
            'destination_balance',
                v_destination_account.ledger_balance
                    + p_amount
        )
    );


    -- ========================================================
    -- 32. Return result
    -- ========================================================

    RETURN QUERY
    SELECT
        v_transaction_id,
        v_transaction_reference,
        v_source_account.id,
        v_destination_account.id,
        p_amount,
        'POSTED'::transaction_status,
        CASE
            WHEN v_fee_amount > 0 THEN
                'Internal transfer posted successfully. Fee charged: '
                || v_fee_amount::text
            ELSE
                'Internal transfer posted successfully'
        END::text;

END;
$function$;

ALTER FUNCTION post_internal_transfer(
    uuid,
    uuid,
    uuid,
    bigint,
    text,
    varchar,
    uuid
) OWNER TO postgres;

REVOKE ALL ON FUNCTION post_internal_transfer(
    uuid,
    uuid,
    uuid,
    bigint,
    text,
    varchar,
    uuid
) FROM PUBLIC;

COMMENT ON FUNCTION post_internal_transfer(
    uuid,
    uuid,
    uuid,
    bigint,
    text,
    varchar,
    uuid
) IS
    'Posts atomic internal transfers with optional configured fees.';