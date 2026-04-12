/**
 * Engram — memory_status
 *
 * Returns total active memory count plus breakdowns by project,
 * source_type, and category.
 */

import { getSupabase } from './db.js';
import type { StatusReport } from './types.js';

export async function memoryStatus(): Promise<StatusReport> {
  const supabase = getSupabase();

  const { count: totalActive, error: countError } = await supabase
    .from('memory_items')
    .select('id', { count: 'exact', head: true })
    .eq('is_active', true)
    .eq('archived', false);

  if (countError) {
    console.error('[engram] status count failed:', countError.message);
  }

  const { data: items, error: itemsError } = await supabase
    .from('memory_items')
    .select('project, source_type, category')
    .eq('is_active', true)
    .eq('archived', false);

  if (itemsError) {
    console.error('[engram] status breakdown fetch failed:', itemsError.message);
  }

  const { count: sessionCount, error: sessionError } = await supabase
    .from('memory_sessions')
    .select('id', { count: 'exact', head: true });

  if (sessionError) {
    console.error('[engram] status session count failed:', sessionError.message);
  }

  const byProject: Record<string, number> = {};
  const byType: Record<string, number> = {};
  const byCategory: Record<string, number> = {};

  for (const item of items ?? []) {
    const row = item as { project: string; source_type: string; category: string | null };
    byProject[row.project] = (byProject[row.project] || 0) + 1;
    byType[row.source_type] = (byType[row.source_type] || 0) + 1;
    const cat = row.category || 'uncategorized';
    byCategory[cat] = (byCategory[cat] || 0) + 1;
  }

  return {
    total_active: totalActive ?? 0,
    sessions: sessionCount ?? 0,
    by_project: byProject,
    by_source_type: byType,
    by_category: byCategory,
  };
}

export function formatStatus(report: StatusReport): string {
  const lines = [
    `Total active memories: ${report.total_active}`,
    `Sessions processed: ${report.sessions}`,
    '',
    'By Project:',
    ...Object.entries(report.by_project)
      .sort((a, b) => b[1] - a[1])
      .map(([p, c]) => `  ${p}: ${c}`),
    '',
    'By Type:',
    ...Object.entries(report.by_source_type)
      .sort((a, b) => b[1] - a[1])
      .map(([t, c]) => `  ${t}: ${c}`),
    '',
    'By Category:',
    ...Object.entries(report.by_category)
      .sort((a, b) => b[1] - a[1])
      .map(([c, n]) => `  ${c}: ${n}`),
  ];
  return lines.join('\n');
}
