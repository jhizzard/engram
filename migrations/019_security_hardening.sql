-- Mnestra v0.4.4 — security hardening.
--
-- Source: external Supabase-advisor sweep by Brad Heath / Nacho Money LLC,
-- 2026-05-06. See docs/SECURITY-HARDENING-2026-05-06.md for the full flag
-- and root-cause analysis. The standing rule lives in the global Claude
-- Code instructions: "MANDATORY: Supabase RLS + privilege hygiene".
--
-- Closes four hole classes that shipped in 0.4.3 and earlier:
--
--   1. Permissive PUBLIC INSERT RLS on mnestra_{commands,developer_memory,
--      project_memory,session_memory}. Created by Supabase Studio's
--      "Allow insert for all" default-policy template at table-creation
--      time — never in source migrations, but inherited per project.
--      Anyone with the project's anon key could write directly to memory
--      tables, poisoning the corpus or session-id-squatting.
--
--   2. PUBLIC EXECUTE on every Mnestra function. Postgres defaults
--      function EXECUTE to PUBLIC; the explicit `grant ... to service_role`
--      in earlier migrations is additive, not exclusive. The five
--      mnestra_doctor_* SECURITY DEFINER probes were the most exposed
--      (vault-secret-existence enumeration with the function-owner's
--      privileges); the six memory_* RPCs were also anon-callable.
--
--   3. Mutable search_path on memory_* and mnestra_doctor_* functions
--      (Supabase lint 0011). Mitigates SECURITY DEFINER shadow-attack
--      vectors via operator-controlled schemas.
--
--   4. mnestra_recent_activity SECURITY DEFINER view (Supabase lint 0010)
--      with anon+authenticated SELECT. Exposed a 100-row UNION of all
--      three memory layers to any anon-key holder — the most direct
--      memory-corpus exfiltration path aside from the dropped INSERT
--      policies.
--
-- Backward-compat: Mnestra writes via service_role only (which bypasses
-- RLS), so dropping the INSERT policies and revoking PUBLIC EXECUTE
-- doesn't break any documented architecture path. service_role keeps
-- full access.
--
-- Idempotence: every statement uses IF EXISTS / IF NOT EXISTS shapes or
-- tolerates being re-run. The two cron-related doctor probes are
-- conditionally created in migration 016 (only when pg_cron is present)
-- and are guarded with `do $$ ... $$` blocks here for the same reason.

-- ====================================================================
-- 1. Drop permissive PUBLIC INSERT policies on memory tables.
-- ====================================================================

drop policy if exists "Allow insert for all" on public.mnestra_commands;
drop policy if exists "Allow insert for all" on public.mnestra_developer_memory;
drop policy if exists "Allow insert for all" on public.mnestra_project_memory;
drop policy if exists "Allow insert for all" on public.mnestra_session_memory;

-- ====================================================================
-- 2. Revoke EXECUTE from PUBLIC + anon + authenticated on every Mnestra
--    function. service_role keeps EXECUTE (granted explicitly in 014
--    + 016).
-- ====================================================================

-- mnestra_doctor_* SECURITY DEFINER probes
revoke execute on function public.mnestra_doctor_column_exists(p_table text, p_column text)        from public, anon, authenticated;
revoke execute on function public.mnestra_doctor_rpc_exists(p_name text)                           from public, anon, authenticated;
revoke execute on function public.mnestra_doctor_vault_secret_exists(p_name text)                  from public, anon, authenticated;

-- pg_cron-conditional doctor probes (created in 016 only when pg_cron present)
do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'mnestra_doctor_cron_runs'
  ) then
    execute 'revoke execute on function public.mnestra_doctor_cron_runs(p_jobname text, p_limit integer) from public, anon, authenticated';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'mnestra_doctor_cron_job_exists'
  ) then
    execute 'revoke execute on function public.mnestra_doctor_cron_job_exists(p_jobname text) from public, anon, authenticated';
  end if;
end $$;

-- memory_* RPCs (SECURITY INVOKER — server-side invocation only)
revoke execute on function public.expand_memory_neighborhood(start_id uuid, max_depth integer)                                                                                                                                                                                       from public, anon, authenticated;
revoke execute on function public.match_memories(query_embedding vector, match_threshold double precision, match_count integer, filter_project text)                                                                                                                                  from public, anon, authenticated;
revoke execute on function public.memory_hybrid_search(query_text text, query_embedding vector, match_count integer, full_text_weight double precision, semantic_weight double precision, rrf_k integer, filter_project text, filter_source_type text)                                from public, anon, authenticated;
revoke execute on function public.memory_hybrid_search_explain(query_text text, query_embedding vector, match_count integer, full_text_weight double precision, semantic_weight double precision, rrf_k integer, filter_project text, filter_source_type text)                        from public, anon, authenticated;
revoke execute on function public.memory_recall_graph(query_embedding vector, project_filter text, max_depth integer, k integer)                                                                                                                                                      from public, anon, authenticated;
revoke execute on function public.memory_status_aggregation()                                                                                                                                                                                                                          from public, anon, authenticated;

-- ====================================================================
-- 3. Pin search_path on every Mnestra function (Supabase lint 0011).
-- ====================================================================

alter function public.expand_memory_neighborhood(start_id uuid, max_depth integer)
  set search_path = public, pg_catalog;
alter function public.match_memories(query_embedding vector, match_threshold double precision, match_count integer, filter_project text)
  set search_path = public, pg_catalog;
alter function public.memory_hybrid_search(query_text text, query_embedding vector, match_count integer, full_text_weight double precision, semantic_weight double precision, rrf_k integer, filter_project text, filter_source_type text)
  set search_path = public, pg_catalog;
alter function public.memory_hybrid_search_explain(query_text text, query_embedding vector, match_count integer, full_text_weight double precision, semantic_weight double precision, rrf_k integer, filter_project text, filter_source_type text)
  set search_path = public, pg_catalog;
alter function public.memory_recall_graph(query_embedding vector, project_filter text, max_depth integer, k integer)
  set search_path = public, pg_catalog;
alter function public.memory_status_aggregation()
  set search_path = public, pg_catalog;

alter function public.mnestra_doctor_column_exists(p_table text, p_column text)
  set search_path = public, pg_catalog;
alter function public.mnestra_doctor_rpc_exists(p_name text)
  set search_path = public, pg_catalog;
alter function public.mnestra_doctor_vault_secret_exists(p_name text)
  set search_path = public, pg_catalog;

do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'mnestra_doctor_cron_runs'
  ) then
    execute 'alter function public.mnestra_doctor_cron_runs(p_jobname text, p_limit integer) set search_path = public, pg_catalog';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'mnestra_doctor_cron_job_exists'
  ) then
    execute 'alter function public.mnestra_doctor_cron_job_exists(p_jobname text) set search_path = public, pg_catalog';
  end if;
end $$;

-- ====================================================================
-- 4. Recreate mnestra_recent_activity view without SECURITY DEFINER,
--    revoke anon/authenticated SELECT. service_role keeps SELECT.
-- ====================================================================

drop view if exists public.mnestra_recent_activity;

create view public.mnestra_recent_activity as
  select 'session'::text   as layer, id, session_id, event_type, payload, project, developer_id, "timestamp", created_at from public.mnestra_session_memory
  union all
  select 'project'::text   as layer, id, session_id, event_type, payload, project, developer_id, "timestamp", created_at from public.mnestra_project_memory
  union all
  select 'developer'::text as layer, id, session_id, event_type, payload, project, developer_id, "timestamp", created_at from public.mnestra_developer_memory
  order by 8 desc
  limit 100;

revoke all on public.mnestra_recent_activity from public, anon, authenticated;
grant select on public.mnestra_recent_activity to service_role;

-- ====================================================================
-- Post-apply verification (run separately in Studio SQL editor):
--
--   -- Should return zero rows:
--   with bad_policies as (
--     select policyname from pg_policies
--      where schemaname='public' and tablename like 'mnestra_%'
--        and ('public' = any(roles) or roles = '{}')
--        and (with_check='true' or qual='true')
--   ),
--   public_exec as (
--     select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--      where n.nspname='public'
--        and (p.proname like 'mnestra_doctor_%' or p.proname like 'memory_%'
--             or p.proname in ('match_memories','expand_memory_neighborhood'))
--        and has_function_privilege('public', p.oid, 'EXECUTE')
--   ),
--   mutable_path as (
--     select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--      where n.nspname='public' and p.prokind='f'
--        and (p.proname like 'memory_%' or p.proname like 'mnestra_doctor_%')
--        and not exists (
--          select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) c
--          where c like 'search_path=%'
--        )
--   )
--   select 'BAD_POLICY' as kind, policyname as detail from bad_policies
--   union all select 'PUBLIC_EXEC', proname from public_exec
--   union all select 'MUTABLE_SEARCH_PATH', proname from mutable_path;
--
-- Verified zero rows on petvetbid (luvvbrpaopnblvxdxwzb) on 2026-05-06.
-- ====================================================================
