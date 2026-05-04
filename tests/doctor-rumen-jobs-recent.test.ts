/**
 * Mnestra — `mnestra doctor` rumen-tick informational section (Sprint 53 T3)
 *
 * Closes Sprint 51.5b T2 finding #1 (cron return_message blindness):
 * surfacing rumen_jobs.error_message + sessions/insights counts inline
 * gives an auditor a Brad-equivalent diagnosis without dropping to psql.
 *
 * Test fixtures use neutral session/job UUIDs (test-job-NNN) and
 * synthetic project context — codename-scrub clean per project rule.
 *
 * Coverage:
 *   1. rumenJobsRecent rows render in the report under "Recent rumen ticks"
 *   2. errored row's error_message surfaces inline (truncated to budget)
 *   3. mixed succeed/zero/errored fixture renders all rows in started_at-DESC order
 *   4. rumenJobsRecent throw → rumenJobs absent (no exception, no section)
 *   5. empty result → section header + "(no rumen_jobs rows returned)"
 *   6. cron return_message non-numeric blob → surfaces in all-zeros probe detail
 *      (the bonus fix on the cron side: previously dropped non-numeric strings
 *      now appear as "non-numeric return_message: <truncated>" in the detail)
 *   7. JSON shape includes rumenJobs field for `mnestra doctor --json` consumers
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  runDoctor,
  formatDoctor,
  formatRumenJobs,
  type CronRunRecord,
  type DoctorDataSource,
  type FsLike,
  type McpPaths,
  type RumenJobRecord,
} from '../src/doctor.js';

// ── Fixtures ─────────────────────────────────────────────────────────────

const HOME_CANONICAL = '/fake/home/.claude.json';
const FAKE_PATHS: McpPaths = {
  canonicalPath: HOME_CANONICAL,
  legacyPath: '/fake/home/.claude/mcp.json',
};

const MNESTRA_ENTRY = JSON.stringify(
  { mcpServers: { mnestra: { command: 'mnestra' } } },
  null,
  2
);

function makeFakeFs(files: Record<string, string>): FsLike {
  return {
    existsSync: (p) => Object.prototype.hasOwnProperty.call(files, p),
    readFileSync: (p) => files[p] ?? '',
  };
}

function makeRumenJob(opts: {
  id?: string;
  startMinAgo?: number;
  durationSec?: number;
  status?: string;
  sessions?: number;
  insights?: number;
  errorMessage?: string | null;
  completedNull?: boolean;
}): RumenJobRecord {
  const start = new Date(Date.now() - (opts.startMinAgo ?? 5) * 60_000);
  const end = opts.completedNull
    ? null
    : new Date(start.getTime() + (opts.durationSec ?? 1) * 1000).toISOString();
  return {
    id: opts.id ?? 'test-job-001',
    started_at: start.toISOString(),
    completed_at: end,
    status: opts.status ?? 'done',
    sessions_processed: opts.sessions ?? 0,
    insights_generated: opts.insights ?? 0,
    error_message: opts.errorMessage ?? null,
  };
}

function healthyCronRuns(jobname: 'rumen-tick' | 'graph-inference-tick'): CronRunRecord[] {
  // 10 runs, all numeric return_message, balanced for green probes.
  return Array.from({ length: 10 }, (_, i) => {
    const start = new Date(Date.now() - 15 * (i + 1) * 60_000);
    const end = new Date(start.getTime() + 1000);
    const msg =
      jobname === 'rumen-tick'
        ? `{"sessions_processed":${3 + i},"insights_generated":${1 + i}}`
        : `{"candidates_scanned":${2 + i},"edges_inserted":${1 + i}}`;
    return {
      jobname,
      status: 'succeeded',
      start_time: start.toISOString(),
      end_time: end.toISOString(),
      return_message: msg,
    };
  });
}

function makeFakeData(opts: {
  rumenJobs?: RumenJobRecord[];
  rumenJobsThrow?: boolean;
  cronRuns?: Partial<Record<'rumen-tick' | 'graph-inference-tick', CronRunRecord[]>>;
}): DoctorDataSource {
  return {
    async cronJobRunDetails(jobname, _limit) {
      return (
        opts.cronRuns?.[jobname as 'rumen-tick' | 'graph-inference-tick'] ??
        healthyCronRuns(jobname as 'rumen-tick' | 'graph-inference-tick')
      );
    },
    async cronJobExists(_jobname) {
      return true;
    },
    async columnExists(_table, _column) {
      return true;
    },
    async rpcExists(_name) {
      return true;
    },
    async vaultSecretExists(_name) {
      return true;
    },
    async rumenJobsRecent(_limit) {
      if (opts.rumenJobsThrow) throw new Error('rumen_jobs: relation does not exist');
      return opts.rumenJobs ?? [];
    },
  };
}

// ── Tests ────────────────────────────────────────────────────────────────

test('rumenJobsRecent rows surface under "Recent rumen ticks" section', async () => {
  const rumenJobs: RumenJobRecord[] = [
    makeRumenJob({ id: 'test-job-001', startMinAgo: 1, sessions: 3, insights: 2 }),
    makeRumenJob({ id: 'test-job-002', startMinAgo: 16, sessions: 0, insights: 0 }),
    makeRumenJob({ id: 'test-job-003', startMinAgo: 31, sessions: 5, insights: 4 }),
  ];
  const data = makeFakeData({ rumenJobs });
  const fs = makeFakeFs({ [HOME_CANONICAL]: MNESTRA_ENTRY });

  const report = await runDoctor({ data, fs, mcpPaths: FAKE_PATHS });
  const text = formatDoctor(report);

  assert.deepEqual(report.rumenJobs, rumenJobs, 'report.rumenJobs holds the fetched rows');
  assert.match(text, /Recent rumen ticks/);
  // Each row's started_at first-25-chars should appear in the rendered output.
  for (const r of rumenJobs) {
    assert.ok(
      text.includes(r.started_at.slice(0, 25)),
      `row ${r.id} started_at not surfaced in formatDoctor output`
    );
  }
});

test('errored rumen job surfaces error_message inline (truncated to budget)', async () => {
  const longError =
    'connection to server at "db.x.supabase.co" (10.0.0.1), port 5432 failed: SSL connection has been closed unexpectedly during query execution at hour 14';
  const rumenJobs: RumenJobRecord[] = [
    makeRumenJob({
      id: 'test-job-failed',
      startMinAgo: 5,
      status: 'failed',
      errorMessage: longError,
    }),
  ];
  const data = makeFakeData({ rumenJobs });
  const fs = makeFakeFs({ [HOME_CANONICAL]: MNESTRA_ENTRY });

  const report = await runDoctor({ data, fs, mcpPaths: FAKE_PATHS });
  const text = formatDoctor(report);

  assert.match(text, /failed/, 'failed status renders');
  // Error message head must appear so an auditor can read the cause inline.
  assert.match(text, /connection to server/);
  // Truncation: the full 150-char error must NOT render verbatim — there
  // should be a … marker, since our budget is 80 chars.
  assert.match(text, /…/, 'long error_message truncated with ellipsis marker');
});

test('mixed succeed/zero/errored fixture renders all rows in fetch order', async () => {
  // Caller (DataSource) is responsible for ordering; doctor renders as-given.
  // Here we hand them in newest-first to mirror the started_at-DESC contract.
  const rumenJobs: RumenJobRecord[] = [
    makeRumenJob({ id: 'test-job-fresh', startMinAgo: 1, sessions: 4, insights: 2 }),
    makeRumenJob({
      id: 'test-job-zero',
      startMinAgo: 16,
      sessions: 0,
      insights: 0,
      status: 'done',
    }),
    makeRumenJob({
      id: 'test-job-fail',
      startMinAgo: 31,
      status: 'failed',
      errorMessage: 'pg_cron HTTP timeout (30s)',
    }),
    makeRumenJob({ id: 'test-job-running', startMinAgo: 0, status: 'running', completedNull: true }),
    makeRumenJob({ id: 'test-job-old', startMinAgo: 60, sessions: 1, insights: 1 }),
  ];
  const data = makeFakeData({ rumenJobs });
  const fs = makeFakeFs({ [HOME_CANONICAL]: MNESTRA_ENTRY });

  const report = await runDoctor({ data, fs, mcpPaths: FAKE_PATHS });
  const text = formatDoctor(report);

  // Each fixture row should appear in the rendered output.
  for (const r of rumenJobs) {
    assert.ok(
      text.includes(r.started_at.slice(0, 25)),
      `${r.id} (${r.status}) not surfaced`
    );
  }
  // Running row's completed_at is null → renders as "—".
  const lines = text.split('\n');
  const runningLine = lines.find((l) => l.includes('running'));
  assert.ok(runningLine, 'running row line present');
  assert.match(runningLine!, /—/, 'null completed_at renders as em-dash');
  // Failed row's error inlines.
  const failLine = lines.find((l) => l.includes('failed'));
  assert.ok(failLine, 'failed row line present');
  assert.match(failLine!, /pg_cron HTTP timeout/);
});

test('rumenJobsRecent throws → report.rumenJobs absent, no exception, no section', async () => {
  const data = makeFakeData({ rumenJobsThrow: true });
  const fs = makeFakeFs({ [HOME_CANONICAL]: MNESTRA_ENTRY });

  const report = await runDoctor({ data, fs, mcpPaths: FAKE_PATHS });
  const text = formatDoctor(report);

  assert.equal(report.rumenJobs, undefined, 'rumenJobs field absent on throw');
  // The section heading should NOT appear when rumenJobs is undefined.
  assert.doesNotMatch(text, /Recent rumen ticks/);
  // Existing probes still work.
  assert.equal(report.exitCode, 0);
});

test('empty rumenJobs array → renders header + "no rumen_jobs rows returned"', () => {
  const lines = formatRumenJobs([]);
  const joined = lines.join('\n');
  assert.match(joined, /Recent rumen ticks/);
  assert.match(joined, /no rumen_jobs rows returned/);
});

test('cron return_message non-numeric blob surfaces in all-zeros probe detail (bonus fix)', async () => {
  // Sprint 53 T3 bonus: fix the existing cron-side blindness where a
  // non-numeric return_message (e.g., a Postgres error) was silently
  // dropped because parseCronReturnMessage() extracted zero numeric fields.
  const errorBlob = 'ERROR: relation "memory_sessions" does not exist (SQLSTATE 42P01)';
  const errorRuns: CronRunRecord[] = Array.from({ length: 7 }, (_, i) => {
    const start = new Date(Date.now() - 15 * (i + 1) * 60_000);
    return {
      jobname: 'rumen-tick',
      status: 'succeeded',
      start_time: start.toISOString(),
      end_time: new Date(start.getTime() + 200).toISOString(),
      return_message: errorBlob,
    };
  });
  const data = makeFakeData({ cronRuns: { 'rumen-tick': errorRuns } });
  const fs = makeFakeFs({ [HOME_CANONICAL]: MNESTRA_ENTRY });

  const report = await runDoctor({ data, fs, mcpPaths: FAKE_PATHS });

  const allZeros = report.results.find((r) => r.name === 'rumen-tick all-zeros')!;
  // The all-zeros classifier shouldn't fire red (parseCronReturnMessage
  // returned no numeric fields — runs are unclassifiable, not all-zero).
  // But the detail line should now name the non-numeric blob.
  assert.match(allZeros.detail, /non-numeric return_message/);
  assert.match(allZeros.detail, /relation "memory_sessions" does not exist/);
});

test('cron return_message numeric still extracted normally (regression: no false-positive blob surface)', async () => {
  // Make sure the bonus fix does NOT surface anything when return_message is
  // a clean numeric JSON. Existing all-zeros / not-all-zeros logic must be
  // unchanged for parseable runs.
  const data = makeFakeData({});
  const fs = makeFakeFs({ [HOME_CANONICAL]: MNESTRA_ENTRY });

  const report = await runDoctor({ data, fs, mcpPaths: FAKE_PATHS });

  const allZeros = report.results.find((r) => r.name === 'rumen-tick all-zeros')!;
  assert.equal(allZeros.status, 'green');
  assert.doesNotMatch(allZeros.detail, /non-numeric return_message/);
});

test('JSON shape: report.rumenJobs is serializable for `mnestra doctor --json`', async () => {
  const rumenJobs: RumenJobRecord[] = [
    makeRumenJob({
      id: 'test-job-json',
      startMinAgo: 5,
      status: 'failed',
      errorMessage: 'sample',
    }),
  ];
  const data = makeFakeData({ rumenJobs });
  const fs = makeFakeFs({ [HOME_CANONICAL]: MNESTRA_ENTRY });

  const report = await runDoctor({ data, fs, mcpPaths: FAKE_PATHS });
  const json = JSON.stringify(report);
  const parsed = JSON.parse(json) as {
    rumenJobs?: RumenJobRecord[];
    results: unknown;
    exitCode: number;
  };

  assert.ok(Array.isArray(parsed.rumenJobs));
  assert.equal(parsed.rumenJobs![0]!.id, 'test-job-json');
  assert.equal(parsed.rumenJobs![0]!.status, 'failed');
  assert.equal(parsed.rumenJobs![0]!.error_message, 'sample');
});
