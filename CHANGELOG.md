# Changelog

All notable changes to Engram will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Planned
- HTTP event webhook server (Fix 6 second half) so TermDeck and similar tools can POST real-time events without spawning a new MCP child per call
- `memory_export` / `memory_import` CLI subcommands for backups and cross-database migration
- A `match_count` cap and EXPLAIN-friendly variant of `memory_hybrid_search` for very large stores

## [0.1.0] - 2026-04-11

### Added
- Six MCP tools: `memory_remember`, `memory_recall`, `memory_search`, `memory_forget`, `memory_status`, `memory_summarize_session`
- `memory_items`, `memory_sessions`, `memory_relationships` schema with vector(1536) and HNSW indexing
- `memory_hybrid_search` SQL function with reciprocal rank fusion over full-text + semantic search
- `consolidateMemories` background job for clustering and merging near-duplicates via Claude Haiku
- Programmatic API at `@jhizzard/engram` for embedding Engram inside other Node tools
- Migrations split into three numbered files for clean upgrade history
- Full documentation: `README.md`, `docs/SCHEMA.md`, `docs/SOURCE-TYPES.md`, `docs/INTEGRATION.md`, `docs/RAG-FIXES-APPLIED.md`

### Fixed (the six RAG fixes from RAG-MEMORY-IMPROVEMENTS-AND-TERMDECK-STRATEGY.md)
- **Fix 1 — Tiered recency decay by source_type.** `memory_hybrid_search` now applies a `CASE source_type` decay, with one-year half-life for decisions / architecture / preferences, 90 days for facts, 30 days for bug fixes, 14 days for session summaries and document chunks. Implemented in `migrations/002_engram_search_function.sql`.
- **Fix 2 — Minimum result count in `memory_recall`.** `memoryRecall` always returns at least `min_results` (default 5) hits when that many exist, regardless of token budget or score threshold. Implemented in `src/recall.ts`.
- **Fix 3 — Source-type weighting inside the SQL function.** Decisions get a 1.5x multiplier, architecture 1.4x, bug fixes 1.3x, preferences 1.2x, document chunks 0.6x. Applied before `LIMIT` so important memories survive truncation. Implemented in `migrations/002_engram_search_function.sql`.
- **Fix 4 — Memory consolidation background job + looser dedup threshold.** New `consolidateMemories` function clusters memories at >0.85 similarity and merges them via Haiku. Dedup threshold in `memoryRemember` lowered from 0.92 to 0.88. Implemented in `src/consolidate.ts` and `src/remember.ts`.
- **Fix 5 — Project affinity scoring.** Exact project match multiplies score by 1.5x, the special `global` project by 1.0x, and unrelated projects by 0.7x. Implemented in `migrations/002_engram_search_function.sql`.
- **Fix 6 — Real-time event ingestion path documented.** `migrations/003_engram_event_webhook.sql` is a placeholder marker; the live ingestion endpoint will live in the MCP server process. Documented in `docs/RAG-FIXES-APPLIED.md`.

[Unreleased]: https://github.com/jhizzard/engram/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jhizzard/engram/releases/tag/v0.1.0
