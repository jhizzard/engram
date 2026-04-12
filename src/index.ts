/**
 * Engram — public API entry point
 *
 * Re-exports the core memory functions for programmatic use. If you
 * want the stdio MCP server, import from `@jhizzard/engram/mcp-server`
 * or run the `engram` bin.
 */

export { memoryRemember } from './remember.js';
export { memoryRecall, type RecallOutput } from './recall.js';
export { memorySearch } from './search.js';
export { memoryForget } from './forget.js';
export { memoryStatus, formatStatus } from './status.js';
export { memorySummarizeSession, type SummarizeResult } from './summarize.js';
export { consolidateMemories, type ConsolidationReport } from './consolidate.js';
export { generateEmbedding, formatEmbedding } from './embeddings.js';
export { getSupabase, resetSupabaseClient } from './db.js';
export * from './types.js';
