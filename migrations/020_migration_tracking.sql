-- 020_migration_tracking.sql
-- Adds durable tracking of which Mnestra migrations have been applied to a project,
-- so upgrade paths can compute (bundled - applied) and apply only the diff.
-- Sprint 61 (TermDeck Convergence Keystone), Mnestra 0.4.7.
--
-- Why this exists: prior to 020, the mnestra/rumen wizards re-applied every
-- bundled migration on every invocation, relying on per-migration
-- `IF NOT EXISTS` / `CREATE OR REPLACE` idempotency to avoid duplicate work.
-- That works for a fresh install but doesn't tell the wizard which migrations
-- the live database is missing — so a user running `npm install -g @latest`
-- against an existing project gets the new package files without any way to
-- detect schema drift. Class A (schema drift on package upgrade) per
-- termdeck/docs/INSTALLER-PITFALLS.md.
--
-- Shape:
--   - `filename`        text PK — the bundled migration filename, e.g.
--                                 `015_source_agent.sql`. PK because each
--                                 bundled file applies at most once.
--   - `applied_at`      timestamptz — wall-clock time of apply. Backfilled
--                                 rows (rows seeded by the post-020 backfill
--                                 probe for migrations applied pre-020) use
--                                 epoch (1970-01-01T00:00:00Z) as a sentinel.
--   - `checksum`        text — SHA-256 of the bundled file content at apply
--                                 time. Lets future runs detect bundle drift
--                                 without auto-overwriting the live schema.
--   - `schema_version`  text — optional free-text marker. Backfill rows use
--                                 the literal `'backfill'` so audit queries
--                                 can distinguish them.
--
-- RLS posture: ENABLE ROW LEVEL SECURITY + REVOKE ALL FROM PUBLIC. No
-- policies are intentional — anon and authenticated have NO access, full
-- stop. service_role bypasses RLS in Postgres by default, which is the only
-- caller that should ever touch this table (the migration runner connects
-- via DATABASE_URL using service-role credentials).
--
-- Idempotent: re-applying this migration on a project that already has the
-- table is a no-op (CREATE TABLE IF NOT EXISTS, ALTER TABLE ... ENABLE RLS
-- is a no-op when already enabled, REVOKE/GRANT are idempotent).

CREATE TABLE IF NOT EXISTS public.mnestra_migrations (
  filename       text PRIMARY KEY,
  applied_at     timestamptz NOT NULL DEFAULT now(),
  checksum       text NOT NULL,
  schema_version text
);

ALTER TABLE public.mnestra_migrations ENABLE ROW LEVEL SECURITY;

-- Service-role-only. anon and authenticated have NO access (no policies = denied by RLS).
-- Service role bypasses RLS by default; the table is queried only by the migration runner
-- which uses the service-role key.

REVOKE ALL ON public.mnestra_migrations FROM PUBLIC;
GRANT  ALL ON public.mnestra_migrations TO service_role;

COMMENT ON TABLE public.mnestra_migrations IS
  'Tracking table for applied Mnestra migrations. service_role-only; RLS-on; no policies.';
