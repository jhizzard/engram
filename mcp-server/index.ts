#!/usr/bin/env node

/**
 * Engram MCP Server
 *
 * Exposes six stdio MCP tools:
 *   memory_remember          — store a fact/decision/preference
 *   memory_recall            — smart retrieval (applies Fix 2 min_results)
 *   memory_search            — low-level filtered search
 *   memory_forget            — soft-delete by ID
 *   memory_status            — system stats
 *   memory_summarize_session — extract facts from text via Haiku
 */

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

import {
  memoryRemember,
  memoryRecall,
  memorySearch,
  memoryForget,
  memoryStatus,
  formatStatus,
  memorySummarizeSession,
} from '../src/index.js';

const server = new McpServer({
  name: 'engram',
  version: '0.1.0',
});

// ── memory_remember ──────────────────────────────────────────────────────

server.registerTool(
  'memory_remember',
  {
    title: 'Remember',
    description:
      'Store a fact, decision, or preference in long-term memory. Use this when you learn something important about the user, project, or codebase that should persist across sessions.',
    inputSchema: {
      text: z.string().describe('The fact or information to remember'),
      project: z.string().default('global').describe('Project name (e.g., "my-app")'),
      category: z
        .enum([
          'technical',
          'business',
          'workflow',
          'debugging',
          'architecture',
          'convention',
          'relationship',
        ])
        .optional()
        .describe('Category of this memory'),
      source_type: z
        .enum(['fact', 'decision', 'preference', 'bug_fix', 'architecture', 'code_context'])
        .default('fact')
        .describe('Type of memory'),
    },
  },
  async ({ text, project, category, source_type }) => {
    try {
      const result = await memoryRemember({
        content: text,
        project: project || 'global',
        source_type: source_type || 'fact',
        category: category ?? null,
      });
      return {
        content: [
          {
            type: 'text' as const,
            text: `Memory ${result}: "${text.slice(0, 80)}${text.length > 80 ? '...' : ''}"`,
          },
        ],
      };
    } catch (err) {
      console.error('[engram-mcp] memory_remember failed:', err);
      return {
        content: [{ type: 'text' as const, text: `Error: ${(err as Error).message}` }],
      };
    }
  }
);

// ── memory_recall ────────────────────────────────────────────────────────

server.registerTool(
  'memory_recall',
  {
    title: 'Recall',
    description:
      'Smart retrieval of relevant memories. Returns concise, deduplicated results within a token budget. Prioritizes decisions and bug fixes over raw document chunks. Always returns at least min_results hits when available. Omit project to search across ALL projects.',
    inputSchema: {
      query: z.string().describe('What to search for in memory'),
      project: z
        .string()
        .optional()
        .describe('Filter by project (omit for cross-project search)'),
      token_budget: z
        .number()
        .default(2000)
        .describe('Max tokens to return (default 2000, ~8000 chars).'),
      min_results: z
        .number()
        .default(5)
        .describe(
          'Minimum number of hits to return if that many exist, regardless of score threshold.'
        ),
    },
  },
  async ({ query, project, token_budget, min_results }) => {
    try {
      const out = await memoryRecall({
        query,
        project: project ?? null,
        token_budget: token_budget || 2000,
        min_results: min_results || 5,
      });
      return { content: [{ type: 'text' as const, text: out.text }] };
    } catch (err) {
      console.error('[engram-mcp] memory_recall failed:', err);
      return {
        content: [{ type: 'text' as const, text: `Error: ${(err as Error).message}` }],
      };
    }
  }
);

// ── memory_search ────────────────────────────────────────────────────────

server.registerTool(
  'memory_search',
  {
    title: 'Search Memories',
    description:
      'Low-level hybrid search with filters. Returns raw JSON with scores. Use for detailed exploration or admin tooling.',
    inputSchema: {
      query: z.string().describe('Search query'),
      project: z.string().optional().describe('Filter by project'),
      source_type: z
        .enum(['fact', 'decision', 'preference', 'bug_fix', 'architecture', 'code_context'])
        .optional()
        .describe('Filter by source type'),
      limit: z.number().default(20).describe('Max results'),
    },
  },
  async ({ query, project, source_type, limit }) => {
    try {
      const hits = await memorySearch({
        query,
        project: project ?? null,
        source_type: source_type ?? null,
        limit: limit || 20,
      });
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(hits, null, 2) }],
      };
    } catch (err) {
      console.error('[engram-mcp] memory_search failed:', err);
      return {
        content: [{ type: 'text' as const, text: `Error: ${(err as Error).message}` }],
      };
    }
  }
);

// ── memory_forget ────────────────────────────────────────────────────────

server.registerTool(
  'memory_forget',
  {
    title: 'Forget',
    description: 'Soft-delete a memory by UUID. The row is archived but preserved.',
    inputSchema: {
      memoryId: z.string().uuid().describe('UUID of the memory to forget'),
    },
  },
  async ({ memoryId }) => {
    try {
      const result = await memoryForget(memoryId);
      if (!result.ok) {
        return { content: [{ type: 'text' as const, text: `Error: ${result.error}` }] };
      }
      return { content: [{ type: 'text' as const, text: `Memory ${memoryId} archived.` }] };
    } catch (err) {
      console.error('[engram-mcp] memory_forget failed:', err);
      return {
        content: [{ type: 'text' as const, text: `Error: ${(err as Error).message}` }],
      };
    }
  }
);

// ── memory_status ────────────────────────────────────────────────────────

server.registerTool(
  'memory_status',
  {
    title: 'Memory Status',
    description:
      'System stats: total active memories, sessions, breakdown by project / source_type / category.',
    inputSchema: {},
  },
  async () => {
    try {
      const report = await memoryStatus();
      return { content: [{ type: 'text' as const, text: formatStatus(report) }] };
    } catch (err) {
      console.error('[engram-mcp] memory_status failed:', err);
      return {
        content: [{ type: 'text' as const, text: `Error: ${(err as Error).message}` }],
      };
    }
  }
);

// ── memory_summarize_session ─────────────────────────────────────────────

server.registerTool(
  'memory_summarize_session',
  {
    title: 'Summarize Session',
    description:
      'Extract discrete facts from text (a session transcript, document, or any text) and store them as memories. Uses Claude Haiku.',
    inputSchema: {
      text: z.string().describe('The text to extract facts from'),
      project: z.string().default('global').describe('Project name'),
    },
  },
  async ({ text, project }) => {
    try {
      const result = await memorySummarizeSession(text, project || 'global');
      if (result.total === 0) {
        return { content: [{ type: 'text' as const, text: 'No facts extracted from the text.' }] };
      }
      const summary = result.facts
        .map((f, i) => `${i + 1}. [${f.category ?? 'uncategorized'}/${f.importance}] ${f.content}`)
        .join('\n');
      return {
        content: [
          {
            type: 'text' as const,
            text: `Extracted ${result.total} facts: ${result.inserted} stored, ${result.updated} updated, ${result.skipped} skipped.\n\n${summary}`,
          },
        ],
      };
    } catch (err) {
      console.error('[engram-mcp] memory_summarize_session failed:', err);
      return {
        content: [{ type: 'text' as const, text: `Error: ${(err as Error).message}` }],
      };
    }
  }
);

// ── Start Server ─────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
console.error('[engram-mcp] engram MCP server listening on stdio');
