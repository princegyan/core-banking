-- ============================================================
-- Notifications
-- ============================================================
BEGIN;

-- ----------------------------------------------------------
-- Tables
-- ----------------------------------------------------------

CREATE TABLE notification_templates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    code varchar(50) NOT NULL,
    name varchar(150) NOT NULL,
    channel varchar NOT NULL CHECK (channel IN ('SMS','EMAIL','PUSH','IN_APP')),
    subject varchar(255),
    body_template text NOT NULL,
    variables jsonb DEFAULT '[]'::jsonb,
    event_trigger varchar CHECK (event_trigger IN ('DEPOSIT','WITHDRAWAL','TRANSFER','LOAN_DISBURSEMENT','LOAN_REPAYMENT','LOAN_OVERDUE','APPROVAL_REQUIRED','APPROVAL_COMPLETED','ACCOUNT_OPENED','ACCOUNT_CLOSED','PASSWORD_CHANGE','LOGIN_ALERT')),
    is_active boolean DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code, channel)
);
CREATE TRIGGER update_notification_templates_updated_at BEFORE UPDATE ON notification_templates FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TABLE notification_preferences (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    customer_id uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    channel varchar NOT NULL CHECK (channel IN ('SMS','EMAIL','PUSH','IN_APP')),
    is_enabled boolean DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, customer_id, channel)
);
CREATE TRIGGER update_notification_preferences_updated_at BEFORE UPDATE ON notification_preferences FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TABLE notification_queue (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    template_id uuid REFERENCES notification_templates(id),
    channel varchar NOT NULL CHECK (channel IN ('SMS','EMAIL','PUSH','IN_APP')),
    recipient_type varchar NOT NULL CHECK (recipient_type IN ('CUSTOMER','USER')),
    recipient_id uuid NOT NULL,
    recipient_address varchar(255) NOT NULL,
    subject varchar(255),
    body text NOT NULL,
    variables jsonb,
    priority varchar DEFAULT 'NORMAL' CHECK (priority IN ('LOW','NORMAL','HIGH','URGENT')),
    status varchar NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','PROCESSING','SENT','DELIVERED','FAILED','CANCELLED')),
    scheduled_at timestamptz DEFAULT now(),
    sent_at timestamptz,
    delivered_at timestamptz,
    failed_at timestamptz,
    failure_reason text,
    retry_count integer DEFAULT 0,
    max_retries integer DEFAULT 3,
    reference_type varchar(100),
    reference_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER update_notification_queue_updated_at BEFORE UPDATE ON notification_queue FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TABLE notification_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    notification_queue_id uuid REFERENCES notification_queue(id) ON DELETE CASCADE,
    event_type varchar NOT NULL CHECK (event_type IN ('QUEUED','SENT','DELIVERED','FAILED','RETRIED')),
    event_data jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------
-- Indexes
-- ----------------------------------------------------------
CREATE INDEX idx_notification_queue_tenant_status_sched ON notification_queue(tenant_id, status, scheduled_at);
CREATE INDEX idx_notification_queue_recipient ON notification_queue(recipient_id);
CREATE INDEX idx_notification_log_tenant_created ON notification_log(tenant_id, created_at DESC);

-- ----------------------------------------------------------
-- Functions
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION queue_notification(
    p_tenant_id uuid,
    p_template_code varchar,
    p_channel varchar,
    p_recipient_type varchar,
    p_recipient_id uuid,
    p_recipient_address varchar,
    p_variables jsonb DEFAULT '{}'::jsonb,
    p_reference_type varchar DEFAULT NULL,
    p_reference_id uuid DEFAULT NULL,
    p_priority varchar DEFAULT 'NORMAL'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_template_id uuid;
    v_subject text;
    v_body text;
    v_queue_id uuid;
    v_is_enabled boolean;
    v_key text;
    v_val text;
BEGIN
    -- Check customer preference if applicable
    IF p_recipient_type = 'CUSTOMER' THEN
        SELECT is_enabled INTO v_is_enabled
        FROM notification_preferences
        WHERE tenant_id = p_tenant_id AND customer_id = p_recipient_id AND channel = p_channel;
        
        IF v_is_enabled IS NOT NULL AND v_is_enabled = false THEN
            RETURN jsonb_build_object('success', false, 'message', 'Customer has disabled notifications for this channel');
        END IF;
    END IF;

    -- Resolve template
    SELECT id, subject, body_template INTO v_template_id, v_subject, v_body
    FROM notification_templates
    WHERE tenant_id = p_tenant_id AND code = p_template_code AND channel = p_channel AND is_active = true;

    IF v_template_id IS NULL THEN
        RAISE EXCEPTION 'Active notification template % for channel % not found', p_template_code, p_channel;
    END IF;

    -- Render body with variables
    IF p_variables IS NOT NULL THEN
        FOR v_key, v_val IN SELECT key, value::text FROM jsonb_each_text(p_variables) LOOP
            v_body := replace(v_body, '{{' || v_key || '}}', v_val);
            IF v_subject IS NOT NULL THEN
                v_subject := replace(v_subject, '{{' || v_key || '}}', v_val);
            END IF;
        END LOOP;
    END IF;

    INSERT INTO notification_queue (
        tenant_id, template_id, channel, recipient_type, recipient_id, recipient_address,
        subject, body, variables, priority, status, reference_type, reference_id
    ) VALUES (
        p_tenant_id, v_template_id, p_channel, p_recipient_type, p_recipient_id, p_recipient_address,
        v_subject, v_body, p_variables, p_priority, 'QUEUED', p_reference_type, p_reference_id
    ) RETURNING id INTO v_queue_id;

    INSERT INTO notification_log (tenant_id, notification_queue_id, event_type, event_data)
    VALUES (p_tenant_id, v_queue_id, 'QUEUED', jsonb_build_object('channel', p_channel, 'priority', p_priority));

    RETURN jsonb_build_object('success', true, 'notification_id', v_queue_id);
END;
$$;
ALTER FUNCTION queue_notification OWNER TO postgres;

CREATE OR REPLACE FUNCTION process_notification_queue(
    p_tenant_id uuid,
    p_batch_size integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_notifications jsonb;
BEGIN
    WITH next_batch AS (
        SELECT id
        FROM notification_queue
        WHERE tenant_id = p_tenant_id 
          AND status = 'QUEUED'
          AND scheduled_at <= now()
        ORDER BY 
            CASE priority 
                WHEN 'URGENT' THEN 1
                WHEN 'HIGH' THEN 2
                WHEN 'NORMAL' THEN 3
                WHEN 'LOW' THEN 4
            END ASC,
            scheduled_at ASC
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    ),
    updated AS (
        UPDATE notification_queue q
        SET status = 'PROCESSING', updated_at = now()
        FROM next_batch nb
        WHERE q.id = nb.id
        RETURNING q.id, q.channel, q.recipient_type, q.recipient_id, q.recipient_address, q.subject, q.body, q.priority, q.retry_count
    )
    SELECT COALESCE(jsonb_agg(row_to_json(updated)), '[]'::jsonb) INTO v_notifications FROM updated;

    RETURN v_notifications;
END;
$$;
ALTER FUNCTION process_notification_queue OWNER TO postgres;

CREATE OR REPLACE FUNCTION mark_notification_sent(
    p_tenant_id uuid,
    p_notification_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE notification_queue
    SET status = 'SENT',
        sent_at = now(),
        updated_at = now()
    WHERE id = p_notification_id AND tenant_id = p_tenant_id;

    IF FOUND THEN
        INSERT INTO notification_log (tenant_id, notification_queue_id, event_type)
        VALUES (p_tenant_id, p_notification_id, 'SENT');
        RETURN jsonb_build_object('success', true);
    ELSE
        RAISE EXCEPTION 'Notification not found';
    END IF;
END;
$$;
ALTER FUNCTION mark_notification_sent OWNER TO postgres;

CREATE OR REPLACE FUNCTION mark_notification_failed(
    p_tenant_id uuid,
    p_notification_id uuid,
    p_failure_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_retry_count integer;
    v_max_retries integer;
    v_new_status varchar;
BEGIN
    SELECT retry_count, max_retries INTO v_retry_count, v_max_retries
    FROM notification_queue
    WHERE id = p_notification_id AND tenant_id = p_tenant_id;

    IF v_retry_count IS NULL THEN
        RAISE EXCEPTION 'Notification not found';
    END IF;

    IF v_retry_count >= v_max_retries THEN
        v_new_status := 'FAILED';
    ELSE
        v_new_status := 'QUEUED';
    END IF;

    UPDATE notification_queue
    SET status = v_new_status,
        failure_reason = p_failure_reason,
        failed_at = CASE WHEN v_new_status = 'FAILED' THEN now() ELSE null END,
        retry_count = retry_count + 1,
        scheduled_at = CASE WHEN v_new_status = 'QUEUED' THEN now() + interval '5 minutes' ELSE scheduled_at END,
        updated_at = now()
    WHERE id = p_notification_id AND tenant_id = p_tenant_id;

    INSERT INTO notification_log (tenant_id, notification_queue_id, event_type, event_data)
    VALUES (
        p_tenant_id, 
        p_notification_id, 
        CASE WHEN v_new_status = 'FAILED' THEN 'FAILED' ELSE 'RETRIED' END,
        jsonb_build_object('failure_reason', p_failure_reason, 'retry_count', v_retry_count + 1)
    );

    RETURN jsonb_build_object('success', true, 'status', v_new_status);
END;
$$;
ALTER FUNCTION mark_notification_failed OWNER TO postgres;

CREATE OR REPLACE FUNCTION get_notification_history(
    p_tenant_id uuid,
    p_recipient_id uuid,
    p_limit integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_history jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(row_to_json(q)), '[]'::jsonb) INTO v_history
    FROM (
        SELECT id, channel, subject, body, status, sent_at, created_at, priority
        FROM notification_queue
        WHERE tenant_id = p_tenant_id AND recipient_id = p_recipient_id
        ORDER BY created_at DESC
        LIMIT p_limit
    ) q;

    RETURN v_history;
END;
$$;
ALTER FUNCTION get_notification_history OWNER TO postgres;

-- ----------------------------------------------------------
-- Comments
-- ----------------------------------------------------------
COMMENT ON TABLE notification_templates IS 'Notification templates for all channels';
COMMENT ON TABLE notification_preferences IS 'Customer preferences for notifications';
COMMENT ON TABLE notification_queue IS 'Queue for outbound notifications';
COMMENT ON TABLE notification_log IS 'Event log for notifications';

COMMIT;
