-- ============================================================
-- 0033_fee_calculation_engine.sql
-- Fee Calculation Engine
-- ============================================================

CREATE OR REPLACE FUNCTION calculate_fee(
    p_tenant_id uuid,
    p_fee_code varchar,
    p_transaction_amount bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_fee fees%ROWTYPE;
    v_calculated_fee bigint;
BEGIN
    IF p_transaction_amount <= 0 THEN
        RAISE EXCEPTION
            'Transaction amount must be greater than zero';
    END IF;

    SELECT f.*
    INTO v_fee
    FROM fees f
    WHERE f.tenant_id = p_tenant_id
      AND f.code = p_fee_code
      AND f.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Active fee configuration not found: %',
            p_fee_code;
    END IF;

    IF v_fee.calculation_type = 'FIXED' THEN

        v_calculated_fee := v_fee.amount;

    ELSIF v_fee.calculation_type = 'PERCENTAGE' THEN

        -- amount is stored in basis points:
        -- 100 = 1%
        -- 250 = 2.5%
        v_calculated_fee :=
            CEIL(
                (
                    p_transaction_amount::numeric
                    * v_fee.amount::numeric
                ) / 10000
            )::bigint;

    ELSE
        RAISE EXCEPTION
            'Unsupported fee calculation type: %',
            v_fee.calculation_type;
    END IF;

    IF v_fee.minimum_amount IS NOT NULL
       AND v_calculated_fee < v_fee.minimum_amount THEN

        v_calculated_fee := v_fee.minimum_amount;

    END IF;

    IF v_fee.maximum_amount IS NOT NULL
       AND v_calculated_fee > v_fee.maximum_amount THEN

        v_calculated_fee := v_fee.maximum_amount;

    END IF;

    RETURN v_calculated_fee;
END;
$$;

ALTER FUNCTION calculate_fee(
    uuid,
    varchar,
    bigint
) OWNER TO postgres;

REVOKE ALL ON FUNCTION calculate_fee(
    uuid,
    varchar,
    bigint
) FROM PUBLIC;

COMMENT ON FUNCTION calculate_fee(
    uuid,
    varchar,
    bigint
) IS
    'Calculates a configured tenant fee in minor currency units.';