-- Migration 018 — memory_sessions.rumen_processed_at column.
--
-- Sprint 53 T2 (Rumen picker rewrite). Adds a tracking column so Rumen's
-- extract phase can pick candidate sessions directly from memory_sessions
-- (one row per Claude Code session, post-Sprint-51.6 bundled hook) and
-- mark them as processed atomically when surface succeeds.
--
-- Why a column not a separate table: the picker hot path is "give me the
-- N most recent sessions Rumen hasn't seen yet." A boolean/timestamp on
-- memory_sessions answers that with one filtered range scan; a separate
-- rumen_processed table would force a NOT EXISTS / LEFT JOIN per tick.
--
-- Why timestamptz not boolean: the timestamp doubles as a debug aid
-- ("when did Rumen last touch this session?") and lets a future backfill
-- script identify the cutoff between pre-Sprint-53 (NULL — never touched
-- by the new picker) and post-Sprint-53 (stamped) without an extra column.
--
-- Idempotent — safe on:
--   1. Joshua's daily-driver (pre-Sprint-53; column will be added with
--      every existing memory_sessions row at NULL → all become candidates
--      on the first post-deploy tick, which is the desired bootstrap).
--   2. Brad's jizzard-brain (Linux SSH; same shape, same null-bootstrap).
--   3. Fresh canonical installs (post-mig-017 schema; column added on
--      first run, no rows to backfill).
--   4. Re-runs (ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS).
--
-- The partial index is the picker's hot path: SELECT … WHERE
-- rumen_processed_at IS NULL AND ended_at IS NOT NULL ORDER BY started_at DESC.
-- Indexing only NULL rows keeps the index tiny (hundreds of rows at any
-- given moment, since stamped rows drop out) — much smaller than a full
-- B-tree on rumen_processed_at would be.

alter table public.memory_sessions
  add column if not exists rumen_processed_at timestamptz;

-- Partial index — covers only unprocessed sessions, ordered by recency.
-- Picker query plan: index range scan on the partial index, no seqscan.
create index if not exists memory_sessions_rumen_unprocessed_idx
  on public.memory_sessions(started_at desc nulls last)
  where rumen_processed_at is null;
