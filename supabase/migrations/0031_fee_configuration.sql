-- ============================================================
-- 0031_fee_configuration.sql
-- Fee & Charge Configuration Foundation
-- ============================================================

CREATE TYPE fee_calculation_type AS ENUM (
    'FIXED',
    'PERCENTAGE'
);

CREATE TABLE fees (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL
        REFERENCES tenants(id)
        ON DELETE CASCADE,

    product_id uuid NULL
        REFERENCES account_products(id)
        ON DELETE RESTRICT,

    code varchar(50) NOT NULL,
    name varchar(150) NOT NULL,
    description text,

    calculation_type fee_calculation_type NOT NULL,

    -- Fixed amount stored in minor units.
    -- Percentage stored as basis points:
    -- 100 = 1%, 250 = 2.5%, etc.
    amount bigint NOT NULL DEFAULT 0,

    minimum_amount bigint NULL,
    maximum_amount bigint NULL,

    transaction_type varchar(50) NULL,

    currency varchar(3) NOT NULL DEFAULT 'GHS',

    is_active boolean NOT NULL DEFAULT true,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fees_amount_nonnegative
        CHECK (amount >= 0),

    CONSTRAINT fees_minimum_nonnegative
        CHECK (
            minimum_amount IS NULL
            OR minimum_amount >= 0
        ),

    CONSTRAINT fees_maximum_nonnegative
        CHECK (
            maximum_amount IS NULL
            OR maximum_amount >= 0
        ),

    CONSTRAINT fees_minimum_maximum_valid
        CHECK (
            minimum_amount IS NULL
            OR maximum_amount IS NULL
            OR minimum_amount <= maximum_amount
        ),

    CONSTRAINT fees_percentage_valid
        CHECK (
            calculation_type <> 'PERCENTAGE'
            OR amount <= 10000
        )
);

CREATE UNIQUE INDEX fees_tenant_code_unique
    ON fees (tenant_id, code);

CREATE INDEX fees_tenant_idx
    ON fees (tenant_id);

CREATE INDEX fees_product_idx
    ON fees (tenant_id, product_id);

CREATE INDEX fees_transaction_type_idx
    ON fees (tenant_id, transaction_type);

CREATE INDEX fees_active_idx
    ON fees (tenant_id, is_active);

CREATE TRIGGER set_fees_updated_at
    BEFORE UPDATE ON fees
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

COMMENT ON TABLE fees IS
    'Tenant-scoped fee and charge configuration.';

COMMENT ON COLUMN fees.amount IS
    'Fixed fee in minor currency units, or percentage in basis points where 100 = 1%.';