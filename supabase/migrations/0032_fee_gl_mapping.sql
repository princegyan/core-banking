-- ============================================================
-- 0032_fee_gl_mapping.sql
-- Fee GL Mapping
-- ============================================================

CREATE TABLE fee_gl_mappings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL
        REFERENCES tenants(id)
        ON DELETE CASCADE,

    fee_id uuid NOT NULL
        REFERENCES fees(id)
        ON DELETE CASCADE,

    fee_income_ledger_account_id uuid NOT NULL
        REFERENCES ledger_accounts(id)
        ON DELETE RESTRICT,

    is_active boolean NOT NULL DEFAULT true,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fee_gl_mapping_unique
        UNIQUE (tenant_id, fee_id)
);

CREATE INDEX fee_gl_mappings_tenant_idx
    ON fee_gl_mappings (tenant_id);

CREATE INDEX fee_gl_mappings_fee_idx
    ON fee_gl_mappings (fee_id);

CREATE INDEX fee_gl_mappings_ledger_idx
    ON fee_gl_mappings (fee_income_ledger_account_id);

CREATE TRIGGER set_fee_gl_mappings_updated_at
    BEFORE UPDATE ON fee_gl_mappings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

COMMENT ON TABLE fee_gl_mappings IS
    'Maps configured fees to their income GL accounts.';