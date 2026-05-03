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

import type { CronRunRecord, DoctorDataSource } from './doctor.js';

interface CronRunRow {
  jobname: string;
  status: string;
  start_time: string;
  end_time: string | null;
  return_message: string | null;
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
  };
}
