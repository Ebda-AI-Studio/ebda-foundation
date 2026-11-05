// BrainDO: the one SQLite-backed Durable Object that owns the finding -> job pipeline, the hands runs, the questions,
// the Telegram budget and dedupe, and the counters behind the dashboard. A single instance (idFromName('brain')) keeps
// every decision strongly consistent; KV is used only outside it, where eventual consistency is fine.
//
// Finding lifecycle: open -> queued | question -> dispatched -> done | failed | held | resolved
//   "acted" = a job was dispatched to the hands, a question was asked, or the finding resolved. The acted-on ratio is
//   acted / raised; a finding still unacted 24 h after it was raised is an OS bug (self-check), shown on the dashboard
//   and in the digest, never a separate message.
import { DurableObject } from 'cloudflare:workers';
import { classifyFinding } from './classify';
import type { Env, Policy } from './env';
import { policyFrom } from './env';
import { fingerprint, type Finding, type Lane, type MergePolicy } from './findings';
import { providerFor, type HandsBatch, type HandsJob, type HandsProvider, type JobOutcome, type RunKind, type UsageReport } from './hands';
import { admit, dayKey, digestMessage, questionMessage, sendTelegram, type Outgoing } from './telegram';
import { usageGuard } from './usage';
import type { AdvisoryRunSummary } from './watchers/advisories';

const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;
export const NIGHTLY_MAX_JOBS = 25;
export const UNACTED_LIMIT_MS = DAY;
const TERMINAL = new Set(['done', 'failed', 'held', 'resolved']);

type Row = Record<string, SqlStorageValue>;

export interface IngestResult {
  fp: string;
  deduped: boolean;
  reopened: boolean;
  lane: Lane;
  reason: string;
  jobId: string | null;
}

export interface CiEventInput {
  id: string;
  slug: string;
  sha: string;
  workflow: string;
  branch: string;
  defaultBranch: string;
  url: string;
  ts: number;
}

export interface HealthObservation {
  url: string;
  kind: 'api' | 'page' | 'money';
  ok: boolean;
  status: number;
  ms: number;
}

export interface FindingRow {
  fp: string; source: string; kind: string; title: string; repo: string | null; url: string | null; lane: string; reason: string;
  status: string; raised_at: number; acted_at: number | null; seen_count: number;
}
export interface RunRow { id: string; kind: string; provider: string; status: string; started_at: number; finished_at: number | null }
export interface QuestionRow { id: string; text: string; options: string[]; default_opt: string; reversible: number; status: string; deadline: number | null }
export interface ActedOn { raised: number; acted: number; ratio: number | null }

/** GET /api/state: everything the dashboard shows. */
export interface BrainState {
  generatedAt: number;
  findings: { open: number; recent: FindingRow[] };
  jobs: { queuedUrgent: number; queuedNightly: number; awaitingAnswer: number; running: number };
  runs: RunRow[];
  questions: QuestionRow[];
  messages: { sentToday: number; budget: number; deferred: number; failed: number };
  actedOn: { d1: ActedOn; d7: ActedOn };
  osBugs: number;
  usage: { report: UsageReport | null; guard: { allowed: boolean; reason: string }; thresholdPct: number };
  health: { at: number; obs: HealthObservation[] } | null;
  advisories: AdvisoryRunSummary | null;
}

function uid(prefix: string): string {
  return `${prefix}_${crypto.randomUUID().replace(/-/g, '').slice(0, 16)}`;
}

export class BrainDO extends DurableObject<Env> {
  private sql: SqlStorage;
  /** Replaceable in tests; 4b swaps the provider through HANDS_PROVIDER. */
  hands: HandsProvider;
  /** Replaceable in tests (the Telegram sender's fetch). */
  fetchImpl: typeof fetch = (...a) => fetch(...a);
  policy: Policy;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.hands = providerFor(env.HANDS_PROVIDER ?? 'stub');
    this.policy = policyFrom(env);
    ctx.blockConcurrencyWhile(async () => this.migrate());
  }

  private migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS findings (
        fp TEXT PRIMARY KEY, source TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, title TEXT NOT NULL,
        repo TEXT, url TEXT, data TEXT NOT NULL, lane TEXT NOT NULL, reason TEXT NOT NULL, merge_policy TEXT NOT NULL,
        status TEXT NOT NULL, first_seen INTEGER NOT NULL, raised_at INTEGER NOT NULL, last_seen INTEGER NOT NULL,
        seen_count INTEGER NOT NULL DEFAULT 1, reopened INTEGER NOT NULL DEFAULT 0, acted_at INTEGER, closed_at INTEGER, outcome TEXT);
      CREATE INDEX IF NOT EXISTS findings_status ON findings(status, raised_at);
      CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY, fp TEXT NOT NULL, lane TEXT NOT NULL, merge_policy TEXT NOT NULL, status TEXT NOT NULL,
        run_id TEXT, answer TEXT, created_at INTEGER NOT NULL, started_at INTEGER, finished_at INTEGER, outcome TEXT);
      CREATE INDEX IF NOT EXISTS jobs_status ON jobs(status, lane, created_at);
      CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, provider TEXT NOT NULL, external_id TEXT, status TEXT NOT NULL,
        day TEXT NOT NULL, started_at INTEGER NOT NULL, finished_at INTEGER, cap_min INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS questions (
        id TEXT PRIMARY KEY, fp TEXT NOT NULL, job_id TEXT NOT NULL, text TEXT NOT NULL, options TEXT NOT NULL,
        default_opt TEXT NOT NULL, reversible INTEGER NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL,
        sent_at INTEGER, deadline INTEGER, answered_at INTEGER, answer TEXT);
      CREATE TABLE IF NOT EXISTS messages (
        dedupe_key TEXT PRIMARY KEY, kind TEXT NOT NULL, day TEXT NOT NULL, status TEXT NOT NULL, text TEXT NOT NULL,
        at INTEGER NOT NULL, reason TEXT);
      CREATE INDEX IF NOT EXISTS messages_day ON messages(day, status);
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY, slug TEXT NOT NULL, sha TEXT NOT NULL, workflow TEXT NOT NULL, branch TEXT NOT NULL,
        default_branch TEXT NOT NULL, url TEXT NOT NULL, ts INTEGER NOT NULL, processed_at INTEGER);
      CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
    `);
  }

  // ---------- small helpers ----------
  private rows(q: string, ...b: unknown[]): Row[] {
    return this.sql.exec(q, ...b).toArray() as Row[];
  }
  private row(q: string, ...b: unknown[]): Row | null {
    return this.rows(q, ...b)[0] ?? null;
  }
  private getMeta<T>(k: string): T | null {
    const r = this.row('SELECT v FROM meta WHERE k = ?', k);
    return r ? (JSON.parse(String(r.v)) as T) : null;
  }
  private setMeta(k: string, v: unknown): void {
    this.sql.exec('INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', k, JSON.stringify(v));
  }

  // ---------- findings ----------
  async ingestFinding(f: Finding, now: number = Date.now()): Promise<IngestResult> {
    const fp = await fingerprint(f);
    const c = classifyFinding(f);
    const existing = this.row('SELECT status, lane, reason FROM findings WHERE fp = ?', fp);
    if (existing && !TERMINAL.has(String(existing.status))) {
      this.sql.exec('UPDATE findings SET last_seen = ?, seen_count = seen_count + 1 WHERE fp = ?', now, fp);
      return { fp, deduped: true, reopened: false, lane: existing.lane as Lane, reason: String(existing.reason), jobId: null };
    }
    const data = JSON.stringify(f);
    if (existing) {
      // recurrence after a terminal state: same row, counted, new job (still one fingerprint, never a second finding)
      this.sql.exec(
        `UPDATE findings SET status = 'open', data = ?, title = ?, lane = ?, reason = ?, merge_policy = ?, raised_at = ?, last_seen = ?,
         seen_count = seen_count + 1, reopened = reopened + 1, acted_at = NULL, closed_at = NULL, outcome = NULL WHERE fp = ?`,
        data, f.title, c.lane, c.reason, c.mergePolicy, now, now, fp,
      );
    } else {
      this.sql.exec(
        `INSERT INTO findings (fp, source, kind, key, title, repo, url, data, lane, reason, merge_policy, status, first_seen, raised_at, last_seen)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?, ?)`,
        fp, f.source, f.kind, f.key, f.title, f.repo ?? null, f.url ?? null, data, c.lane, c.reason, c.mergePolicy, now, now, now,
      );
    }
    const jobId = uid('job');
    if (c.lane === 'question') {
      const destructive = /destructive/.test(c.reason);
      const qid = uid('q');
      this.sql.exec(
        `INSERT INTO jobs (id, fp, lane, merge_policy, status, created_at) VALUES (?, ?, 'nightly', ?, 'awaiting_answer', ?)`,
        jobId, fp, c.mergePolicy, now,
      );
      this.sql.exec(
        `INSERT INTO questions (id, fp, job_id, text, options, default_opt, reversible, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)`,
        qid, fp, jobId, `${f.title}${f.repo ? ` (${f.repo})` : ''}: ${c.reason}. Open a PR for it?`, JSON.stringify(['proceed', 'hold']),
        destructive ? 'hold' : 'proceed', destructive ? 0 : 1, now,
      );
      this.sql.exec(`UPDATE findings SET status = 'question' WHERE fp = ?`, fp);
    } else {
      this.sql.exec(`INSERT INTO jobs (id, fp, lane, merge_policy, status, created_at) VALUES (?, ?, ?, ?, 'queued', ?)`, jobId, fp, c.lane, c.mergePolicy, now);
      this.sql.exec(`UPDATE findings SET status = 'queued' WHERE fp = ?`, fp);
    }
    return { fp, deduped: false, reopened: !!existing, lane: c.lane, reason: c.reason, jobId };
  }

  async ingestMany(fs: Finding[], now: number = Date.now()): Promise<{ raised: number; deduped: number }> {
    let raised = 0;
    let deduped = 0;
    for (const f of fs) ((await this.ingestFinding(f, now)).deduped ? deduped++ : raised++);
    return { raised, deduped };
  }

  /** Close an open finding by identity (CI went green, an advisory was fixed upstream, a page recovered). */
  async resolveFinding(f: Pick<Finding, 'source' | 'kind' | 'key'>, outcome: string, now: number = Date.now()): Promise<boolean> {
    const fp = await fingerprint(f);
    const r = this.row('SELECT status FROM findings WHERE fp = ?', fp);
    if (!r || TERMINAL.has(String(r.status))) return false;
    this.sql.exec(`UPDATE findings SET status = 'resolved', closed_at = ?, acted_at = COALESCE(acted_at, ?), outcome = ? WHERE fp = ?`, now, now, outcome, fp);
    // jobs not yet handed out are cancelled; a running job finishes and reports normally
    this.sql.exec(`UPDATE jobs SET status = 'cancelled', finished_at = ? WHERE fp = ? AND status IN ('queued', 'awaiting_answer')`, now, fp);
    this.sql.exec(`UPDATE questions SET status = 'cancelled' WHERE fp = ? AND status IN ('pending', 'sent')`, fp);
    return true;
  }

  /** Resolve every open finding of source+kind whose key is not in `openKeys` (complete advisory listing only). */
  async reconcile(source: string, kind: string, keyPrefix: string, openKeys: string[], now: number = Date.now()): Promise<number> {
    const open = new Set(openKeys);
    let n = 0;
    for (const r of this.rows(`SELECT key FROM findings WHERE source = ? AND kind = ? AND status NOT IN ('done','failed','held','resolved')`, source, kind)) {
      const key = String(r.key);
      if (key.startsWith(keyPrefix) && !open.has(key) && (await this.resolveFinding({ source, kind, key }, 'no longer reported', now))) n++;
    }
    return n;
  }

  // ---------- CI events (from the relay webhook) ----------
  ingestCiEvent(ev: CiEventInput): boolean {
    const before = this.sql.exec('SELECT 1 FROM events WHERE id = ?', ev.id).toArray().length;
    if (before) return false;
    this.sql.exec(
      'INSERT INTO events (id, slug, sha, workflow, branch, default_branch, url, ts) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      ev.id, ev.slug, ev.sha, ev.workflow, ev.branch, ev.defaultBranch, ev.url, ev.ts,
    );
    return true;
  }

  /**
   * CI watcher (cron): turn queued failure events into findings. Only default-branch failures are the OS's job (a PR's
   * red CI belongs to that PR); one finding per repo+workflow while it stays red, however many commits fail.
   */
  async processCiEvents(now: number = Date.now()): Promise<{ processed: number; findings: number }> {
    const evs = this.rows('SELECT * FROM events WHERE processed_at IS NULL ORDER BY ts LIMIT 200');
    let findings = 0;
    for (const e of evs) {
      if (e.branch === e.default_branch) {
        const r = await this.ingestFinding(
          { source: 'ci', kind: 'ci-failure', key: `${e.slug}:${e.workflow}`, title: `CI "${e.workflow}" failing on ${e.branch}`, repo: String(e.slug), url: String(e.url), detail: { sha: e.sha } },
          now,
        );
        if (!r.deduped) findings++;
      }
      this.sql.exec('UPDATE events SET processed_at = ? WHERE id = ?', now, e.id);
    }
    // events are an inbox, not history: keep 14 days
    this.sql.exec('DELETE FROM events WHERE processed_at IS NOT NULL AND processed_at < ?', now - 14 * DAY);
    return { processed: evs.length, findings };
  }

  // ---------- health ----------
  /** Health watcher results. A target failing HEALTH_FAIL_BUDGET checks in a row (the self-heal retry window) becomes a P1. */
  async observeHealth(obs: HealthObservation[], now: number = Date.now()): Promise<{ raised: string[]; recovered: string[] }> {
    const fails = this.getMeta<Record<string, number>>('health:fails') ?? {};
    const raised: string[] = [];
    const recovered: string[] = [];
    for (const o of obs) {
      const kind = o.kind === 'money' ? 'money-path-broken' : 'prod-outage';
      const ident = { source: 'health', kind, key: o.url };
      if (o.ok) {
        if ((fails[o.url] ?? 0) > 0 && (await this.resolveFinding(ident, 'recovered', now))) recovered.push(o.url);
        fails[o.url] = 0;
        continue;
      }
      fails[o.url] = (fails[o.url] ?? 0) + 1;
      if (fails[o.url]! >= this.policy.healthFailBudget) {
        const r = await this.ingestFinding(
          { ...ident, title: `${o.url} down (HTTP ${o.status || 'no response'}, ${fails[o.url]} checks in a row)`, url: o.url, severity: 'P1', selfHealExhausted: true, touches: o.kind === 'money' ? ['money'] : [] },
          now,
        );
        if (!r.deduped) raised.push(o.url);
      }
    }
    this.setMeta('health:fails', fails);
    this.setMeta('health:last', { at: now, obs });
    return { raised, recovered };
  }

  // ---------- messages ----------
  private async emit(msg: Outgoing, now: number): Promise<'sent' | 'duplicate' | 'deferred' | 'failed'> {
    const day = dayKey(now);
    const already = !!this.row('SELECT 1 FROM messages WHERE dedupe_key = ? AND status IN (\'sent\', \'deferred\', \'rolled\')', msg.dedupeKey);
    const sentToday = Number(this.row(`SELECT COUNT(*) AS n FROM messages WHERE day = ? AND status = 'sent' AND kind != 'digest'`, day)?.n ?? 0);
    const digestSent = !!this.row(`SELECT 1 FROM messages WHERE day = ? AND status = 'sent' AND kind = 'digest'`, day);
    const a = admit(msg.kind, already, sentToday, digestSent, this.policy.messageBudgetPerDay);
    if (a === 'duplicate') return 'duplicate';
    const upsert = `INSERT INTO messages (dedupe_key, kind, day, status, text, at, reason) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(dedupe_key) DO UPDATE SET status = excluded.status, day = excluded.day, at = excluded.at, reason = excluded.reason`;
    if (a === 'defer') {
      this.sql.exec(upsert, msg.dedupeKey, msg.kind, day, 'deferred', msg.text, now, 'over daily budget');
      return 'deferred';
    }
    const res = await sendTelegram(this.env.TELEGRAM_BOT_TOKEN, this.env.TELEGRAM_CHAT_ID, msg, this.fetchImpl);
    this.sql.exec(upsert, msg.dedupeKey, msg.kind, day, res.ok ? 'sent' : 'failed', msg.text, now, res.reason ?? null);
    return res.ok ? 'sent' : 'failed';
  }

  // ---------- questions ----------
  private applyAnswer(q: Row, answer: string, how: 'answered' | 'defaulted', now: number): void {
    this.sql.exec('UPDATE questions SET status = ?, answer = ?, answered_at = ? WHERE id = ?', how, answer, now, q.id);
    if (answer === 'proceed') {
      this.sql.exec(`UPDATE jobs SET status = 'queued', answer = ? WHERE id = ? AND status = 'awaiting_answer'`, answer, q.job_id);
      this.sql.exec(`UPDATE findings SET status = 'queued' WHERE fp = ? AND status = 'question'`, q.fp);
    } else {
      this.sql.exec(`UPDATE jobs SET status = 'held', answer = ?, finished_at = ? WHERE id = ? AND status = 'awaiting_answer'`, answer, now, q.job_id);
      this.sql.exec(`UPDATE findings SET status = 'held', closed_at = ?, outcome = 'held by decision' WHERE fp = ? AND status = 'question'`, now, q.fp);
    }
  }

  answerQuestion(id: string, option: string, now: number = Date.now()): { ok: boolean; reason?: string } {
    const q = this.row('SELECT * FROM questions WHERE id = ?', id);
    if (!q) return { ok: false, reason: 'no such question' };
    if (!['pending', 'sent'].includes(String(q.status))) return { ok: false, reason: `question already ${q.status}` };
    const opts = JSON.parse(String(q.options)) as string[];
    if (!opts.includes(option)) return { ok: false, reason: 'unknown option' };
    this.applyAnswer(q, option, 'answered', now);
    return { ok: true };
  }

  private async flushQuestions(now: number): Promise<void> {
    // past the deadline: reversible -> the default is applied; irreversible -> stays held until answered
    for (const q of this.rows(`SELECT * FROM questions WHERE status = 'sent' AND deadline <= ?`, now)) {
      if (Number(q.reversible) === 1) this.applyAnswer(q, String(q.default_opt), 'defaulted', now);
    }
    const deadlineMs = this.policy.questionDeadlineHours * HOUR;
    for (const q of this.rows(`SELECT * FROM questions WHERE status = 'pending' ORDER BY created_at LIMIT 10`)) {
      const deadline = now + deadlineMs;
      const msg = questionMessage({ id: String(q.id), text: String(q.text), options: JSON.parse(String(q.options)), defaultOption: String(q.default_opt), deadline, reversible: Number(q.reversible) === 1 });
      const r = await this.emit(msg, now);
      if (r === 'sent') this.sql.exec(`UPDATE questions SET status = 'sent', sent_at = ?, deadline = ? WHERE id = ?`, now, deadline, q.id);
      else if (r === 'deferred') break; // budget spent for today: the digest carries the rest
    }
  }

  // ---------- dispatch ----------
  private jobsFor(where: string, ...b: unknown[]): HandsJob[] {
    return this.rows(`SELECT j.id, j.fp, j.lane, j.merge_policy, j.answer, f.data FROM jobs j JOIN findings f ON f.fp = j.fp WHERE ${where}`, ...b).map((r) => ({
      id: String(r.id),
      fingerprint: String(r.fp),
      lane: r.lane as 'urgent' | 'nightly',
      mergePolicy: r.merge_policy as MergePolicy,
      finding: JSON.parse(String(r.data)) as Finding,
      ...(r.answer ? { answer: String(r.answer) } : {}),
    }));
  }

  private usage(now: number) {
    return usageGuard(this.getMeta<UsageReport>('usage'), this.policy.usageThresholdPct, now);
  }

  private async startRun(kind: RunKind, jobs: HandsJob[], capMin: number, now: number, provider: HandsProvider = this.hands): Promise<HandsBatch> {
    const runId = uid('run');
    const batch: HandsBatch = { runId, kind, jobs, perJobCapMin: capMin, usageThresholdPct: this.policy.usageThresholdPct, createdAt: now };
    const ref = await provider.start(batch);
    this.sql.exec(
      `INSERT INTO runs (id, kind, provider, external_id, status, day, started_at, cap_min) VALUES (?, ?, ?, ?, 'running', ?, ?, ?)`,
      runId, kind, ref.provider, ref.externalId ?? null, dayKey(now), now, capMin,
    );
    for (const j of jobs) {
      this.sql.exec(`UPDATE jobs SET status = 'running', run_id = ?, started_at = ? WHERE id = ?`, runId, now, j.id);
      this.sql.exec(`UPDATE findings SET status = 'dispatched', acted_at = COALESCE(acted_at, ?) WHERE fp = ?`, now, j.fingerprint);
    }
    return batch;
  }

  /** Urgent lane: one run at a time, URGENT_RUNS_PER_DAY a day, one job per run, URGENT_RUN_CAP_MIN cap. */
  private async dispatchUrgent(now: number): Promise<void> {
    // a stuck urgent run past its cap (+10 min grace) frees the slot and reports could-not-fix
    for (const run of this.rows(`SELECT * FROM runs WHERE kind = 'urgent' AND status = 'running' AND started_at < ?`, now - (this.policy.urgentRunCapMin + 10) * 60000)) {
      this.sql.exec(`UPDATE runs SET status = 'timed_out', finished_at = ? WHERE id = ? AND status = 'running'`, now, run.id);
      for (const j of this.rows(`SELECT id FROM jobs WHERE run_id = ? AND status = 'running'`, run.id)) {
        await this.recordOutcome(String(j.id), { status: 'timed_out', note: `no outcome within ${run.cap_min} min` }, now);
      }
    }
    const queued = this.jobsFor(`j.status = 'queued' AND j.lane = 'urgent' ORDER BY j.created_at`);
    if (!queued.length) return;
    if (this.row(`SELECT 1 FROM runs WHERE kind = 'urgent' AND status = 'running'`)) return; // one at a time; the rest wait
    const today = Number(this.row(`SELECT COUNT(*) AS n FROM runs WHERE kind = 'urgent' AND day = ?`, dayKey(now))?.n ?? 0);
    const guard = this.usage(now);
    if (today >= this.policy.urgentRunsPerDay || !guard.allowed) {
      const why = !guard.allowed ? guard.reason : `urgent cap ${this.policy.urgentRunsPerDay}/day reached`;
      for (const j of queued) {
        // queued for the nightly batch and messaged ONCE per issue
        this.sql.exec(`UPDATE jobs SET lane = 'nightly' WHERE id = ?`, j.id);
        await this.emit({ dedupeKey: `p1:${j.fingerprint}`, kind: 'p1-unhealed', text: `Ebda OS: urgent issue not handled yet: ${j.finding.title}\nNo urgent run now (${why}); queued for tonight's batch.` }, now);
      }
      return;
    }
    await this.startRun('urgent', [queued[0]!], this.policy.urgentRunCapMin, now);
  }

  /** Nightly lane: the one batched run at the end of the day (cron 30 21 * * * UTC = 23:30 Cairo in winter). */
  async runNightly(now: number = Date.now()): Promise<{ started: boolean; jobs: number; reason: string; runId?: string }> {
    const jobs = this.jobsFor(`j.status = 'queued' AND j.lane = 'nightly' ORDER BY j.created_at LIMIT ${NIGHTLY_MAX_JOBS}`);
    if (!jobs.length) return { started: false, jobs: 0, reason: 'queue empty: no container started' };
    const guard = this.usage(now);
    if (!guard.allowed) {
      this.setMeta('usage:refused', { at: now, reason: guard.reason, jobs: jobs.length });
      return { started: false, jobs: jobs.length, reason: guard.reason };
    }
    const b = await this.startRun('nightly', jobs, 45, now);
    return { started: true, jobs: jobs.length, reason: guard.reason, runId: b.runId };
  }

  /** Mac fallback: the mac-local hands claim queued nightly work themselves when awake. */
  async claim(providerName: string, max: number, now: number = Date.now()): Promise<HandsBatch | { refused: string }> {
    const guard = this.usage(now);
    if (!guard.allowed) return { refused: guard.reason };
    const n = Math.max(1, Math.min(max, NIGHTLY_MAX_JOBS));
    const jobs = this.jobsFor(`j.status = 'queued' AND j.lane = 'nightly' ORDER BY j.created_at LIMIT ${n}`);
    if (!jobs.length) return { refused: 'queue empty' };
    const recorder: HandsProvider = { name: providerName, start: async (b) => ({ runId: b.runId, provider: providerName, startedAt: now }) };
    return this.startRun('nightly', jobs, 45, now, recorder);
  }

  getRun(runId: string): HandsBatch | null {
    const run = this.row('SELECT * FROM runs WHERE id = ?', runId);
    if (!run) return null;
    return {
      runId,
      kind: run.kind as RunKind,
      jobs: this.jobsFor(`j.run_id = ? ORDER BY j.created_at`, runId),
      perJobCapMin: Number(run.cap_min),
      usageThresholdPct: this.policy.usageThresholdPct,
      createdAt: Number(run.started_at),
    };
  }

  async recordOutcome(jobId: string, o: JobOutcome, now: number = Date.now()): Promise<{ ok: boolean; reason?: string }> {
    const j = this.row(`SELECT j.*, f.title FROM jobs j JOIN findings f ON f.fp = j.fp WHERE j.id = ?`, jobId);
    if (!j) return { ok: false, reason: 'no such job' };
    if (j.status !== 'running') return { ok: false, reason: `job is ${j.status}, not running` };
    if (o.status === 'skipped_usage') {
      // the hands stopped at the usage threshold before this job: back to the queue, not a failure
      this.sql.exec(`UPDATE jobs SET status = 'queued', run_id = NULL, started_at = NULL, lane = 'nightly' WHERE id = ?`, jobId);
      this.sql.exec(`UPDATE findings SET status = 'queued' WHERE fp = ?`, j.fp);
    } else {
      const ok = o.status === 'merged' || o.status === 'pr_opened' || o.status === 'fix_deployed';
      this.sql.exec(`UPDATE jobs SET status = ?, finished_at = ?, outcome = ? WHERE id = ?`, ok ? 'done' : 'failed', now, JSON.stringify(o), jobId);
      this.sql.exec(`UPDATE findings SET status = ?, closed_at = ?, outcome = ? WHERE fp = ? AND status = 'dispatched'`, ok ? 'done' : 'failed', now, JSON.stringify(o), j.fp);
      if (j.lane === 'urgent') {
        const what = { merged: 'fixed and merged', pr_opened: 'PR opened, needs your review', fix_deployed: 'fix deployed', could_not_fix: 'could NOT fix', timed_out: 'could NOT fix in time', skipped_usage: '' }[o.status];
        await this.emit({ dedupeKey: `outcome:${jobId}`, kind: 'urgent-outcome', text: `Ebda OS urgent: ${what}\n${j.title}${o.prUrl ? `\n${o.prUrl}` : ''}${o.note ? `\n${o.note}` : ''}` }, now);
      }
    }
    if (j.run_id && !this.row(`SELECT 1 FROM jobs WHERE run_id = ? AND status = 'running'`, j.run_id)) {
      this.sql.exec(`UPDATE runs SET status = 'done', finished_at = ? WHERE id = ? AND status = 'running'`, now, j.run_id);
    }
    return { ok: true };
  }

  reportUsage(u: Omit<UsageReport, 'reportedAt'>, now: number = Date.now()): void {
    this.setMeta('usage', { ...u, reportedAt: now } satisfies UsageReport);
  }

  // ---------- self-check + metrics ----------
  /** Findings raised more than 24 h ago that nothing acted on. Each one is a bug in the OS, not a message. */
  selfCheck(now: number = Date.now()): string[] {
    // a question that was sent counts as acted (the OS asked); mark it first so the ratio and the check reflect it
    this.sql.exec(`UPDATE findings SET acted_at = (SELECT MIN(sent_at) FROM questions q WHERE q.fp = findings.fp AND q.sent_at IS NOT NULL) WHERE acted_at IS NULL AND status = 'question'`);
    const stale = this.rows(`SELECT fp FROM findings WHERE acted_at IS NULL AND status IN ('open', 'queued', 'question') AND raised_at <= ?`, now - UNACTED_LIMIT_MS).map((r) => String(r.fp));
    this.setMeta('os:bugs', { at: now, fps: stale });
    return stale;
  }

  actedOn(now: number, windowMs: number): ActedOn {
    const r = this.row(`SELECT COUNT(*) AS raised, SUM(CASE WHEN acted_at IS NOT NULL THEN 1 ELSE 0 END) AS acted FROM findings WHERE raised_at > ?`, now - windowMs);
    const raised = Number(r?.raised ?? 0);
    const acted = Number(r?.acted ?? 0);
    return { raised, acted, ratio: raised ? acted / raised : null };
  }

  /** The 5-minute tick: expire/send questions, dispatch urgent work, self-check. */
  async tick(now: number = Date.now()): Promise<{ osBugs: number }> {
    await this.flushQuestions(now);
    await this.dispatchUrgent(now);
    return { osBugs: this.selfCheck(now).length };
  }

  /** The one daily digest: outcomes (not noticings), acted-on ratio, decisions waiting, rolled-up messages. */
  async digest(now: number = Date.now()): Promise<string> {
    const since = now - DAY;
    const outcomes: Array<{ title: string; status: string; prUrl: string | null }> = this.rows(`SELECT f.title, j.outcome FROM jobs j JOIN findings f ON f.fp = j.fp WHERE j.finished_at > ? AND j.outcome IS NOT NULL ORDER BY j.finished_at`, since).map((r) => {
      const o = JSON.parse(String(r.outcome)) as JobOutcome;
      return { title: String(r.title), status: o.status, prUrl: o.prUrl ?? null };
    });
    for (const r of this.rows(`SELECT title, outcome FROM findings WHERE status = 'resolved' AND closed_at > ?`, since)) outcomes.push({ title: String(r.title), status: String(r.outcome ?? 'resolved'), prUrl: null });
    const a24 = this.actedOn(now, DAY);
    const a7 = this.actedOn(now, 7 * DAY);
    const pending = this.rows(`SELECT id, text, default_opt FROM questions WHERE status = 'pending' ORDER BY created_at LIMIT 10`);
    const rolled = this.rows(`SELECT dedupe_key, text FROM messages WHERE status = 'deferred' ORDER BY at`);
    const refused = this.getMeta<{ at: number; reason: string }>('usage:refused');
    const msg = digestMessage({
      day: dayKey(now),
      outcomes,
      raised24h: a24.raised,
      acted24h: a24.acted,
      ratio7d: a7.ratio,
      pendingQuestions: pending.map((q) => ({ id: String(q.id), text: String(q.text), defaultOption: String(q.default_opt) })),
      rolledUp: rolled.map((r) => String(r.text)),
      osBugs: this.selfCheck(now).length,
      usageNote: refused && now - refused.at < DAY ? refused.reason : null,
    });
    const r = await this.emit(msg, now);
    if (r === 'sent') {
      for (const m of rolled) this.sql.exec(`UPDATE messages SET status = 'rolled' WHERE dedupe_key = ?`, m.dedupe_key);
      // questions delivered through the digest start their deadline now
      const deadline = now + this.policy.questionDeadlineHours * HOUR;
      for (const q of pending) this.sql.exec(`UPDATE questions SET status = 'sent', sent_at = ?, deadline = ? WHERE id = ? AND status = 'pending'`, now, deadline, q.id);
    }
    return r;
  }

  // ---------- dashboard ----------
  state(now: number = Date.now()): BrainState {
    const count = (q: string, ...b: unknown[]) => Number(this.row(q, ...b)?.n ?? 0);
    const day = dayKey(now);
    const bugs = this.getMeta<{ at: number; fps: string[] }>('os:bugs');
    return {
      generatedAt: now,
      findings: {
        open: count(`SELECT COUNT(*) AS n FROM findings WHERE status NOT IN ('done','failed','held','resolved')`),
        recent: this.rows(`SELECT fp, source, kind, title, repo, url, lane, reason, status, raised_at, acted_at, seen_count FROM findings ORDER BY last_seen DESC LIMIT 50`) as unknown as FindingRow[],
      },
      jobs: {
        queuedUrgent: count(`SELECT COUNT(*) AS n FROM jobs WHERE status = 'queued' AND lane = 'urgent'`),
        queuedNightly: count(`SELECT COUNT(*) AS n FROM jobs WHERE status = 'queued' AND lane = 'nightly'`),
        awaitingAnswer: count(`SELECT COUNT(*) AS n FROM jobs WHERE status = 'awaiting_answer'`),
        running: count(`SELECT COUNT(*) AS n FROM jobs WHERE status = 'running'`),
      },
      runs: this.rows(`SELECT id, kind, provider, status, started_at, finished_at FROM runs ORDER BY started_at DESC LIMIT 20`) as unknown as RunRow[],
      questions: this.rows(`SELECT id, text, options, default_opt, reversible, status, deadline FROM questions WHERE status IN ('pending','sent') ORDER BY created_at`).map((q) => ({ ...q, options: JSON.parse(String(q.options)) as string[] }) as unknown as QuestionRow),
      messages: {
        sentToday: count(`SELECT COUNT(*) AS n FROM messages WHERE day = ? AND status = 'sent' AND kind != 'digest'`, day),
        budget: this.policy.messageBudgetPerDay,
        deferred: count(`SELECT COUNT(*) AS n FROM messages WHERE status = 'deferred'`),
        failed: count(`SELECT COUNT(*) AS n FROM messages WHERE day = ? AND status = 'failed'`, day),
      },
      actedOn: { d1: this.actedOn(now, DAY), d7: this.actedOn(now, 7 * DAY) },
      osBugs: bugs?.fps.length ?? 0,
      usage: { report: this.getMeta<UsageReport>('usage'), guard: this.usage(now), thresholdPct: this.policy.usageThresholdPct },
      health: this.getMeta<BrainState['health']>('health:last'),
      advisories: this.getMeta<AdvisoryRunSummary>('advisories:last'),
    };
  }

  setMetaPublic(k: string, v: unknown): void {
    this.setMeta(k, v);
  }
}
