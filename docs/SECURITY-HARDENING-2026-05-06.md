# Mnestra security hardening — 2026-05-06

**Status:** Migration `019_security_hardening.sql` written, applied + verified on `petvetbid` (`luvvbrpaopnblvxdxwzb`) on 2026-05-06, shipped in `@jhizzard/mnestra@0.4.4`. Brad-side apply still pending — manual SQL one-shot or `npm install @jhizzard/mnestra@0.4.4` + re-run install.
**Source:** External sweep by Brad Heath (Nacho Money LLC) — flagged the same morning, observed on his `jizzard-brain tools` Supabase project (`rrzkceirgciiqgeefvbe`). Same channel that produced the termdeck-stack PUNCHLIST a day earlier.
**Cross-ref:** Global standing rule now in `~/.claude/CLAUDE.md` § *MANDATORY: Supabase RLS + privilege hygiene*. This doc is the project-scoped follow-up.

## TL;DR

Three hardening items, one migration:

1. **Drop the four `Allow insert for all` PUBLIC INSERT policies** on `mnestra_commands`, `mnestra_developer_memory`, `mnestra_project_memory`, `mnestra_session_memory`. They were created by Supabase Studio's default-policy template at table-creation time (not visible in our migration source) and grant write to anyone holding the project's anon key.
2. **REVOKE EXECUTE FROM PUBLIC** on the five `mnestra_doctor_*` SECURITY DEFINER functions from migration 016. Source migration only `GRANT`s to `service_role`, but Postgres defaults EXECUTE to PUBLIC — the grant is additive. `mnestra_doctor_vault_secret_exists` is the worst: anon-callable enumeration of vault secret names.
3. **SET search_path** on the six memory-* functions that Supabase lint `0011_function_search_path_mutable` flags. Cheap fix; closes a SECURITY DEFINER shadow-attack vector.

Service role keeps full access throughout (bypasses RLS, gets explicit grants). No legitimate anon write path is broken — Mnestra's documented architecture is service-role-only writes via the MCP server.

## Root cause classification

| # | Hole | Source | Why it shipped |
|---|------|--------|----------------|
| 1 | `WITH CHECK (true)` PUBLIC INSERT policies on 4 tables | Supabase Studio default template ("Allow insert for all") | Created at table-creation time outside our migration files. Not in `migrations/001_mnestra_tables.sql`. Per-project drift, not source-controlled. |
| 2 | PUBLIC EXECUTE on 5 SECURITY DEFINER doctor functions | Postgres default + missing REVOKE in `016_mnestra_doctor_probes.sql` | Migration 016 grants to `service_role` only but never `REVOKE EXECUTE … FROM PUBLIC`. Postgres grants are additive — the explicit service_role grant doesn't displace the implicit PUBLIC grant. |
| 3 | Mutable `search_path` on 6 functions | Missing `SET search_path = public, pg_catalog` clause in CREATE FUNCTION | Lint `0011`. Functions: `memory_hybrid_search`, `memory_hybrid_search_explain`, `match_memories`, `memory_recall_graph`, `memory_status_aggregation`, `expand_memory_neighborhood`. |

Note on #2: the same migration shape pattern is what we'd want every future SECURITY DEFINER function to follow — `revoke execute … from public` BEFORE the targeted `grant execute … to service_role`. The global CLAUDE.md rule codifies this template.

## Draft migration — `019_security_hardening.sql`

```sql
-- Mnestra v0.4.4 (target) — Sprint <next>: security hardening
--
-- Closes:
--   1. Permissive PUBLIC INSERT RLS on mnestra_{commands,developer,project,session}_memory
--   2. PUBLIC EXECUTE on mnestra_doctor_* SECURITY DEFINER functions
--   3. Mutable search_path on memory_* functions (lint 0011)
--
-- Source: external security sweep by Brad Heath, 2026-05-06.
-- See docs/SECURITY-HARDENING-2026-05-06.md and global CLAUDE.md
-- "MANDATORY: Supabase RLS + privilege hygiene" for the standing rule.

begin;

-- ============================================================
-- 1. Drop permissive PUBLIC INSERT policies on memory tables.
--    Mnestra writes go through the MCP server using service_role,
--    which bypasses RLS — these policies were Studio-default
--    artifacts, never load-bearing.
-- ============================================================

drop policy if exists "Allow insert for all" on public.mnestra_commands;
drop policy if exists "Allow insert for all" on public.mnestra_developer_memory;
drop policy if exists "Allow insert for all" on public.mnestra_project_memory;
drop policy if exists "Allow insert for all" on public.mnestra_session_memory;

-- ============================================================
-- 2. Revoke PUBLIC EXECUTE on mnestra_doctor_* SECURITY DEFINER
--    functions. Source migration 016 granted to service_role
--    only, but Postgres defaults EXECUTE to PUBLIC — the grant
--    is additive, not exclusive. Doctor probes connect via
--    service role; no client path breaks.
-- ============================================================

revoke execute on function public.mnestra_doctor_column_exists(text, text)        from public;
revoke execute on function public.mnestra_doctor_rpc_exists(text)                 from public;
revoke execute on function public.mnestra_doctor_vault_secret_exists(text)        from public;

-- The two cron-related wrappers are conditionally created in 016 (only if
-- pg_cron is available). Guard the revoke the same way.
do $$
begin
  if exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'mnestra_doctor_cron_runs'
  ) then
    execute 'revoke execute on function public.mnestra_doctor_cron_runs(text, int) from public';
  end if;
  if exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'mnestra_doctor_cron_job_exists'
  ) then
    execute 'revoke execute on function public.mnestra_doctor_cron_job_exists(text) from public';
  end if;
end $$;

-- ============================================================
-- 3. Pin search_path on memory_* functions to close lint 0011
--    (function_search_path_mutable). Mitigates SECURITY DEFINER
--    shadow-attack vectors via operator-controlled schemas.
--
--    Argument signatures must match exactly. If a future migration
--    changes any signature, this block must be updated to match.
-- ============================================================

-- The exact signatures depend on the live shape of these functions.
-- Verify in Studio before applying. If signature drift occurred
-- between migrations, the ALTER FUNCTION will error and the txn
-- aborts — that's the desired behavior.

alter function public.memory_hybrid_search(text, vector, int, int, float, float, float, int, text, text)
  set search_path = public, pg_catalog;

alter function public.memory_hybrid_search_explain(text, vector, int, int, float, float, float, int, text, text)
  set search_path = public, pg_catalog;

alter function public.match_memories(vector, float, int)
  set search_path = public, pg_catalog;

alter function public.memory_recall_graph(text, vector, int, int, int, float, float, float, int, text, text)
  set search_path = public, pg_catalog;

alter function public.memory_status_aggregation()
  set search_path = public, pg_catalog;

alter function public.expand_memory_neighborhood(uuid, int, int)
  set search_path = public, pg_catalog;

commit;

-- Post-apply verification (run separately in Studio SQL editor):
--
--   -- Should return zero rows:
--   select schemaname, tablename, policyname
--     from pg_policies
--    where schemaname = 'public'
--      and policyname = 'Allow insert for all';
--
--   -- Should show NO public_exec=true rows for mnestra_doctor_*:
--   select n.nspname, p.proname,
--          has_function_privilege('public', p.oid, 'EXECUTE') as public_exec
--     from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname like 'mnestra_doctor_%';
--
--   -- Should show search_path=public,pg_catalog in proconfig:
--   select p.proname, p.proconfig
--     from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname like 'memory_%';
```

> **Caveat — function signatures.** The `alter function` block uses my best guess at the argument lists from migration files; before shipping, verify exact signatures against the live `pg_proc` shape on a Mnestra project. If any signature in our codebase drifted, the ALTER errors and the migration aborts cleanly (txn-wrapped). Do **not** publish `019` without doing the signature verification pass on at least one live Mnestra project (e.g. petvetbid).

## Backward-compat / blast-radius analysis

| Change | What breaks | Who's affected |
|--------|-------------|----------------|
| Drop "Allow insert for all" on 4 tables | Direct anon-client INSERT into memory tables | Nobody intentionally — Mnestra writes via service_role MCP server. If any user has built direct anon-write client paths, they break and that's correct. |
| REVOKE EXECUTE on doctor_* from PUBLIC | Anon/authenticated callers of doctor probes | Nobody. `cli/src/doctor.js` connects via service_role. |
| SET search_path on memory_* | None | Pure metadata change; no behavior diff. |

No existing Mnestra installation that follows the documented architecture should observe any breakage. If a custom installation built around anon writes exists, the migration should be gated behind a `--allow-anon-writes` config flag — but Brad's setup, our reference setup, and every project doc default to service-role-only writes, so the gate is unnecessary.

## Release coupling

This is a `@jhizzard/mnestra` release — not termdeck-stack. Suggested version: `0.4.4` (patch — pure security hardening, no API change). The `@jhizzard/termdeck-stack` installer should pin to the new mnestra version in its dependency manifest as part of the same wave.

Stack-installer audit-trail: bump per `docs/RELEASE.md` § "stack-installer audit-trail bump matters."

## Standing checklist (post-fix, before next release)

Run on a live Mnestra project to verify the migration applied cleanly and no new holes opened:

```sql
-- 1. Confirm no PUBLIC permissive policies on mnestra_* tables
select schemaname, tablename, policyname, roles, with_check
  from pg_policies
 where schemaname = 'public'
   and tablename like 'mnestra_%'
   and ('public' = ANY(roles) OR roles = '{}');

-- 2. Confirm no PUBLIC EXECUTE on any mnestra/memory function
select n.nspname, p.proname,
       has_function_privilege('public', p.oid, 'EXECUTE') as public_exec
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and (p.proname like 'mnestra_%' or p.proname like 'memory_%')
   and has_function_privilege('public', p.oid, 'EXECUTE');

-- 3. Confirm Supabase advisors clean
-- Run: mcp__supabase__get_advisors with type='security'
```

## Brad's verbatim flag (preserved as audit trail)

> Below is the full text Brad sent on 2026-05-06 — kept verbatim so future sessions can verify the source. His draft path on his machine: `/home/nacho/sprints/structural-rls-20260506/josh-mnestra-rls-flag.md`.

```
# Heads-up — `@jhizzard/mnestra` ships an unrestricted INSERT policy on 4 tables
**From:** Brad Heath / Nacho Money LLC
**Date:** 2026-05-06
**Discovered while:** sweeping Supabase security advisors across all my projects this morning.

## TL;DR

Four Mnestra tables ship with an RLS policy that allows **anyone with the project's anon key**
to INSERT rows. Tables: `mnestra_commands`, `mnestra_developer_memory`, `mnestra_project_memory`,
`mnestra_session_memory`. Policy name: `Allow insert for all`. `WITH CHECK (true)`, no role
restriction (`roles: ["-"]` = PUBLIC). On any Supabase project that runs Mnestra migrations,
anyone holding the published anon key can write into these tables.

This was Supabase's `lint=0024_permissive_rls_policy` flagging — observed on
**`jizzard-brain tools`** (`rrzkceirgciiqgeefvbe`) but it's in the migration set, so every
Mnestra install would inherit it unless the operator manually tightens.

## Why this matters

The anon key is published in client bundles by design — Supabase's whole anon-key model
assumes RLS is the gate. With `WITH CHECK (true)` for INSERT, the gate is open. Practical
risk shapes:

- **Memory pollution:** an attacker with the anon key (e.g. someone who scraped the local
  dev `.env` from a leaked repo, a CI image, or just a published Mnestra tutorial) can flood
  `mnestra_project_memory` with synthetic memories, biasing future `memory_hybrid_search`
  results. Mnestra's whole value prop is "this is the user's authoritative memory" — that
  breaks if the corpus is poisonable.
- **Session-id squatting:** `mnestra_session_memory` keys on session IDs; an attacker can
  pre-create sessions, race-condition the legitimate user's writes, or just block IDs.
- **No audit trail:** there's no `actor` or `inserted_by` column to disambiguate legitimate
  vs attacker inserts after the fact.

[... full text continues — see Brad's WhatsApp / paste from 2026-05-06 morning ...]
```

(The remainder of Brad's flag — Options A/B/C, doctor function fix, search_path fix, suggested release shape — is folded into the migration draft above and the global CLAUDE.md rule. The verbatim source-of-truth is Brad's file at the path noted in the header.)

---

**Owner:** Josh / Mnestra release.
**Estimated effort:** 1 small sprint or fold into next maintenance release. ~1h to apply, ~30m to verify on petvetbid before publish.
**Risk:** Low. Pure tightening. Service-role paths unaffected.
