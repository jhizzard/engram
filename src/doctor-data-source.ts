/**
 * Mnestra — default DoctorDataSource implementation
 *
 * Wraps the SECURITY DEFINER probe helpers from migration 016
 * (`mnestra_doctor_*`) as a `DoctorDataSource`. If the helpers aren't
 * installed yet, RPC calls error out and the doctor's per-probe
 * try/catch surfaces them as `unknown` with an actionable recommendation
 * to apply the migration.
 */

import type { SupabaseClient } from '@supabase/supabase-js';

import type { CronRunRecord, DoctorDataSource, RumenJobRecord } from './doctor.js';

interface CronRunRow {
  jobname: string;
  status: string;
  start_time: string;
  end_time: string | null;
  return_message: string | null;
}

interface RumenJobRow {
  id: string;
  started_at: string;
  completed_at: string | null;
  status: string;
  sessions_processed: number | null;
  insights_generated: number | null;
  error_message: string | null;
}

export function createSupabaseDoctorDataSource(client: SupabaseClient): DoctorDataSource {
  async function callBoolProbe(fn: string, args: Record<string, unknown>): Promise<boolean> {
    const { data, error } = await client.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    // SQL functions returning a single boolean come back as either a
    // bare boolean or a one-row [{<fn>: bool}] depending on PostgREST
    // version. Normalize.
    if (typeof data === 'boolean') return data;
    if (Array.isArray(data) && data.length > 0 && typeof data[0] === 'object' && data[0] !== null) {
      const row = data[0] as Record<string, unknown>;
      const v = row[fn] ?? Object.values(row)[0];
      return Boolean(v);
    }
    return Boolean(data);
  }

  return {
    async cronJobRunDetails(jobname: string, limit: number): Promise<CronRunRecord[]> {
      const { data, error } = await client.rpc('mnestra_doctor_cron_runs', {
        p_jobname: jobname,
        p_limit: limit,
      });
      if (error) throw new Error(`mnestra_doctor_cron_runs: ${error.message}`);
      const rows = Array.isArray(data) ? (data as CronRunRow[]) : [];
      return rows.map((r) => ({
        jobname: r.jobname,
        status: r.status,
        start_time: r.start_time,
        end_time: r.end_time,
        return_message: r.return_message,
      }));
    },

    async cronJobExists(jobname: string): Promise<boolean> {
      return callBoolProbe('mnestra_doctor_cron_job_exists', { p_jobname: jobname });
    },

    async columnExists(table: string, column: string): Promise<boolean> {
      return callBoolProbe('mnestra_doctor_column_exists', {
        p_table: table,
        p_column: column,
      });
    },

    async rpcExists(name: string): Promise<boolean> {
      return callBoolProbe('mnestra_doctor_rpc_exists', { p_name: name });
    },

    async vaultSecretExists(name: string): Promise<boolean> {
      return callBoolProbe('mnestra_doctor_vault_secret_exists', { p_name: name });
    },

    async rumenJobsRecent(limit: number): Promise<RumenJobRecord[]> {
      // public.rumen_jobs is in the public schema (not cron/vault), so
      // service_role can SELECT directly via PostgREST without a
      // SECURITY DEFINER wrapper.
      //
      // Ordering: live daily-driver probe (Sprint 53 T3 17:18 ET)
      // confirmed T4-CODEX's 17:17 ET cross-finding — started_at is NULL
      // on rows from older installs because the migration's
      // `NOT NULL DEFAULT NOW()` was wrapped in `ADD COLUMN IF NOT EXISTS`
      // and skipped on a pre-existing nullable column. ORDER BY
      // started_at DESC put NULL rows first (PG default for DESC) and
      // hid all recent activity. Fetched 2× the limit and sort in JS by
      // `coalesce(completed_at, started_at)` DESC so:
      //   - running ticks (completed_at NULL) sort by started_at
      //   - completed ticks sort by completion time
      //   - everything-NULL rows fall to the bottom
      // The renderer still shows both timestamps so a NULL started_at
      // remains visible to the auditor.
      const fetchLimit = Math.max(limit * 2, limit + 5);
      const { data, error } = await client
        .from('rumen_jobs')
        .select(
          'id, started_at, completed_at, status, sessions_processed, insights_generated, error_message'
        )
        .order('completed_at', { ascending: false, nullsFirst: false })
        .order('started_at', { ascending: false, nullsFirst: false })
        .limit(fetchLimit);
      if (error) throw new Error(`rumen_jobs: ${error.message}`);
      const rows = Array.isArray(data) ? (data as RumenJobRow[]) : [];
      const sorted = rows
        .map((r) => ({
          id: r.id,
          started_at: r.started_at,
          completed_at: r.completed_at,
          status: r.status,
          sessions_processed: r.sessions_processed ?? 0,
          insights_generated: r.insights_generated ?? 0,
          error_message: r.error_message,
          _key: r.completed_at ?? r.started_at ?? '',
        }))
        .sort((a, b) => (a._key < b._key ? 1 : a._key > b._key ? -1 : 0))
        .slice(0, limit)
        .map(({ _key, ...rest }) => rest);
      return sorted;
    },
  };
}
