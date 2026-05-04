-- Mnestra v0.4.1 — `mnestra doctor` SECURITY DEFINER probe wrappers
--
-- Sprint 51.5 T2 (TermDeck). Adds five SECURITY DEFINER helper functions
-- so the `mnestra doctor` subcommand (running under the supabase
-- service_role) can probe `cron.job_run_details`, `cron.job`, `vault.secrets`,
-- `information_schema.columns`, and `pg_proc` without granting raw schema
-- access to service_role.
--
-- Why SECURITY DEFINER: by default `cron.*` and `vault.*` are owned by
-- the `postgres` role and unreadable from service_role. The classical
-- alternative is to `grant usage on schema cron to service_role; grant
-- select on cron.job_run_details to service_role; …` — broader privilege
-- expansion than this lane needs. SECURITY DEFINER lets us read exactly
-- what the doctor needs without exposing the entire cron/vault surface.
--
-- Idempotent: every function uses CREATE OR REPLACE; every GRANT is
-- safe to re-run. No data mutation. Safe to re-apply on every install.
--
-- Sprint 51.9 — pg_cron-conditional cron probes. T3 caught 2026-05-04
-- 14:55 ET that fresh Supabase projects (mnestra-only, no rumen) hit
-- exit-5 on this migration: `cron.job_run_details` and `cron.job` are
-- parse-time-resolved by `language sql` functions, and a fresh project
-- does NOT have `pg_cron` enabled by default (only `pg_stat_statements,
-- pg_trgm, pgcrypto, plpgsql, supabase_vault, uuid-ossp, vector` are in
-- the default set). The two cron-touching functions
-- (`mnestra_doctor_cron_runs`, `mnestra_doctor_cron_job_exists`) +
-- their grants are now wrapped in a do$$ guard that only emits them
-- when `pg_cron` is enabled. The doctor's cron-related probes return
-- the existing `unknown` band (Sprint 51.5 T2 already established it)
-- when the wrappers don't exist — graceful degradation. Petvetbid +
-- jizzard-brain are unaffected because both have rumen installed,
-- which enables pg_cron via rumen's mig 002. Closes the
-- mnestra-only-no-rumen fresh-install path.

-- ── 1. column existence probe (public schema only — cron-independent) ───

create or replace function mnestra_doctor_column_exists(
  p_table  text,
  p_column text
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name   = p_table
      and column_name  = p_column
  );
$$;

-- ── 2. RPC / function existence probe (cron-independent) ────────────────

create or replace function mnestra_doctor_rpc_exists(p_name text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where p.proname = p_name
      and n.nspname = 'public'
  );
$$;

-- ── 3. vault.secrets existence probe (no value disclosure) ──────────────
--
-- Existence-only — never returns the secret value. The doctor only needs
-- to know whether the named vault entry was created during stack install.
-- supabase_vault IS in the Supabase default extension set, so this is
-- safe to emit unconditionally on greenfield projects.

create or replace function mnestra_doctor_vault_secret_exists(p_name text)
returns boolean
language sql
security definer
set search_path = vault, public
as $$
  select exists (select 1 from vault.secrets where name = p_name);
$$;

-- ── 4. Grants for the cron-independent probes ───────────────────────────

grant execute on function mnestra_doctor_column_exists(text, text)        to service_role;
grant execute on function mnestra_doctor_rpc_exists(text)                 to service_role;
grant execute on function mnestra_doctor_vault_secret_exists(text)        to service_role;

-- ── 5. cron.* probes (only emit when pg_cron is enabled) ────────────────
--
-- The two SECURITY DEFINER wrappers below reference `cron.job_run_details`
-- and `cron.job`. Because Postgres parse-time-resolves identifiers in
-- `language sql` functions, the CREATE itself fails when `cron` schema
-- doesn't exist — not just function execution. The do$$ guard checks
-- pg_extension first; if pg_cron isn't enabled, we skip emitting these
-- two wrappers entirely. The doctor's cron probes return `unknown`
-- in that case (Sprint 51.5 T2 contract).
--
-- Idempotent: do$$ runs every replay; CREATE OR REPLACE keeps the
-- function definitions in sync if pg_cron later gets enabled and the
-- migration re-runs. Existing installs (petvetbid, jizzard-brain) have
-- pg_cron from Rumen's install path and emit these unconditionally.

do $cron_guard$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $stmt$
      create or replace function mnestra_doctor_cron_runs(
        p_jobname text,
        p_limit   int default 10
      )
      returns table (
        jobname        text,
        status         text,
        start_time     timestamptz,
        end_time       timestamptz,
        return_message text
      )
      language sql
      security definer
      set search_path = cron, public
      as $body$
        select j.jobname, d.status, d.start_time, d.end_time, d.return_message
        from cron.job_run_details d
        join cron.job j on j.jobid = d.jobid
        where j.jobname = p_jobname
        order by d.start_time desc
        limit greatest(coalesce(p_limit, 10), 1);
      $body$;
    $stmt$;

    execute $stmt$
      create or replace function mnestra_doctor_cron_job_exists(p_jobname text)
      returns boolean
      language sql
      security definer
      set search_path = cron, public
      as $body$
        select exists (select 1 from cron.job where jobname = p_jobname);
      $body$;
    $stmt$;

    execute 'grant execute on function mnestra_doctor_cron_runs(text, int) to service_role';
    execute 'grant execute on function mnestra_doctor_cron_job_exists(text) to service_role';
  end if;
end
$cron_guard$;
