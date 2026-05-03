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

-- ── 1. cron.job_run_details lookup ───────────────────────────────────────
--
-- Returns the most recent N runs of a named cron job, projecting only
-- the columns the doctor needs (status, start/end timestamps, return
-- message). The doctor parses `return_message` for the rumen-tick /
-- graph-inference all-zeros pattern.

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
as $$
  select j.jobname, d.status, d.start_time, d.end_time, d.return_message
  from cron.job_run_details d
  join cron.job j on j.jobid = d.jobid
  where j.jobname = p_jobname
  order by d.start_time desc
  limit greatest(coalesce(p_limit, 10), 1);
$$;

-- ── 2. column existence probe (public schema only) ───────────────────────

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

-- ── 3. RPC / function existence probe ────────────────────────────────────

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

-- ── 4. cron.job existence probe (does the named job exist at all) ───────

create or replace function mnestra_doctor_cron_job_exists(p_jobname text)
returns boolean
language sql
security definer
set search_path = cron, public
as $$
  select exists (select 1 from cron.job where jobname = p_jobname);
$$;

-- ── 5. vault.secrets existence probe (no value disclosure) ──────────────
--
-- Existence-only — never returns the secret value. The doctor only needs
-- to know whether the named vault entry was created during stack install.

create or replace function mnestra_doctor_vault_secret_exists(p_name text)
returns boolean
language sql
security definer
set search_path = vault, public
as $$
  select exists (select 1 from vault.secrets where name = p_name);
$$;

-- ── 6. Grants ────────────────────────────────────────────────────────────

grant execute on function mnestra_doctor_cron_runs(text, int)             to service_role;
grant execute on function mnestra_doctor_column_exists(text, text)        to service_role;
grant execute on function mnestra_doctor_rpc_exists(text)                 to service_role;
grant execute on function mnestra_doctor_cron_job_exists(text)            to service_role;
grant execute on function mnestra_doctor_vault_secret_exists(text)        to service_role;
