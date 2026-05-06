-- Mnestra v0.4.6 — security hardening (revised from 0.4.4 / 0.4.5).
--
-- Source: external Supabase-advisor sweep by Brad Heath / Nacho Money LLC,
-- 2026-05-06. See docs/SECURITY-HARDENING-2026-05-06.md for the full flag
-- and root-cause analysis. The standing rule lives in the global Claude
-- Code instructions: "MANDATORY: Supabase RLS + privilege hygiene".
--
-- Two corrections folded into this revision:
--
--   A. **search_path must include `extensions`.** The 0.4.4/0.4.5 version of
--      this migration set search_path = public, pg_catalog on the memory_*
--      RPCs. Supabase >= 2024 installs pgvector in the `extensions` schema,
--      so the `<=>` cosine-distance operator becomes unreachable from those
--      RPCs after the alter — semantic recall fails with "operator does not
--      exist: extensions.vector <=> extensions.vector". Confirmed live
--      against the reference Mnestra project on 2026-05-06; fixed by
--      including `extensions` in search_path.
--
--   B. **Schema-generation-aware.** Some Mnestra installs are on the older
--      "memory_items-only" generation — they have memory_items /
--      memory_relationships / memory_sessions + the 6 memory_* RPCs, but
--      NOT the layered-memory tables (mnestra_session_memory,
--      mnestra_developer_memory, mnestra_project_memory, mnestra_commands)
--      and NOT the mnestra_doctor_* SECURITY DEFINER probes. The 0.4.4 / 0.4.5
--      migration body assumed the layered shape and threw "relation does
--      not exist" / "function does not exist" mid-migration on older
--      installs. Brad caught this on three of his projects (Structural,
--      aetheria-payroll, aetheria-phase1) and worked around with a
--      signature-agnostic DO-block subset.
--
--      This revision restructures every section as defensive lookups
--      against pg_class / pg_proc / pg_views, so each statement only fires
--      when its target exists. The migration runs cleanly on:
--        - layered-memory generation (Josh's reference project): full fix
--        - memory_items-only generation (Brad's three projects): function
--          hardening only; mnestra_*-targeting statements are skipped
--        - mixed generation: each statement applies to whatever exists
--
-- Closes four hole classes (where applicable to the install's schema
-- generation):
--
--   1. Permissive PUBLIC INSERT RLS on mnestra_{commands,developer_memory,
--      project_memory,session_memory}. Created by Supabase Studio's
--      "Allow insert for all" default-policy template at table-creation
--      time. Anyone with the project's anon key could write directly to
--      memory tables, poisoning the corpus or session-id-squatting.
--
--   2. PUBLIC EXECUTE on every Mnestra function. Postgres defaults
--      function EXECUTE to PUBLIC; the explicit `grant ... to service_role`
--      in earlier migrations is additive, not exclusive.
--
--   3. Mutable search_path on memory_* and mnestra_doctor_* functions
--      (Supabase lint 0011).
--
--   4. mnestra_recent_activity SECURITY DEFINER view (Supabase lint 0010)
--      with anon+authenticated SELECT.
--
-- Backward-compat: zero behavior change for any Mnestra installation that
-- follows the documented architecture (service-role writes via MCP server).
-- service_role keeps EXECUTE on every function and SELECT on the view.
--
-- Idempotent: every section guards on object existence and uses
-- IF EXISTS / signature-agnostic patterns. Re-running this migration is
-- safe and is in fact the recommended way to upgrade a 0.4.4/0.4.5 install
-- to pick up the search_path fix.

-- ====================================================================
-- 1. Drop permissive PUBLIC INSERT policies on mnestra_* tables, when
--    those tables exist on this install. Skipped silently on older
--    memory_items-only schema generation.
-- ====================================================================

do $$
declare
  tbl text;
  tables text[] := array[
    'mnestra_commands',
    'mnestra_developer_memory',
    'mnestra_project_memory',
    'mnestra_session_memory'
  ];
begin
  foreach tbl in array tables loop
    if to_regclass(format('public.%I', tbl)) is not null then
      execute format('drop policy if exists "Allow insert for all" on public.%I', tbl);
    end if;
  end loop;
end $$;

-- ====================================================================
-- 2 + 3. Revoke EXECUTE from public + anon + authenticated AND pin
-- search_path on every Mnestra function. Signature-agnostic — iterates
-- pg_proc to apply to whatever functions exist on this install. Covers
-- memory_*, match_memories, expand_memory_neighborhood, and
-- mnestra_doctor_*.
--
-- search_path includes `extensions` for the pgvector operator and
-- pg_catalog for built-ins; doctor functions don't use vectors but the
-- inclusion is harmless and keeps every Mnestra function uniform.
-- ====================================================================

do $$
declare
  fn record;
  sig text;
begin
  for fn in
    select n.nspname,
           p.proname,
           pg_get_function_identity_arguments(p.oid) as ident_args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and (
         p.proname like 'memory_%'
         or p.proname in ('match_memories', 'expand_memory_neighborhood')
         or p.proname like 'mnestra_doctor_%'
       )
  loop
    sig := format('%I.%I(%s)', fn.nspname, fn.proname, fn.ident_args);
    execute format('revoke execute on function %s from public, anon, authenticated', sig);
    execute format('alter function %s set search_path = public, extensions, pg_catalog', sig);
    -- service_role keeps EXECUTE; the revoke above only targets public/anon/authenticated.
  end loop;
end $$;

-- ====================================================================
-- 4. Recreate mnestra_recent_activity view without SECURITY DEFINER and
-- restrict SELECT to service_role. Skipped silently if the view doesn't
-- exist or any of the three underlying tables are missing.
-- ====================================================================

do $$
begin
  if to_regclass('public.mnestra_session_memory') is not null
     and to_regclass('public.mnestra_project_memory') is not null
     and to_regclass('public.mnestra_developer_memory') is not null
  then
    drop view if exists public.mnestra_recent_activity;

    execute $view$
      create view public.mnestra_recent_activity as
        select 'session'::text as layer, id, session_id, event_type, payload, project, developer_id, "timestamp", created_at from public.mnestra_session_memory
        union all
        select 'project'::text as layer, id, session_id, event_type, payload, project, developer_id, "timestamp", created_at from public.mnestra_project_memory
        union all
        select 'developer'::text as layer, id, session_id, event_type, payload, project, developer_id, "timestamp", created_at from public.mnestra_developer_memory
        order by 8 desc
        limit 100
    $view$;

    revoke all on public.mnestra_recent_activity from public, anon, authenticated;
    grant select on public.mnestra_recent_activity to service_role;
  end if;
end $$;

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
-- Verified zero rows on the reference Mnestra project on 2026-05-06.
-- Smoke test: select count(*) from memory_hybrid_search('smoke', array_fill(0::real, ARRAY[1536])::vector, 1) → 1 row, no operator-resolution error.
-- ====================================================================
