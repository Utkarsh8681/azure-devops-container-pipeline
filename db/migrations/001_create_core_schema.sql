-- 001_create_core_schema.sql
--
-- Baseline schema. Written idempotently (IF NOT EXISTS) so it is safe to run
-- against an environment provisioned before the tracking table existed.

CREATE SCHEMA IF NOT EXISTS app;

CREATE TABLE IF NOT EXISTS app.tenant (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        TEXT        NOT NULL UNIQUE,
    name        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS app.service_event (
    id          BIGSERIAL   PRIMARY KEY,
    tenant_id   UUID        NOT NULL REFERENCES app.tenant(id) ON DELETE CASCADE,
    event_type  TEXT        NOT NULL,
    payload     JSONB       NOT NULL DEFAULT '{}'::jsonb,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Composite index ordered to match the dominant access pattern: recent
-- events for a single tenant. Leading with tenant_id allows the index to
-- serve both the filter and the sort.
CREATE INDEX IF NOT EXISTS ix_service_event_tenant_recent
    ON app.service_event (tenant_id, occurred_at DESC);
