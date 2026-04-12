/**
 * Engram — consolidation job (Fix 4)
 *
 * Scans memory_items for clusters of highly-similar memories (>0.85
 * cosine similarity), merges each cluster into a single canonical memory
 * via Claude Haiku, and marks the originals as superseded.
 *
 * This is the "retrieve -> judge -> distill -> consolidate" pattern.
 * Run it on a schedule (weekly cron) or on-demand from an admin tool.
 *
 * Non-destructive: originals are soft-marked (superseded_by set,
 * is_active = false), never deleted. You can audit and revert.
 */

import { getSupabase } from './db.js';
import { generateEmbedding, formatEmbedding } from './embeddings.js';

const CLUSTER_SIMILARITY = 0.85;
const MAX_CLUSTER_SIZE = 6;
const MAX_CLUSTERS_PER_RUN = 25;

export interface ConsolidationReport {
  scanned: number;
  clusters_found: number;
  clusters_merged: number;
  memories_superseded: number;
  errors: number;
}

interface MemoryRow {
  id: string;
  content: string;
  project: string;
  source_type: string;
  category: string | null;
  metadata: Record<string, unknown>;
}

async function synthesizeCanonical(cluster: MemoryRow[]): Promise<string | null> {
  const apiKey = process.env.ANTHROPIC_API_KEY ?? '';
  if (!apiKey) {
    console.error('[engram-consolidate] no ANTHROPIC_API_KEY — skipping synthesis');
    return null;
  }

  const { default: Anthropic } = await import('@anthropic-ai/sdk');
  const client = new Anthropic({ apiKey });
  const model = process.env.ENGRAM_HAIKU_MODEL || 'claude-haiku-4-5-20251001';

  const listing = cluster.map((m, i) => `[${i + 1}] ${m.content}`).join('\n');

  try {
    const response = await client.messages.create({
      model,
      max_tokens: 1024,
      system:
        'You are a memory consolidation assistant. Merge near-duplicate facts into a single canonical fact. Respond with plain text and nothing else.',
      messages: [
        {
          role: 'user',
          content: `These memories are near-duplicates describing the same underlying fact. Merge them into ONE concise canonical fact that preserves every unique detail. Do not invent new information.

${listing}

Canonical fact:`,
        },
      ],
    });
    const block = response.content[0];
    if (!block || block.type !== 'text') return null;
    const out = block.text.trim();
    return out || null;
  } catch (err) {
    console.error('[engram-consolidate] synthesis failed:', err);
    return null;
  }
}

export async function consolidateMemories(): Promise<ConsolidationReport> {
  const supabase = getSupabase();
  const report: ConsolidationReport = {
    scanned: 0,
    clusters_found: 0,
    clusters_merged: 0,
    memories_superseded: 0,
    errors: 0,
  };

  const { data: memories, error } = await supabase
    .from('memory_items')
    .select('id, content, project, source_type, category, metadata')
    .eq('is_active', true)
    .eq('archived', false)
    .is('superseded_by', null)
    .order('created_at', { ascending: false })
    .limit(500);

  if (error || !memories) {
    console.error('[engram-consolidate] fetch failed:', error?.message);
    report.errors++;
    return report;
  }

  report.scanned = memories.length;
  const visited = new Set<string>();

  for (const seed of memories as MemoryRow[]) {
    if (visited.has(seed.id)) continue;
    if (report.clusters_found >= MAX_CLUSTERS_PER_RUN) break;

    let embedding: number[];
    try {
      embedding = await generateEmbedding(seed.content);
    } catch (err) {
      console.error('[engram-consolidate] embed failed for seed:', err);
      report.errors++;
      continue;
    }

    const { data: similar, error: matchErr } = await supabase.rpc('match_memories', {
      query_embedding: formatEmbedding(embedding),
      match_threshold: CLUSTER_SIMILARITY,
      match_count: MAX_CLUSTER_SIZE,
      filter_project: seed.project,
    });

    if (matchErr) {
      console.error('[engram-consolidate] match_memories failed:', matchErr.message);
      report.errors++;
      continue;
    }

    const cluster = (similar ?? []).filter(
      (m: { id: string }) => !visited.has(m.id)
    ) as MemoryRow[];

    if (cluster.length < 2) {
      visited.add(seed.id);
      continue;
    }

    report.clusters_found++;

    const canonical = await synthesizeCanonical(cluster);
    if (!canonical) {
      report.errors++;
      cluster.forEach((m) => visited.add(m.id));
      continue;
    }

    let canonicalEmbedding: number[];
    try {
      canonicalEmbedding = await generateEmbedding(canonical);
    } catch (err) {
      console.error('[engram-consolidate] canonical embed failed:', err);
      report.errors++;
      continue;
    }

    const { data: inserted, error: insertErr } = await supabase
      .from('memory_items')
      .insert({
        content: canonical,
        embedding: formatEmbedding(canonicalEmbedding),
        source_type: seed.source_type,
        category: seed.category,
        project: seed.project,
        metadata: {
          ...seed.metadata,
          consolidated_from: cluster.map((m) => m.id),
          consolidated_at: new Date().toISOString(),
        },
      })
      .select('id')
      .single();

    if (insertErr || !inserted) {
      console.error('[engram-consolidate] canonical insert failed:', insertErr?.message);
      report.errors++;
      continue;
    }

    const ids = cluster.map((m) => m.id);
    const { error: supersedeErr } = await supabase
      .from('memory_items')
      .update({
        superseded_by: inserted.id,
        is_active: false,
        updated_at: new Date().toISOString(),
      })
      .in('id', ids);

    if (supersedeErr) {
      console.error('[engram-consolidate] supersede update failed:', supersedeErr.message);
      report.errors++;
      continue;
    }

    report.clusters_merged++;
    report.memories_superseded += ids.length;
    ids.forEach((id) => visited.add(id));
  }

  return report;
}
