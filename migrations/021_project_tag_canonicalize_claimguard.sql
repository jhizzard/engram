-- 021_project_tag_canonicalize_claimguard.sql
-- Sprint 62 T2 — finishes the gorgias / gorgias-ticket-monitor → claimguard
-- rename that migration 012 (Sprint 41 T2) explicitly scoped out.
--
-- Why this exists:
--   Same project (the ClaimGuard repo at ~/Documents/Unagi/gorgias-ticket-monitor)
--   was tagged three ways across history. As of 2026-05-08:
--     - 'claimguard'              ~29 rows  (newest tag, written by the
--                                            post-Sprint-41 PROJECT_MAP)
--     - 'gorgias-ticket-monitor' ~245 rows  (mid tag, the on-disk dir name)
--     - 'gorgias'                ~541 rows  (oldest tag, pre-Sprint-41)
--
--   Migration 012's §"What this migration does NOT do" called out the merge
--   as a separate cleanup pass:
--
--     - Does NOT consolidate duplicate tags like 'gorgias' vs
--       'gorgias-ticket-monitor', 'pvb' vs 'PVB', or 'mnestra' vs 'engram'.
--       Visible in `SELECT project, count(*) FROM memory_items GROUP BY
--       project` but a separate cleanup pass.
--
--   That separate pass is 021. Sprint 21 T2's earlier rename plan never
--   landed; Sprint 35's harness-hook fix addressed the upstream PROJECT_MAP
--   so new rows tag correctly, and Sprint 62 T2 (this migration) closes the
--   historical-corpus gap so memory_recall(project="claimguard") returns the
--   full ~815-row history rather than just the post-Sprint-41 tail.
--
-- The companion T2 invariant test at
-- termdeck/tests/project-tag-invariant.test.js currently skips the claimguard
-- invariant via `deferredToSprint35`; with 021 applied that invariant would
-- pass cleanly if un-deferred. Un-deferring is out of T2's lane (test edits
-- are owned by orchestrator close-out).
--
-- Why the *project*-column merge and not a content-keyword rebucket: rows
-- already-tagged 'gorgias' or 'gorgias-ticket-monitor' carry definitive
-- project provenance — the row is from the ClaimGuard project by virtue of
-- the writer's prior tag, regardless of content keywords. We are not
-- inferring; we are renaming an exact-match tag set that the SOURCE-BRIEF
-- and 012's prologue both confirm refer to the same on-disk codebase.
--
-- Idempotence:
--   The UPDATE is gated by `WHERE project IN ('gorgias','gorgias-ticket-monitor')`.
--   After the first apply those rows carry project='claimguard', so a re-run
--   matches zero rows — RAISE NOTICE prints 0 and the migration succeeds. The
--   bundled migration runner (packages/server/src/setup/migration-runner.js)
--   also checksums applied migrations into mnestra_migrations (table from
--   020) and skips re-application by filename, so the in-runner path is
--   idempotent at two layers.
--
-- RLS posture:
--   memory_items has RLS enabled (per migration 019 security hardening), but
--   service_role bypasses RLS. The migration runner authenticates as
--   service_role via DATABASE_URL, so the UPDATE lands without policy
--   changes. This migration does NOT touch policies or roles.
--
-- Reversibility:
--   Down-migration is documented at the bottom (commented). Splitting the
--   merged set back into three is destructive — once project='claimguard'
--   replaces the prior values, the row provenance for which tag it ORIGINALLY
--   carried is gone (no audit column tracks pre-image). Reversal requires
--   restore from a pg_dump snapshot taken before the migration was applied.
--   Do NOT attempt heuristic reversal.
--
-- Application:
--   Applied via the bundled migration runner using node-postgres
--   client.query(). DO blocks + GET DIAGNOSTICS ROW_COUNT (no psql
--   metacommands — \gset / \echo / etc are not supported in client.query).
--   Manual fallback: `psql "$DATABASE_URL" -f 021_project_tag_canonicalize_claimguard.sql`.

BEGIN;

-- ============================================================
-- AUDIT BEFORE
-- ============================================================
DO $$
DECLARE
  before_claimguard               int;
  before_gorgias                  int;
  before_gorgias_ticket_monitor   int;
  before_total_three              int;
BEGIN
  SELECT count(*) INTO before_claimguard
    FROM public.memory_items WHERE project = 'claimguard';
  SELECT count(*) INTO before_gorgias
    FROM public.memory_items WHERE project = 'gorgias';
  SELECT count(*) INTO before_gorgias_ticket_monitor
    FROM public.memory_items WHERE project = 'gorgias-ticket-monitor';
  before_total_three := before_claimguard + before_gorgias + before_gorgias_ticket_monitor;
  RAISE NOTICE '[021-canonicalize] BEFORE  claimguard=% gorgias=% gorgias-ticket-monitor=%  (sum=%)',
    before_claimguard, before_gorgias, before_gorgias_ticket_monitor, before_total_three;
END $$;

-- ============================================================
-- CANONICALIZE — gorgias + gorgias-ticket-monitor → claimguard
--
-- Single-statement UPDATE on the project column. No content scoping required:
-- the source tags refer unambiguously to the ClaimGuard project per Sprint 41
-- T2's analysis (012's prologue) and the SOURCE-BRIEF for Sprint 62 §1.
-- ============================================================
DO $$
DECLARE
  affected_count integer;
BEGIN
  UPDATE public.memory_items
     SET project = 'claimguard'
   WHERE project IN ('gorgias', 'gorgias-ticket-monitor');
  GET DIAGNOSTICS affected_count = ROW_COUNT;
  RAISE NOTICE '[021-canonicalize] canonicalized % memory_items rows  (gorgias + gorgias-ticket-monitor) -> claimguard',
    affected_count;
END $$;

-- ============================================================
-- AUDIT AFTER + CONSERVATION CHECK
-- ============================================================
DO $$
DECLARE
  after_claimguard               int;
  after_gorgias                  int;
  after_gorgias_ticket_monitor   int;
BEGIN
  SELECT count(*) INTO after_claimguard
    FROM public.memory_items WHERE project = 'claimguard';
  SELECT count(*) INTO after_gorgias
    FROM public.memory_items WHERE project = 'gorgias';
  SELECT count(*) INTO after_gorgias_ticket_monitor
    FROM public.memory_items WHERE project = 'gorgias-ticket-monitor';
  RAISE NOTICE '[021-canonicalize] AFTER   claimguard=% gorgias=% gorgias-ticket-monitor=%',
    after_claimguard, after_gorgias, after_gorgias_ticket_monitor;
  IF after_gorgias <> 0 OR after_gorgias_ticket_monitor <> 0 THEN
    RAISE EXCEPTION
      '[021-canonicalize] post-apply invariant violated: expected zero rows in gorgias / gorgias-ticket-monitor, got gorgias=% gorgias-ticket-monitor=%',
      after_gorgias, after_gorgias_ticket_monitor;
  END IF;
END $$;

COMMIT;

-- ============================================================
-- POST-APPLY: verification queries (NOT part of the migration; run separately
-- to confirm the merge took, the invariant tests stay green, and the recall
-- path returns the full history). Each query is safe to run repeatedly.
-- ============================================================
--
-- 1. Tag distribution after migration — claimguard should be the only
--    bucket among the three; gorgias / gorgias-ticket-monitor should be 0:
--      SELECT project, count(*) FROM public.memory_items
--       WHERE project IN ('claimguard', 'gorgias', 'gorgias-ticket-monitor')
--       GROUP BY project ORDER BY project;
--
-- 2. Confirm no orphan rows remain under either legacy tag (these should
--    return 0):
--      SELECT count(*) FROM public.memory_items
--       WHERE project IN ('gorgias', 'gorgias-ticket-monitor');
--
-- 3. Spot-check that the merged set carries content from all three
--    historical eras (look for varied dates, varied source_types):
--      SELECT date_trunc('week', created_at) AS week, count(*)
--        FROM public.memory_items
--       WHERE project = 'claimguard'
--       GROUP BY 1 ORDER BY 1;
--
-- 4. Confirm the project-tag invariant test for claimguard would now pass
--    if un-deferred (rows whose content matches gorgias-ticket-monitor or
--    Unagi/ identifiers should be top-tagged claimguard):
--      SELECT project, count(*) FROM public.memory_items
--       WHERE content ILIKE '%gorgias-ticket-monitor%'
--          OR content ILIKE '%Unagi/%'
--       GROUP BY project ORDER BY count(*) DESC LIMIT 5;
--
-- DOWN-MIGRATION (manual, NOT auto-applied):
--   Splitting the merged set back into three is non-trivial (no source-of-
--   truth on which rows were originally which tag — provenance is lost when
--   the UPDATE replaces the project string). If a roll-back is needed,
--   restore from a pg_dump taken before this migration was applied. Do NOT
--   attempt to reverse via heuristic — the row provenance is destroyed by
--   the merge.
