# Installer Pitfalls — pointer

The canonical synthesis of every install/upgrade incident across the TermDeck + Mnestra + Rumen stack lives in TermDeck:

**`~/Documents/Graciella/ChopinNashville/SideHustles/TermDeck/termdeck/docs/INSTALLER-PITFALLS.md`**

Read it before any work that touches:
- Mnestra migrations (`migrations/00*.sql`)
- The session-end hook (`packages/stack-installer/assets/hooks/memory-session-end.js`)
- `mnestra serve` config defaults
- Anything that gets bundled into `@jhizzard/termdeck-stack` or invoked from `termdeck init --mnestra`

The doc is organized as:
1. **Pre-ship checklist** — 10 items, every installer/migration PR must clear them.
2. **Chronological ledger** — every Brad incident, root-caused and classed.
3. **Failure-class taxonomy** — A through I, name the class your PR avoids.
4. **How to add a new entry** — append, don't rewrite.

Mnestra-specific items in the ledger (as of 2026-05-02):
- #5  v0.6.2 wizard exited mid-write, lost secrets (Class C)
- #7  v0.6.8 migration 007 never picked up (Class H)
- #9  MCP config path mismatch — `~/.claude/mcp.json` → `~/.claude.json` (Class B)
- #10 Bundled hook silent-failed on private `rag-system` dependency (Class E)
- #13 Schema-vs-package drift — Mnestra migrations 009–015 never applied on existing installs (Class A + I) — **OPEN, P0**

The Mnestra memory store also has the synthesis indexed — `memory_recall(query="installer pitfalls")` from any project surfaces the headline + pointer.
