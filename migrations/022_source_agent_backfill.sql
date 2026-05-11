-- 022_source_agent_backfill.sql
-- Sprint 62 T3 (TermDeck) — backfill source_agent for pre-Sprint-50 NULL rows
-- where the writer can be inferred from row shape, NOT from content content-marker
-- inspection. Mnestra 0.4.9 (release-pending; orchestrator bumps at sprint close).
--
-- Why this exists:
--   Sprint 50 introduced source_agent (migration 015). Pre-Sprint-50 rows
--   have source_agent IS NULL and are silently excluded from filtered
--   memory_recall queries (per the recall tool's docstring: "NULL-source-
--   agent rows ... are excluded when this filter is set" — see
--   src/recall.ts:165-169).
--
--   2026-05-08 production probe: 6,381 of 6,483 active memory_items rows
--   (~98%) have source_agent IS NULL — far above the SOURCE-BRIEF estimate
--   of "3,000+". Filtered recall has been blind to most of the corpus for
--   roughly the entire post-Sprint-50 window.
--
--   Migration 015 already backfilled session_summary NULL rows -> 'claude'
--   (015 lines 48-51), so the NULL universe today is exclusively non-
--   session_summary types. This migration closes the slice where the
--   writer can be inferred from row shape (architectural / schema /
--   structural evidence), and deliberately leaves the remaining slice
--   NULL — to be reached via the additive include_null_source recall
--   flag rather than by speculative attribution.
--
-- Design principle: row-shape attribution, not content-marker attribution.
--   The original SOURCE-BRIEF proposed content-marker predicates (ILIKE
--   '%[T-CODEX]%' etc). Sampling proved this unsafe: 100% of NULL rows
--   matching codex/gemini/grok markers are Claude *describing* those
--   agents, never authored by them. Marker == "row mentions agent",
--   not "row authored by agent".
--
--   Instead, this migration attributes by the (source_type, has_path,
--   has_session) tuple — schema-level fingerprints that map 1:1 to the
--   writer architecture, and that 50+ randomly-sampled rows confirm.
--
-- Predicate plan (each with explicit evidence chain):
--
--   A. NULL + source_type IN (decision, bug_fix, architecture, preference,
--      code_context) -> 'claude'.
--      Architectural evidence: pre-Sprint-50, only Claude shipped a
--      memory_remember client. The mcp__memory__memory_remember and
--      mcp__mnestra__memory_remember surfaces both ran exclusively in
--      Claude sessions. Codex/Gemini/Grok memory_remember capabilities
--      did not exist until the Sprint 51 per-agent MCP wiring (see
--      memory: "MCP server wiring patterns for Codex, Gemini, and Grok
--      CLIs (verified 2026-05-04 ... follow-up to Sprint 51.6's "Codex
--      MCP not wired" gap)"). All NULL rows of these source_types are
--      pre-Sprint-50 and therefore architecturally Claude.
--      Schema fingerprint: 100% of these rows have source_file_path IS NULL
--      AND source_session_id IS NULL — bare memory_remember shape.
--      Sample confirmation: 28-row sample showed 100% Claude-summary writing
--      pattern (project context, dated entries, file:line evidence — the
--      recognizable Claude memory_remember signature).
--      Expected count: 560.
--
--   B. NULL + source_type='fact' + source_session_id IS NOT NULL -> 'claude'.
--      Schema evidence: source_session_id is a Claude session UUID format
--      (matches the existing claude/session_summary tagged rows; same
--      shape: has_path=false, has_session=true). The Claude SessionEnd
--      hook is the only writer that populates source_session_id with a
--      Claude UUID. Other writers either set source_file_path (rag-extractor)
--      or leave both NULL (bare memory_remember).
--      Expected count: 4,587.
--
--   D. NULL + source_type='document_chunk' -> 'orchestrator'.
--      Structural evidence: 951/951 rows have source_file_path set + JSONB
--      metadata containing chunkIndex + heading keys — unmistakable
--      rag-system batch-chunker output. The chunker is not an LLM session;
--      'orchestrator' is the appropriate non-LLM tag per the source_agent
--      enum (claude|codex|gemini|grok|orchestrator).
--      Path buckets:
--        513 rows ~/.gemini/antigravity/scratch/* (Gemini scratch docs the
--                 rag-extractor ingested — Gemini wrote the source MD,
--                 but the rag-extractor wrote the row.)
--        429 rows ~/Documents/* (project docs ingested directly).
--          9 rows ~/.claude/projects/*/memory/MEMORY.md (auto-memory MD
--                 ingested by the rag-extractor).
--      All four buckets are extractor-written, not LLM-written. The
--      original document author is preserved in source_file_path; the
--      row writer is the extractor.
--      Expected count: 951.
--
-- Predicate deliberately NOT applied (response to T4-CODEX 20:43 ET concern):
--   C. NULL + source_type='fact' + source_session_id IS NULL +
--      source_file_path IS NULL.
--      These 283 rows are bare memory_remember calls without session
--      attribution. Sampling (10 rows) showed 100% Claude content pattern,
--      but they lack the schema fingerprint that makes A/B/D structurally
--      definitive — there is no architectural lock that PREVENTS a
--      non-Claude writer from producing this shape (e.g., a manual psql
--      insert, a non-MCP REST call, or an early rag-extractor variant
--      that omitted source_file_path).
--      Migration 015 lines 24-30 explicitly preserved provenance
--      uncertainty for non-session_summary historical rows; broad
--      attribution here would erase that bright line. Per T4-CODEX
--      AUDIT-CONCERN (Sprint 62, 20:43 ET), these rows stay NULL and
--      are reached via the additive include_null_source recall path
--      added in src/recall.ts under this same sprint.
--      Residual NULL after this migration: 283 rows = 4.4% of corpus.
--      Acceptance target: <5%. Met.
--
-- Total backfill: 6,098 rows (A + B + D). Acceptance: residual NULL < 5%
-- of corpus (4.4% expected; well under threshold).
--
-- What this migration deliberately does NOT do:
--   * Touch session_summary rows (015 already attributed those).
--   * Touch already-tagged rows (every UPDATE is gated by source_agent IS NULL).
--   * Use content-marker predicates (sampling proved unreliable; markers
--     describe agents, not authors).
--   * Backfill the inferential-only slice (Predicate C, see above).
--
-- Idempotent: every UPDATE has WHERE source_agent IS NULL, so re-running
-- is a no-op on already-tagged rows. Safe to re-apply.
--
-- Reversibility: this migration tags rows but does not modify content,
-- type, or any other column. To revert (in a future migration), run:
--   UPDATE public.memory_items
--      SET source_agent = NULL
--    WHERE source_agent IN ('claude', 'orchestrator')
--      AND created_at < '2026-05-09'
--      AND source_type != 'session_summary';  -- preserve 015's backfill
--
-- RLS posture (per global CLAUDE.md RLS hygiene gates 1-5): this is a
-- DO block, not a CREATE FUNCTION. Runs as the migration runner's role
-- (service_role, which bypasses RLS). search_path is set explicitly to
-- defend against schema-shadow attacks during execution. No new policies,
-- no new function executable surface.

set search_path = public, pg_catalog;

do $$
declare
  pred_a integer := 0;
  pred_b integer := 0;
  pred_d integer := 0;
  remaining integer;
  total_rows integer;
begin
  -- Predicate A: structural attribution by source_type for non-fact, non-document_chunk
  -- types. Architectural lock: pre-Sprint-50 only Claude shipped a memory_remember
  -- client. NULL rows of these types are therefore unambiguously Claude.
  update public.memory_items
     set source_agent = 'claude'
   where source_agent is null
     and source_type in ('decision', 'bug_fix', 'architecture', 'preference', 'code_context');
  get diagnostics pred_a = row_count;

  -- Predicate B: fact rows with Claude-session attribution. source_session_id
  -- is the Claude SessionEnd hook's UUID; same shape as the existing tagged
  -- claude/session_summary rows.
  update public.memory_items
     set source_agent = 'claude'
   where source_agent is null
     and source_type = 'fact'
     and source_session_id is not null;
  get diagnostics pred_b = row_count;

  -- Predicate D: rag-system document chunks -> 'orchestrator' (non-LLM batch writer).
  -- All 951 rows carry source_file_path + chunkIndex/heading metadata — the
  -- rag-extractor's deterministic fingerprint.
  update public.memory_items
     set source_agent = 'orchestrator'
   where source_agent is null
     and source_type = 'document_chunk';
  get diagnostics pred_d = row_count;

  select count(*) into remaining
    from public.memory_items
   where source_agent is null;

  select count(*) into total_rows from public.memory_items;

  raise notice '[022] backfill complete: A(claude/typed)=% B(claude/fact+session)=% D(orchestrator/doc_chunk)=% remaining_null=% / % total (acceptance: <5%%)',
    pred_a, pred_b, pred_d, remaining, total_rows;
  raise notice '[022] residual NULL = bare memory_remember fact rows (no session, no path); reach via include_null_source recall flag';
end$$;

-- Refresh the column comment to reflect 015 + 022 together as the partial-
-- backfill story, and document the residual + the recall flag escape hatch.
comment on column public.memory_items.source_agent is
  'Agent that produced this memory: claude|codex|gemini|grok|orchestrator|NULL. Populated at write time by per-agent SessionEnd writers from Sprint 50 onward. Pre-Sprint-50 NULL rows backfilled by migration 015 (session_summary -> claude) and migration 022 (decision/bug_fix/architecture/preference/code_context -> claude; fact w/ source_session_id -> claude; document_chunk -> orchestrator). Residual NULL = bare-call fact rows without session or path attribution; intentionally preserved per migration 015''s provenance bright line. Reach those via memory_recall include_null_source=true.';
