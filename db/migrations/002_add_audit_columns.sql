-- 002_add_audit_columns.sql
--
-- Adds audit columns to live tables.
--
-- Deliberately nullable with a default rather than NOT NULL. On PostgreSQL
-- versions before 11, adding a NOT NULL column with a default rewrites the
-- whole table while holding an ACCESS EXCLUSIVE lock — which means downtime
-- proportional to table size. Nullable now, backfilled and tightened in a
-- later migration, is the safe sequence.

ALTER TABLE app.tenant
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_by TEXT;

ALTER TABLE app.service_event
    ADD COLUMN IF NOT EXISTS correlation_id UUID;

-- Note: CREATE INDEX CONCURRENTLY cannot run inside a transaction block, and
-- this runner wraps each file in one. Concurrent index builds therefore need
-- their own migration file with the transaction disabled, or a maintenance
-- window. A plain CREATE INDEX is used here because the table is small at
-- this point in the schema's life.
CREATE INDEX IF NOT EXISTS ix_service_event_correlation
    ON app.service_event (correlation_id);
