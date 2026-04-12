# Source types

Every memory in Engram has a `source_type`. The type controls two things:

1. **How fast it decays.** A six-month-old architectural decision should still rank highly; a six-month-old "we tried `npm ci` and it failed" probably shouldn't.
2. **How much it's weighted.** Decisions and architectural notes outrank raw document chunks in the final fused score.

The MCP tool `memory_remember` exposes six source types. Two more (`session_summary`, `document_chunk`) exist in the SQL ranking function but are populated by `memory_summarize_session` and external ingestion pipelines, not by direct user calls.

## Decay and weight profile

| `source_type` | When to use it | Half-life | Weight |
|---|---|---:|---:|
| `decision` | Architectural or strategic choices. "We picked Postgres over DynamoDB because…" | 365 days | 1.5x |
| `architecture` | System architecture notes, diagrams, module boundaries. | 365 days | 1.4x |
| `bug_fix` | A specific bug and its resolution. Stale fixes age out fast on purpose. | 30 days | 1.3x |
| `preference` | User or team preferences. "The team prefers Tailwind." | 365 days | 1.2x |
| `fact` | Project facts. "The API base URL is X." Default if you don't pass `source_type`. | 90 days | 1.0x |
| `code_context` | Snippet-level context about a specific file or function. | 14 days | 1.0x |
| `session_summary` *(internal)* | Output of `memory_summarize_session` rollups. | 14 days | 1.0x |
| `document_chunk` *(internal)* | Chunks from indexed docs. | 14 days | 0.6x |

The exact decay formula is `1.0 / (1.0 + age_seconds / (half_life_days * 86400))`, applied per row before RRF fusion. See `migrations/002_engram_search_function.sql`.

## Choosing the right type

- **Did the user make a deliberate choice?** → `decision`
- **Does it describe how the system is laid out?** → `architecture`
- **Is it a workaround or a fix for a specific bug?** → `bug_fix`
- **Is it about how the user likes to work?** → `preference`
- **Is it a stable fact about the project?** → `fact`
- **Is it a comment about a specific function or file you're editing right now?** → `code_context`

If you're not sure, `fact` is a safe default.

## Why decay differs by type

Long-running engineering work has a strange property: the most important things are usually the oldest. The decision to use Postgres over DynamoDB matters every day. The bug you fixed yesterday matters this week and then never again. A flat 30-day decay (Engram's predecessor used one) crushes both into the same score and drowns the important stuff.

The tiered profile fixes this. Decisions and architecture barely move over a year. Bug fixes fade fast so the recall window stays focused on actually-current issues. Code context fades fastest of all because it's the most local — by next week you'll be in a different file anyway.
