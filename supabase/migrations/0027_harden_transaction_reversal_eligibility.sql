-- 0027_harden_transaction_reversal_eligibility.sql

DROP FUNCTION IF EXISTS post_transaction_reversal(
    uuid,
    uuid,
    uuid,
    text,
    varchar
);

CREATE FUNCTION post_transaction_reversal(
    p_tenant_id uuid,
    p_transaction_id uuid,
    p_created_by uuid,
    p_description text DEFAULT NULL,
    p_idempotency_key varchar DEFAULT NULL
)
RETURNS TABLE (
    original_transaction_id uuid,
    original_reference varchar,
    reversal_transaction_id uuid,
    reversal_reference varchar,
    amount bigint,
    message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_original transactions%ROWTYPE;
    v_reversal_id uuid;
    v_reversal_reference varchar;
    v_entry record;
    v_customer_account_id uuid;
    v_customer_account accounts%ROWTYPE;
    v_ledger_account ledger_accounts%ROWTYPE;
    v_new_balance bigint;
BEGIN

    ----------------------------------------------------------------
    -- 1. Validate creator
    ----------------------------------------------------------------
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


    ----------------------------------------------------------------
    -- 2. Lock original transaction
    ----------------------------------------------------------------
    SELECT t.*
    INTO v_original
    FROM transactions t
    WHERE t.id = p_transaction_id
      AND t.tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found';
    END IF;


    ----------------------------------------------------------------
    -- 3. Only POSTED transactions can be reversed
    ----------------------------------------------------------------
    IF v_original.status <> 'POSTED' THEN
        RAISE EXCEPTION
            'Only POSTED transactions can be reversed. Current status: %',
            v_original.status;
    END IF;


    ----------------------------------------------------------------
    -- 4. BUSINESS REVERSAL ELIGIBILITY
    --
    -- Current supported rules:
    --
    -- DEPOSIT     -> ALLOWED
    -- WITHDRAWAL  -> PROHIBITED
    -- REVERSAL    -> PROHIBITED
    --
    -- Any future transaction type is blocked until explicitly
    -- supported by a business-specific reversal rule.
    ----------------------------------------------------------------
    IF v_original.transaction_type = 'WITHDRAWAL' THEN
        RAISE EXCEPTION
            'Withdrawal transactions cannot be reversed. '
            'Process a new deposit instead';
    END IF;

    IF v_original.transaction_type = 'REVERSAL' THEN
        RAISE EXCEPTION
            'Reversal transactions cannot be reversed';
    END IF;

    IF v_original.transaction_type <> 'DEPOSIT' THEN
        RAISE EXCEPTION
            'Transaction type % is not currently eligible for reversal',
            v_original.transaction_type;
    END IF;


    ----------------------------------------------------------------
    -- 5. Prevent duplicate reversal
    ----------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM transactions t
        WHERE t.tenant_id = p_tenant_id
          AND t.reversal_of_transaction_id = v_original.id
          AND t.status IN ('POSTED', 'REVERSED')
    ) THEN
        RAISE EXCEPTION
            'Transaction % has already been reversed',
            v_original.reference;
    END IF;


    ----------------------------------------------------------------
    -- 6. Idempotency
    ----------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN

        SELECT t.id
        INTO v_reversal_id
        FROM transactions t
        WHERE t.tenant_id = p_tenant_id
          AND t.idempotency_key = p_idempotency_key
        LIMIT 1;

        IF v_reversal_id IS NOT NULL THEN

            SELECT t.reference
            INTO v_reversal_reference
            FROM transactions t
            WHERE t.id = v_reversal_id;

            RETURN QUERY
            SELECT
                v_original.id,
                v_original.reference,
                v_reversal_id,
                v_reversal_reference,
                v_original.amount,
                'Duplicate reversal request'::text;

            RETURN;
        END IF;

    END IF;


    ----------------------------------------------------------------
    -- 7. Generate reversal reference
    ----------------------------------------------------------------
    v_reversal_reference :=
        generate_transaction_reference('REVERSAL');


    ----------------------------------------------------------------
    -- 8. Create reversal transaction
    ----------------------------------------------------------------
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
            p_description,
            'Reversal of ' || v_original.reference
        ),
        COALESCE(
            p_idempotency_key,
            'REV-' || v_original.id::text
        ),
        now(),
        p_created_by,
        v_original.business_date_id,
        v_original.accounting_period_id,
        v_original.value_date,
        v_original.channel,
        v_original.id
    )
    RETURNING id INTO v_reversal_id;


    ----------------------------------------------------------------
    -- 9. Reverse original double-entry postings
    ----------------------------------------------------------------
    FOR v_entry IN
        SELECT te.*
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
            COALESCE(
                v_entry.description,
                'Reversal of ' || v_original.reference
            )
        );


        ----------------------------------------------------------------
        -- Lock ledger account
        ----------------------------------------------------------------
        SELECT la.*
        INTO v_ledger_account
        FROM ledger_accounts la
        WHERE la.id = v_entry.ledger_account_id
          AND la.tenant_id = p_tenant_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Ledger account not found for reversal entry';
        END IF;


        ----------------------------------------------------------------
        -- Calculate new ledger balance
        ----------------------------------------------------------------
        IF v_ledger_account.account_type IN ('ASSET', 'EXPENSE') THEN

            v_new_balance :=
                v_ledger_account.current_balance
                + v_entry.credit
                - v_entry.debit;

        ELSE

            v_new_balance :=
                v_ledger_account.current_balance
                + v_entry.debit
                - v_entry.credit;

        END IF;


        IF v_new_balance < 0 THEN
            RAISE EXCEPTION
                'Reversal would create negative ledger balance for account %',
                v_ledger_account.account_code;
        END IF;


        UPDATE ledger_accounts
        SET current_balance = v_new_balance
        WHERE id = v_entry.ledger_account_id;

    END LOOP;


    ----------------------------------------------------------------
    -- 10. Find linked customer account
    ----------------------------------------------------------------
    SELECT a.*
    INTO v_customer_account
    FROM accounts a
    WHERE a.ledger_account_id IN (
        SELECT te.ledger_account_id
        FROM transaction_entries te
        WHERE te.transaction_id = v_original.id
    )
      AND a.tenant_id = p_tenant_id
    LIMIT 1
    FOR UPDATE;


    IF FOUND THEN

        v_customer_account_id := v_customer_account.id;


        ----------------------------------------------------------------
        -- Deposit reversal:
        --
        -- Original:
        -- Cash       DR
        -- Customer   CR
        --
        -- Reversal:
        -- Customer   DR
        -- Cash       CR
        ----------------------------------------------------------------
        IF v_customer_account.ledger_balance < v_original.amount
           OR v_customer_account.available_balance < v_original.amount THEN

            RAISE EXCEPTION
                'Insufficient customer balance to reverse deposit';

        END IF;


        UPDATE accounts
        SET
            ledger_balance =
                ledger_balance - v_original.amount,
            available_balance =
                available_balance - v_original.amount
        WHERE id = v_customer_account_id;

    ELSE

        RAISE EXCEPTION
            'Customer account linked to deposit transaction was not found';

    END IF;


    ----------------------------------------------------------------
    -- 11. Mark original transaction as REVERSED
    ----------------------------------------------------------------
    UPDATE transactions
    SET status = 'REVERSED'
    WHERE id = v_original.id;


    ----------------------------------------------------------------
    -- 12. Audit
    ----------------------------------------------------------------
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
            'reference',
                v_original.reference,
            'status',
                'POSTED',
            'amount',
                v_original.amount
        ),
        jsonb_build_object(
            'reference',
                v_reversal_reference,
            'status',
                'REVERSED',
            'amount',
                v_original.amount,
            'reversal_transaction_id',
                v_reversal_id
        )
    );


    ----------------------------------------------------------------
    -- 13. Return result
    ----------------------------------------------------------------
    RETURN QUERY
    SELECT
        v_original.id,
        v_original.reference,
        v_reversal_id,
        v_reversal_reference,
        v_original.amount,
        'Transaction reversed successfully'::text;

END;
$$;


ALTER FUNCTION post_transaction_reversal(
    uuid,
    uuid,
    uuid,
    text,
    varchar
) OWNER TO postgres;


REVOKE ALL ON FUNCTION post_transaction_reversal(
    uuid,
    uuid,
    uuid,
    text,
    varchar
) FROM PUBLIC;