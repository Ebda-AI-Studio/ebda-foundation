// BrainDO: the one SQLite-backed Durable Object that owns the finding -> job pipeline, the hands runs, the questions,
// the Telegram budget and dedupe, and the counters behind the dashboard. A single instance (idFromName('brain')) keeps
// every decision strongly consistent; KV is used only outside it, where eventual consistency is fine.
//
// Finding lifecycle: open -> queued | question -> dispatched -> done | failed | held | resolved
//   "acted" = a job was dispatched to the hands, a question was asked, or the finding resolved. The acted-on ratio is
//   acted / raised; a finding still unacted 24 h after it was raised is an OS bug (self-check), shown on the dashboard
//   and in the digest, never a separate message.
import { DurableObject } from 'cloudflare:workers';
import { classifyFinding, HALT_KINDS } from './classify';
import { authMode } from './hands-container';
import type { Env, Policy } from './env';
import { intVar, numberVar, policyFrom } from './env';
import { evidenceOf, fingerprint, type Finding, type Lane, type MergePolicy } from './findings';
import { providerFor, type JobUsage, type HandsBatch, type HandsJob, type HandsProvider, type JobOutcome, type RunKind, type UsageReport } from './hands';
import { admit, dayKey, digestMessage, MONITOR_NOTES_PER_DIGEST, questionMessage, sendTelegram, URGENT_KINDS, type MsgKind, type Outgoing } from './telegram';
import { usageGuard } from './usage';
import type { AdvisoryRunSummary } from './watchers/advisories';

/** HANDS-COORD: the longest a controller lease may run before it must be renewed. */
export const LEASE_MAX_MIN = 240;
const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;
export const NIGHTLY_MAX_JOBS = 25;
export const UNACTED_LIMIT_MS = DAY;
/** A nightly job whose run died is requeued once; the second death ends it as timed_out. */
export const NIGHTLY_MAX_TRIES = 2;
export const WAITING_MAX_MS = 14 * DAY;
/** In flight: a re-sighting only updates last_seen (and may promote the lane, never demote it). `waiting` = fix PR open. */
const ACTIVE = new Set(['open', 'queued', 'question', 'dispatched', 'waiting', 'digest']);
/** Re-sighting rules after a finding left the active set (controller ruling 4a-I1):
 *  - held (Ahmad said hold): never reopened by a re-sighting; only a resolution clears it.
 *  - done / failed / resolved: reopened only after the cool-down AND only when the evidence changed. A persistent outage
 *    keeps one incident id as its evidence, so it is ONE urgent run, then the outcome message, never a run per tick. */
export const COOLDOWN_MS = 24 * HOUR;
export const URGENT_COOLDOWN_MS = 6 * HOUR;
/** Failed urgent-class sends: tries at t, t+5 min, t+15 min, then "undelivered" and rolled into the digest. */
export const RETRY_BACKOFF_MS = [5 * 60000, 10 * 60000];

/** Model routing (final decision, LEAN mode): haiku for triage / classification / summaries / digest text, sonnet for everything that
 *  writes code, opus ONLY for a job explicitly flagged security-design or money-design, capped per day. Nothing routes to opus by default. */
export const HAIKU_KINDS: ReadonlySet<string> = new Set(['triage', 'classification', 'classify', 'summary', 'summarize', 'digest-text']);
export const OPUS_FLAGS: ReadonlySet<string> = new Set(['security-design', 'money-design']);
export type ModelAlias = 'haiku' | 'sonnet' | 'opus';
export function modelFor(f: Finding, defaultModel: string | undefined): ModelAlias {
  if ((f.touches ?? []).some((t) => OPUS_FLAGS.has(String(t).toLowerCase()))) return 'opus';
  if (HAIKU_KINDS.has(f.kind.toLowerCase())) return 'haiku';
  return defaultModel === 'haiku' ? 'haiku' : 'sonnet'; // the default can be lowered, never raised to opus
}
const monthKey = (now: number) => new Date(now).toISOString().slice(0, 7);

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
  repo?: string;
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
  /** HANDS-COORD controller leases that are live now */
  leases: Row[];
  /** last time each external monitor reported (epoch ms, null = never) */
  sources: { prodWatchSeenAt: number | null };
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
  /** watcher ids with an open monitor-unconfigured finding: the post-deploy cutover gate fails while any PORT-BRAIN id is here */
  unconfigured: string[];
  /** F-01: why the hands are halted, or null */
  halt: string | null;
  /** dollars spent today / this month vs the budgets, and the model mix this month */
  spend: { day: number; month: number; dailyBudget: number; monthlyBudget: number; byModel: Record<string, number> };
  /** F-05: last Cloudflare footprint reading (null = never read) */
  footprint: Footprint | null;
  /** the footprint watcher's warn / stop levels for the estimated Cloudflare month (CF_WARN_USD / CF_STOP_USD) */
  cfLimits: { warnUsd: number; stopUsd: number };
  /** each watcher that is not running and what it is missing (from its monitor-unconfigured finding) */
  gaps: Array<{ id: string; missing: string }>;
  /** the text the next 05:00 digest would send if it ran now (built, never sent) */
  digestPreview: string;
}

export interface Footprint {
  at: number;
  unknown: boolean;
  estUsd?: number;
  containerMin?: number;
  doRequests?: number;
  doRowsWritten?: number;
  kvWrites?: number;
  workersRequests?: number;
  note?: string;
}

function mappedReposFrom(json: string | undefined): Set<string> | null {
  if (!json) return null;
  try {
    const repos = (JSON.parse(json) as { repos?: Record<string, unknown> }).repos;
    return repos && typeof repos === 'object' ? new Set(Object.keys(repos)) : null;
  } catch {
    return null;
  }
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
  /** owner/name keys of the hands config (HANDS_CONFIG_JSON); null = no readable config, membership is not checked. Replaceable in tests. */
  mappedRepos: Set<string> | null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.hands = providerFor(env.HANDS_PROVIDER ?? 'stub', env);
    this.policy = policyFrom(env);
    this.mappedRepos = mappedReposFrom(env.HANDS_CONFIG_JSON);
    ctx.blockConcurrencyWhile(async () => this.migrate());
  }

  private migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS findings (
        fp TEXT PRIMARY KEY, source TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, title TEXT NOT NULL,
        repo TEXT, url TEXT, data TEXT NOT NULL, lane TEXT NOT NULL, reason TEXT NOT NULL, merge_policy TEXT NOT NULL,
        status TEXT NOT NULL, first_seen INTEGER NOT NULL, raised_at INTEGER NOT NULL, last_seen INTEGER NOT NULL,
        seen_count INTEGER NOT NULL DEFAULT 1, reopened INTEGER NOT NULL DEFAULT 0, acted_at INTEGER, closed_at INTEGER, outcome TEXT,
        evidence TEXT NOT NULL DEFAULT '');
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
        at INTEGER NOT NULL, reason TEXT, attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER);
      CREATE INDEX IF NOT EXISTS messages_day ON messages(day, status);
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY, slug TEXT NOT NULL, sha TEXT NOT NULL, workflow TEXT NOT NULL, branch TEXT NOT NULL,
        default_branch TEXT NOT NULL, url TEXT NOT NULL, ts INTEGER NOT NULL, processed_at INTEGER);
      CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS auth_fail (ip TEXT NOT NULL, at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS auth_fail_ip ON auth_fail(ip, at);
      CREATE TABLE IF NOT EXISTS leases (repo TEXT PRIMARY KEY, holder TEXT NOT NULL, note TEXT, claimed_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
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
    const evidence = await evidenceOf(f);
    let c = classifyFinding(f);
    // I-2: a finding the hands cannot work on (no repo, or a repo missing from their config) never spends a container
    let unmappedUrgent = false;
    if (c.lane !== 'digest' && (!f.repo || (this.mappedRepos !== null && !this.mappedRepos.has(f.repo)))) {
      unmappedUrgent = c.lane === 'urgent';
      c = { lane: 'digest', reason: `${f.repo ? `repo ${f.repo} is not in the hands config` : 'no repo mapped'}: cannot auto-fix, digest only (was ${c.lane})`, mergePolicy: 'pr-and-question' };
    }
    if (HALT_KINDS.has(f.kind.toLowerCase())) await this.setHalt(f.title, now, false); // F-01: the alert is the finding's own p1 message below
    const existing = this.row('SELECT status, lane, reason, evidence, closed_at FROM findings WHERE fp = ?', fp);
    const data = JSON.stringify(f);
    if (existing) {
      const status = String(existing.status);
      const seen = () => this.sql.exec('UPDATE findings SET last_seen = ?, seen_count = seen_count + 1 WHERE fp = ?', now, fp);
      if (ACTIVE.has(status)) {
        seen();
        this.sql.exec('UPDATE findings SET data = ?, evidence = ? WHERE fp = ?', data, evidence, fp);
        const promoted = this.promote(fp, String(existing.lane), c, now);
        return { fp, deduped: true, reopened: false, lane: promoted ? 'urgent' : (existing.lane as Lane), reason: promoted ? c.reason : String(existing.reason), jobId: null };
      }
      const urgentClass = existing.lane === 'urgent' || c.lane === 'urgent';
      const cooled = now - Number(existing.closed_at ?? 0) >= (urgentClass ? URGENT_COOLDOWN_MS : COOLDOWN_MS);
      // N-1: a watcher's "config missing" note that was resolved (it ran configured) and is raised again means the config is gone AGAIN:
      // no cool-down, no evidence check, or the post-deploy gate would read a regression as clear
      const gapAgain = f.kind === 'monitor-unconfigured' && status === 'resolved';
      if (status === 'held' || (!gapAgain && (!cooled || evidence === String(existing.evidence)))) {
        seen();
        return { fp, deduped: true, reopened: false, lane: existing.lane as Lane, reason: String(existing.reason), jobId: null };
      }
      // a new occurrence after the cool-down: same row, counted, new job (one fingerprint, never a second finding)
      this.sql.exec(
        `UPDATE findings SET status = 'open', data = ?, evidence = ?, title = ?, lane = ?, reason = ?, merge_policy = ?, raised_at = ?, last_seen = ?,
         seen_count = seen_count + 1, reopened = reopened + 1, acted_at = NULL, closed_at = NULL, outcome = NULL WHERE fp = ?`,
        data, evidence, f.title, c.lane, c.reason, c.mergePolicy, now, now, fp,
      );
    } else {
      this.sql.exec(
        `INSERT INTO findings (fp, source, kind, key, title, repo, url, data, evidence, lane, reason, merge_policy, status, first_seen, raised_at, last_seen)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?, ?)`,
        fp, f.source, f.kind, f.key, f.title, f.repo ?? null, f.url ?? null, data, evidence, c.lane, c.reason, c.mergePolicy, now, now, now,
      );
    }
    if (c.lane === 'digest') {
      // digest-only: no job, no question, no message. Counted as acted (the digest is the action) so self-check never flags it.
      this.sql.exec(`UPDATE findings SET status = 'digest', acted_at = COALESCE(acted_at, ?) WHERE fp = ?`, now, fp);
      if (existing) this.setMeta('digest:shown', (this.getMeta<string[]>('digest:shown') ?? []).filter((x) => x !== fp)); // a recurrence is news again
      if (c.alert) await this.emit({ dedupeKey: `p1:${fp}:alert:${evidence}`, kind: 'p1-unhealed', text: `Ebda OS: ${f.title}\n${c.reason}.` }, now);
      if (unmappedUrgent) await this.emit({ dedupeKey: `p1:${fp}:unmapped:${evidence}`, kind: 'p1-unhealed', text: `Ebda OS: could not self-heal: ${f.title}\n${c.reason}.` }, now);
      return { fp, deduped: false, reopened: !!existing, lane: 'digest', reason: c.reason, jobId: null };
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

  /**
   * Re-classification on a re-sighting may only go UP (ruling 4a-I3): a nightly or question finding that is now urgent
   * (a CVE newly CISA-KEV listed, a CVSS raised to >= 9) is promoted while its job has not been handed out. A job already
   * running or with a PR open keeps its lane; nothing is ever demoted.
   */
  private promote(fp: string, oldLane: string, c: ReturnType<typeof classifyFinding>, now: number): boolean {
    if (c.lane !== 'urgent' || oldLane === 'urgent') return false;
    const job = this.row(`SELECT id FROM jobs WHERE fp = ? AND status IN ('queued', 'awaiting_answer') ORDER BY created_at DESC`, fp);
    if (!job) return false;
    this.sql.exec(`UPDATE jobs SET lane = 'urgent', status = 'queued', merge_policy = ? WHERE id = ?`, c.mergePolicy, job.id);
    this.sql.exec(`UPDATE questions SET status = 'cancelled', answered_at = ? WHERE fp = ? AND status IN ('pending', 'sent')`, now, fp);
    this.sql.exec(`UPDATE findings SET lane = 'urgent', reason = ?, merge_policy = ?, status = 'queued' WHERE fp = ?`, `promoted: ${c.reason}`, c.mergePolicy, fp);
    return true;
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
    if (!r || r.status === 'resolved') return false;
    this.sql.exec(`UPDATE findings SET status = 'resolved', closed_at = ?, acted_at = COALESCE(acted_at, ?), outcome = ? WHERE fp = ?`, now, now, outcome, fp);
    // jobs not yet handed out are cancelled; a running job finishes and reports normally
    this.sql.exec(`UPDATE jobs SET status = 'cancelled', finished_at = ? WHERE fp = ? AND status IN ('queued', 'awaiting_answer')`, now, fp);
    this.sql.exec(`UPDATE questions SET status = 'cancelled' WHERE fp = ? AND status IN ('pending', 'sent')`, fp);
    return true;
  }

  /**
   * Restore drills run on the Mac (ruling F-I6: the drill needs R2 + age secrets the container must not hold) and post
   * their PASS/FAIL here (POST /drill). Only a PASS counts as fresh; a FAIL is recorded and leaves the drill stale.
   */
  async recordDrill(result: 'pass' | 'fail', note: string | undefined, now: number = Date.now()): Promise<void> {
    this.setMeta('drill:last', { at: now, result, ...(note ? { note: note.slice(0, 300) } : {}) });
    if (result !== 'pass') return;
    this.setMeta('drill:last-pass', now);
    for (const kind of ['dr-drill-stale', 'dr-drill-overdue']) await this.resolveFinding({ source: 'watcher', kind, key: `dr-drill:ebda-store:${kind === 'dr-drill-stale' ? 'stale' : 'overdue'}` }, 'restore drill passed', now);
  }

  /**
   * The hands container refused to run (exit 3: it could not lock down egress, e.g. no CAP_NET_ADMIN on the platform). That is not a
   * monitor note: no auto-fix will run at all until it is fixed, so it is a P1 message (once a day). The run counts as failed and its
   * jobs go back to the queue; an unknown run id still raises the message.
   */
  async handsRefused(runId: string, reason: string, now: number = Date.now()): Promise<{ ok: boolean }> {
    const run = this.row('SELECT status FROM runs WHERE id = ?', runId);
    if (run?.status === 'running') {
      this.sql.exec(`UPDATE runs SET status = 'failed', finished_at = ? WHERE id = ?`, now, runId);
      for (const j of this.rows(`SELECT id, fp FROM jobs WHERE run_id = ? AND status = 'running'`, runId)) {
        this.sql.exec(`UPDATE jobs SET status = 'queued', run_id = NULL, started_at = NULL WHERE id = ?`, j.id);
        this.sql.exec(`UPDATE findings SET status = 'queued' WHERE fp = ? AND status = 'dispatched'`, j.fp);
      }
    }
    this.setMeta('hands:refused', { at: now, runId, reason: reason.slice(0, 200) });
    await this.emit({ dedupeKey: `hands-refused:${dayKey(now)}`, kind: 'p1-unhealed', text: `Ebda OS: the hands container refused to run: ${reason.slice(0, 200)}\nNo auto-fix or nightly work runs until this is fixed (the egress lock needs CAP_NET_ADMIN on the container platform). Jobs stay queued.` }, now);
    return { ok: true };
  }

  /** Newest PASS of the weekly restore drill (posted by the Mac), or null. The signature keeps the watcher Sink shape. */
  lastPassAt(_source: string, _kind: string): number | null {
    return this.getMeta<number>('drill:last-pass');
  }

  // ---------- controller leases (launch-map row HANDS-COORD) ----------
  // A controller (a Claude session or Ahmad) that is working in a repo holds a lease on it. While a lease is live the brain hands NO
  // job for that repo to any provider (the jobs stay queued), and the hands re-check the lease before they touch the repo. A lease
  // always expires (max LEASE_MAX_MIN), so a crashed controller cannot freeze the hands for longer than that.
  async claimLease(repo: string, holder: string, ttlMin: number, note: string | undefined, now: number = Date.now()): Promise<{ ok: boolean; holder: string; expiresAt: number }> {
    const r = repo.toLowerCase();
    const cur = this.row(`SELECT holder, expires_at FROM leases WHERE repo = ?`, r);
    if (cur && Number(cur.expires_at) > now && String(cur.holder) !== holder) return { ok: false, holder: String(cur.holder), expiresAt: Number(cur.expires_at) };
    const exp = now + Math.max(1, Math.min(LEASE_MAX_MIN, Math.floor(ttlMin))) * 60_000;
    this.sql.exec(`INSERT INTO leases (repo, holder, note, claimed_at, expires_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(repo) DO UPDATE SET holder = excluded.holder, note = excluded.note, claimed_at = excluded.claimed_at, expires_at = excluded.expires_at`, r, holder, note?.slice(0, 200) ?? null, now, exp);
    return { ok: true, holder, expiresAt: exp };
  }

  async releaseLease(repo: string, holder: string): Promise<boolean> {
    const r = repo.toLowerCase();
    const cur = this.row(`SELECT holder FROM leases WHERE repo = ?`, r);
    if (!cur || String(cur.holder) !== holder) return false;
    this.sql.exec(`DELETE FROM leases WHERE repo = ?`, r);
    return true;
  }

  async activeLeases(now: number = Date.now()): Promise<Array<{ repo: string; holder: string; expiresAt: number; note?: string }>> {
    this.sql.exec(`DELETE FROM leases WHERE expires_at <= ?`, now);
    return this.rows(`SELECT repo, holder, note, expires_at FROM leases ORDER BY repo`).map((r) => ({ repo: String(r.repo), holder: String(r.holder), expiresAt: Number(r.expires_at), ...(r.note ? { note: String(r.note) } : {}) }));
  }

  /** Queued jobs minus those whose repo has a live controller lease (they stay queued for a later tick). */
  private unleased(jobs: HandsJob[], now: number): HandsJob[] {
    const leased = new Set(this.rows(`SELECT repo FROM leases WHERE expires_at > ?`, now).map((r) => String(r.repo)));
    return leased.size ? jobs.filter((j) => !leased.has(String(j.finding.repo ?? '').toLowerCase())) : jobs;
  }

  // ---------- external monitors (prod-watch) ----------
  /**
   * Resolve every open finding of `source` (any kind) whose key is not in `openKeys`, except keys starting with one of
   * `keepPrefixes` (the monitor could not evaluate them this run, so their state is unknown, not clear). Records the heartbeat.
   */
  async reconcileSource(source: string, openKeys: string[], keepPrefixes: string[], now: number = Date.now()): Promise<number> {
    const open = new Set(openKeys);
    let n = 0;
    for (const r of this.rows(`SELECT kind, key FROM findings WHERE source = ? AND status != 'resolved'`, source)) {
      const key = String(r.key);
      if (open.has(key) || keepPrefixes.some((p) => key.startsWith(p))) continue;
      if (await this.resolveFinding({ source, kind: String(r.kind), key }, 'cleared at the source', now)) n++;
    }
    this.setMeta(`source:seen:${source}`, now);
    return n;
  }

  /** Resolve every open finding of source+kind whose key is not in `openKeys` (complete advisory listing only). */
  async reconcile(source: string, kind: string, keyPrefix: string, openKeys: string[], now: number = Date.now()): Promise<number> {
    const open = new Set(openKeys);
    let n = 0;
    for (const r of this.rows(`SELECT key FROM findings WHERE source = ? AND kind = ? AND status != 'resolved'`, source, kind)) {
      const key = String(r.key);
      if (key.startsWith(keyPrefix) && !open.has(key) && (await this.resolveFinding({ source, kind, key }, 'no longer reported', now))) n++;
    }
    return n;
  }

  // ---------- CI events (from the relay webhook) ----------
  /** A green default-branch run: close the workflow's CI finding, and remember when (M-4: a red event older than this is stale). */
  async resolveCi(slug: string, workflow: string, runKey: string, now: number = Date.now()): Promise<boolean> {
    // M-3: the signed run id + attempt is the identity of a green; a replay of one already applied changes nothing, so it can never
    // close a NEWER red that opened after it
    const seen = this.getMeta<string[]>('ci:green:seen') ?? [];
    if (seen.includes(runKey)) return false;
    this.setMeta('ci:green:seen', [...seen, runKey].slice(-500));
    const greens = this.getMeta<Record<string, number>>('ci:green') ?? {};
    greens[`${slug}:${workflow}`] = now;
    // bounded: keep the 500 newest
    const keep = Object.entries(greens).sort((a, b) => b[1] - a[1]).slice(0, 500);
    this.setMeta('ci:green', Object.fromEntries(keep));
    this.setMeta(`ci:green:last`, runKey);
    return this.resolveFinding({ source: 'ci', kind: 'ci-failure', key: `${slug}:${workflow}` }, 'CI green again', now);
  }

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
    const greens = this.getMeta<Record<string, number>>('ci:green') ?? {};
    let findings = 0;
    for (const e of evs) {
      // M-4: a failure that arrived BEFORE the newest green run of the same workflow is already fixed; raising it would cost a Claude run on a green CI
      const staleRed = Number(e.ts) <= (greens[`${e.slug}:${e.workflow}`] ?? 0);
      if (e.branch === e.default_branch && !staleRed) {
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
    // the start of the current failure streak is the incident's evidence: one streak = one incident = one urgent run
    const since = this.getMeta<Record<string, number>>('health:since') ?? {};
    const raised: string[] = [];
    const recovered: string[] = [];
    for (const o of obs) {
      const kind = o.kind === 'money' ? 'money-path-broken' : 'prod-outage';
      const ident = { source: 'health', kind, key: o.url };
      if (o.ok) {
        if ((fails[o.url] ?? 0) > 0 && (await this.resolveFinding(ident, 'recovered', now))) recovered.push(o.url);
        fails[o.url] = 0;
        delete since[o.url];
        continue;
      }
      fails[o.url] = (fails[o.url] ?? 0) + 1;
      since[o.url] ??= now;
      if (fails[o.url]! >= this.policy.healthFailBudget) {
        const r = await this.ingestFinding(
          { ...ident, title: `${o.url} down (HTTP ${o.status || 'no response'}, ${fails[o.url]} checks in a row)`, url: o.url, ...(o.repo ? { repo: o.repo } : {}), severity: 'P1', selfHealExhausted: true, touches: o.kind === 'money' ? ['money'] : [], detail: { incident: since[o.url] } },
          now,
        );
        if (!r.deduped) raised.push(o.url);
      }
    }
    this.setMeta('health:fails', fails);
    this.setMeta('health:since', since);
    this.setMeta('health:last', { at: now, obs });
    return { raised, recovered };
  }

  // ---------- messages ----------
  private dayCounts(day: string) {
    const r = this.row(
      `SELECT SUM(CASE WHEN kind IN ('urgent-outcome','p1-unhealed') THEN 1 ELSE 0 END) AS urgent,
              SUM(CASE WHEN kind NOT IN ('urgent-outcome','p1-unhealed','digest') THEN 1 ELSE 0 END) AS normal,
              SUM(CASE WHEN kind = 'digest' THEN 1 ELSE 0 END) AS digest
       FROM messages WHERE day = ? AND status = 'sent'`,
      day,
    );
    return { normal: Number(r?.normal ?? 0), urgent: Number(r?.urgent ?? 0), digest: Number(r?.digest ?? 0) > 0 };
  }

  private async emit(msg: Outgoing, now: number): Promise<'sent' | 'duplicate' | 'deferred' | 'failed'> {
    const day = dayKey(now);
    const urgent = URGENT_KINDS.has(msg.kind);
    // F-09: a failed send of ANY kind (urgent or a question) is owned by the bounded retry path (3 tries, honouring retry_after),
    // never re-sent by the next tick. A revoked token (401/403) stops every send for the day.
    if (this.getMeta(`tg:blocked:${day}`)) return 'failed';
    const already = !!this.row(`SELECT 1 FROM messages WHERE dedupe_key = ? AND status IN ('sent', 'deferred', 'rolled', 'undelivered', 'failed')`, msg.dedupeKey);
    const a = admit(msg.kind, already, this.dayCounts(day), this.policy.messageBudgetPerDay, this.policy.urgentMessageBudgetPerDay);
    if (a === 'duplicate') return 'duplicate';
    const upsert = `INSERT INTO messages (dedupe_key, kind, day, status, text, at, reason, attempts, next_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(dedupe_key) DO UPDATE SET status = excluded.status, day = excluded.day, at = excluded.at, reason = excluded.reason,
                    attempts = excluded.attempts, next_at = excluded.next_at`;
    if (a === 'defer') {
      this.sql.exec(upsert, msg.dedupeKey, msg.kind, day, 'deferred', msg.text, now, 'over daily budget', 0, null);
      return 'deferred';
    }
    const res = await sendTelegram(this.env.TELEGRAM_BOT_TOKEN, this.env.TELEGRAM_CHAT_ID, msg, this.fetchImpl);
    if (!res.ok && (res.status === 401 || res.status === 403)) this.setMeta(`tg:blocked:${day}`, { at: now, status: res.status });
    const nextAt = !res.ok && res.status !== 401 && res.status !== 403 ? now + (res.retryAfterMs ?? RETRY_BACKOFF_MS[0]!) : null;
    this.sql.exec(upsert, msg.dedupeKey, msg.kind, day, res.ok ? 'sent' : 'failed', msg.text, now, res.reason ?? null, 1, nextAt);
    if (nextAt !== null) await this.scheduleRetry(nextAt);
    return res.ok ? 'sent' : 'failed';
  }

  private async scheduleRetry(at: number): Promise<void> {
    // F-11: never sooner than a minute from now, whatever a row says
    at = Math.max(at, Date.now() + 60_000);
    const cur = await this.ctx.storage.getAlarm();
    if (cur === null || cur > at) await this.ctx.storage.setAlarm(at);
  }

  /** Retry failed urgent-class sends (ruling 4a-I5): 3 tries over 15 min, then "undelivered" and into the digest. */
  async retryFailed(now: number = Date.now()): Promise<{ sent: number; undelivered: number }> {
    let sent = 0;
    let undelivered = 0;
    if (this.getMeta(`tg:blocked:${dayKey(now)}`)) return { sent: 0, undelivered: 0 };
    for (const m of this.rows(`SELECT * FROM messages WHERE status = 'failed' AND kind IN ('urgent-outcome','p1-unhealed','question') AND next_at IS NOT NULL AND next_at <= ?`, now)) {
      const q = String(m.kind) === 'question' ? this.questionForKey(String(m.dedupe_key)) : null;
      const res = await sendTelegram(this.env.TELEGRAM_BOT_TOKEN, this.env.TELEGRAM_CHAT_ID, { dedupeKey: String(m.dedupe_key), kind: m.kind as MsgKind, text: String(m.text), ...(q ? { buttons: q.buttons } : {}) }, this.fetchImpl);
      const attempts = Number(m.attempts) + 1;
      if (!res.ok && (res.status === 401 || res.status === 403)) {
        this.setMeta(`tg:blocked:${dayKey(now)}`, { at: now, status: res.status });
        this.sql.exec(`UPDATE messages SET attempts = ?, next_at = NULL, status = 'undelivered', reason = ? WHERE dedupe_key = ?`, attempts, res.reason ?? 'telegram refused the bot', m.dedupe_key);
        undelivered++;
        break;
      }
      if (res.ok) {
        this.sql.exec(`UPDATE messages SET status = 'sent', day = ?, at = ?, attempts = ?, next_at = NULL, reason = NULL WHERE dedupe_key = ?`, dayKey(now), now, attempts, m.dedupe_key);
        if (q) this.sql.exec(`UPDATE questions SET status = 'sent', sent_at = ?, deadline = ? WHERE id = ? AND status = 'pending'`, now, now + this.policy.questionDeadlineHours * HOUR, q.id);
        sent++;
      } else if (attempts >= RETRY_BACKOFF_MS.length + 1) {
        this.sql.exec(`UPDATE messages SET status = 'undelivered', attempts = ?, next_at = NULL, reason = ? WHERE dedupe_key = ?`, attempts, res.reason ?? 'send failed', m.dedupe_key);
        undelivered++;
      } else {
        const nextAt = now + (res.retryAfterMs ?? RETRY_BACKOFF_MS[attempts - 1]!);
        this.sql.exec(`UPDATE messages SET attempts = ?, next_at = ?, reason = ? WHERE dedupe_key = ?`, attempts, nextAt, res.reason ?? 'send failed', m.dedupe_key);
        await this.scheduleRetry(nextAt);
      }
    }
    return { sent, undelivered };
  }

  /** The buttons of a question message, rebuilt from its row (retry of a failed question send). */
  private questionForKey(key: string): { id: string; buttons: Array<{ text: string; data: string }> } | null {
    const id = key.startsWith('q:') ? key.slice(2) : '';
    const q = id ? this.row('SELECT id, options, default_opt FROM questions WHERE id = ?', id) : null;
    if (!q) return null;
    const msg = questionMessage({ id: String(q.id), text: '', options: JSON.parse(String(q.options)), defaultOption: String(q.default_opt), deadline: 0, reversible: true });
    return { id: String(q.id), buttons: msg.buttons ?? [] };
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    try {
      await this.retryFailed(now);
    } catch (e) {
      // F-11: a throw mid-loop must not leave a past `next_at` that re-fires at once; try again in 5 minutes
      console.error('retryFailed threw', (e as Error).message);
      await this.ctx.storage.setAlarm(now + 5 * 60_000);
      return;
    }
    const next = this.row(`SELECT MIN(next_at) AS t FROM messages WHERE status = 'failed' AND next_at IS NOT NULL`);
    if (next?.t !== null && next?.t !== undefined) await this.ctx.storage.setAlarm(Math.max(Number(next.t), now + 60_000));
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

  /** Unknown usage + a real provider: at most one job per run. Known usage, or the stub provider: the limit asked for. */
  /** An open major/critical incident of GitHub or Anthropic (world-watch `vendor-incident`), or null. */
  private vendorOutage(): string | null {
    const r = this.row(`SELECT title FROM findings WHERE kind = 'vendor-incident' AND status != 'resolved' AND (key LIKE 'world-watch:github%' OR key LIKE 'world-watch:anthropic%' OR lower(title) LIKE 'github%' OR lower(title) LIKE 'anthropic%') LIMIT 1`);
    return r ? String(r.title) : null;
  }

  private unknownUsageLimit(guard: { unknown?: boolean }, limit: number): number {
    return guard.unknown === true && this.hands.name !== 'stub' ? 1 : limit;
  }

  // ---------- F-01 halt, dollar budgets ----------
  /** Why the hands may not start anything, or null. The var is the second line of defence, the DO key the first. */
  halted(): string | null {
    const v = String(this.env.HANDS_HALT ?? '0').toLowerCase();
    if (v === '1' || v === 'true') return 'HANDS_HALT is set on the Worker';
    const h = this.getMeta<{ reason: string; at: number }>('halt');
    return h ? `halted: ${h.reason}` : null;
  }

  /** Turn the halt on (idempotent): every start refuses, both containers are destroyed now. `alert` sends ONE p1 message per reason per day. */
  async setHalt(reason: string, now: number = Date.now(), alert = true): Promise<boolean> {
    const fresh = !this.getMeta('halt');
    if (fresh) this.setMeta('halt', { reason: reason.slice(0, 300), at: now });
    await this.stopContainers(true);
    if (alert && fresh) await this.emit({ dedupeKey: `halt:${dayKey(now)}:${reason.slice(0, 60)}`, kind: 'p1-unhealed', text: `Ebda OS: HANDS HALTED: ${reason.slice(0, 300)}\nNo container starts until you clear it (dashboard or POST /api/halt {"on":false}).` }, now);
    return fresh;
  }

  async clearHalt(now: number = Date.now()): Promise<void> {
    this.sql.exec(`DELETE FROM meta WHERE k = 'halt'`);
    for (const kind of ['nightly', 'urgent'] as const) await this.hands.resume?.(kind);
    this.setMeta('halt:cleared', { at: now });
  }

  private async stopContainers(halt: boolean): Promise<void> {
    for (const kind of ['nightly', 'urgent'] as const) await this.hands.stop?.(kind, { halt }).catch(() => undefined);
  }

  /** Budgets in USD. Monthly default 150 (headroom under the $200 API credit); daily default 10. */
  budgets() {
    return { monthly: numberVar(this.env.HANDS_MONTHLY_BUDGET_USD, 150), daily: numberVar(this.env.HANDS_DAILY_BUDGET_USD, 10) };
  }

  spent(now: number): { day: number; month: number } {
    return { day: this.getMeta<number>(`spend:d:${dayKey(now)}`) ?? 0, month: this.getMeta<number>(`spend:m:${monthKey(now)}`) ?? 0 };
  }

  /** Add one job's cost. 80 % of the month -> a digest warning; 100 % -> the halt and ONE p1 message. */
  async addSpend(u: JobUsage, now: number): Promise<void> {
    const cost = Number.isFinite(u.costUsd) && u.costUsd > 0 ? u.costUsd : 0;
    const cur = this.spent(now);
    this.setMeta(`spend:d:${dayKey(now)}`, cur.day + cost);
    this.setMeta(`spend:m:${monthKey(now)}`, cur.month + cost);
    const byModel = this.getMeta<Record<string, number>>(`spend:model:${monthKey(now)}`) ?? {};
    byModel[u.model] = (byModel[u.model] ?? 0) + cost;
    this.setMeta(`spend:model:${monthKey(now)}`, byModel);
    const { monthly } = this.budgets();
    const month = cur.month + cost;
    if (month >= monthly) {
      await this.ingestFinding({ source: 'brain', kind: 'budget-stop', key: `budget:${monthKey(now)}`, title: `monthly hands budget reached: $${month.toFixed(2)} of $${monthly}`, severity: 'P1' }, now);
    } else if (month >= 0.8 * monthly) {
      await this.ingestFinding({ source: 'brain', kind: 'budget-warn', key: `budget-80:${monthKey(now)}`, title: `hands spend is at ${Math.round((month / monthly) * 100)}% of the monthly budget ($${month.toFixed(2)} of $${monthly})`, severity: 'P3' }, now);
    }
  }

  /** The reason no new run may start on budget grounds (daily, or the month), or null. Auto-clears with the day / month. */
  budgetBlock(now: number): string | null {
    const b = this.budgets();
    const s = this.spent(now);
    if (s.month >= b.monthly) return `monthly budget $${b.monthly} reached ($${s.month.toFixed(2)})`;
    if (s.day >= b.daily) return `daily budget $${b.daily} reached ($${s.day.toFixed(2)})`;
    return null;
  }

  private usage(now: number, forMac = false) {
    // API-key containers have no weekly plan window: the dollar budget is their guard. The Mac runs on Ahmad's login and keeps the weekly guard.
    if (!forMac && authMode(this.env) === 'api') return { allowed: true, reason: 'api key: dollar budget guard' } as ReturnType<typeof usageGuard>;
    return usageGuard(this.getMeta<UsageReport>('usage'), this.policy.usageThresholdPct, now);
  }

  /**
   * Starts one run. A provider that throws (container binding missing, container busy, API error) never aborts the
   * caller: the run is recorded as 'failed' (it counts toward the urgent daily cap, so a broken provider is retried at
   * most URGENT_RUNS_PER_DAY times a day), the jobs stay queued, and null is returned.
   */
  private async startRun(kind: RunKind, jobs: HandsJob[], capMin: number, now: number, provider: HandsProvider = this.hands): Promise<HandsBatch | null> {
    // F-01 backstop: whatever path got here (urgent, nightly, Mac claim), a halted or over-budget brain starts nothing
    if (this.halted() || this.budgetBlock(now)) return null;
    const runId = uid('run');
    // model routing: one alias per job; opus only when flagged AND under the daily cap (otherwise sonnet). Recorded per run.
    let opusToday = this.getMeta<number>(`opus:${dayKey(now)}`) ?? 0;
    const opusCap = intVar(this.env.HANDS_OPUS_JOBS_PER_DAY, 2);
    const models: Record<string, number> = {};
    for (const j of jobs) {
      let m = modelFor(j.finding, this.env.HANDS_DEFAULT_MODEL);
      if (m === 'opus') {
        if (opusToday >= opusCap) m = 'sonnet';
        else opusToday++;
      }
      j.model = m;
      models[m] = (models[m] ?? 0) + 1;
    }
    this.setMeta(`opus:${dayKey(now)}`, opusToday);
    this.setMeta(`run:models:${runId}`, models);
    const s = this.spent(now);
    const b = this.budgets();
    const batch: HandsBatch = { runId, kind, jobs, perJobCapMin: capMin, usageThresholdPct: this.policy.usageThresholdPct, createdAt: now, budgetUsd: Math.max(0, Math.min(b.daily - s.day, b.monthly - s.month)) };
    // M-7: the run row and the jobs' claim are written BEFORE the outbound start call. The call yields the DO, and another tick
    // interleaving there must already see "a run is in flight" (urgent) and "these jobs are taken" (nightly), not start a second one.
    this.sql.exec(
      `INSERT INTO runs (id, kind, provider, external_id, status, day, started_at, cap_min) VALUES (?, ?, ?, NULL, 'running', ?, ?, ?)`,
      runId, kind, provider.name, dayKey(now), now, capMin,
    );
    // N-2: the stuck-run cap is 45 min x the jobs CLAIMED, fixed here; the count of jobs still running shrinks as they report
    this.setMeta(`run:jobs:${runId}`, jobs.length);
    for (const j of jobs) {
      this.sql.exec(`UPDATE jobs SET status = 'running', run_id = ?, started_at = ? WHERE id = ?`, runId, now, j.id);
      this.sql.exec(`UPDATE findings SET status = 'dispatched', acted_at = COALESCE(acted_at, ?) WHERE fp = ?`, now, j.fingerprint);
    }
    let ref: Awaited<ReturnType<HandsProvider['start']>>;
    try {
      ref = await provider.start(batch);
    } catch (e) {
      const error = String((e as Error)?.message ?? e).slice(0, 300);
      // the run counts toward the urgent daily cap as 'failed'; the jobs go back to the queue untouched
      this.sql.exec(`UPDATE runs SET status = 'failed', finished_at = ? WHERE id = ?`, now, runId);
      for (const j of jobs) {
        this.sql.exec(`UPDATE jobs SET status = 'queued', run_id = NULL, started_at = NULL WHERE id = ?`, j.id);
        this.sql.exec(`UPDATE findings SET status = 'queued' WHERE fp = ? AND status = 'dispatched'`, j.fingerprint);
      }
      this.setMeta('hands:start-failed', { at: now, runId, provider: provider.name, error });
      console.error('hands provider failed to start', provider.name, error);
      return null;
    }
    this.sql.exec(`UPDATE runs SET provider = ?, external_id = ? WHERE id = ?`, ref.provider, ref.externalId ?? null, runId);
    return batch;
  }

  /**
   * I-1: a run that outlives its cap (+10 min grace) is timed out, whatever its lane. Urgent: the job reports could-not-fix
   * (message + free slot). Nightly / Mac claim: the run died mid-batch (container cap, OOM, Mac asleep), so its unreported
   * jobs go back to the queue, and after NIGHTLY_MAX_TRIES tries they end as timed_out. The count lands in the digest.
   */
  async sweepStuckRuns(now: number): Promise<number> {
    let swept = 0;
    const nightlyCap = intVar(this.env.HANDS_NIGHTLY_RUN_CAP_MIN, 90);
    for (const run of this.rows(`SELECT * FROM runs WHERE status = 'running'`)) {
      const urgent = run.kind === 'urgent';
      const jobs = this.rows(`SELECT id FROM jobs WHERE run_id = ? AND status = 'running'`, run.id);
      // the nightly container's run cap, or 45 min per claimed job (the Mac), whichever is longer
      const claimed = this.getMeta<number>(`run:jobs:${run.id}`) ?? jobs.length;
      // a container is destroyed at its run cap, so its run cannot outlive min(45 x jobs, cap): jobs it never reached requeue the same night.
      // A Mac claim has no such cap (the Mac runs as long as its jobs need): 45 min per job CLAIMED, fixed at claim time (N-2).
      const capMin = urgent ? this.policy.urgentRunCapMin : String(run.provider).startsWith('mac') ? Math.max(nightlyCap, Number(run.cap_min) * claimed) : Math.min(Number(run.cap_min) * claimed, nightlyCap);
      if (Number(run.started_at) >= now - (capMin + 10) * 60000) continue;
      this.sql.exec(`UPDATE runs SET status = 'timed_out', finished_at = ? WHERE id = ? AND status = 'running'`, now, run.id);
      swept++;
      // F-04: a swept run's CONTAINER is stopped too, not just its row (a brain that thinks the run is over while it keeps billing)
      if (String(run.provider) === 'cloudflare-sandbox') await this.hands.stop?.(run.kind as RunKind, { halt: false }).catch(() => undefined);
      for (const j of jobs) {
        const id = String(j.id);
        // a swept job that began Claude but produced no meter reading is charged the pessimistic amount (the run died with its spend unseen)
        if (this.getMeta(`job:started:${id}`) && this.getMeta(`job:metered:${id}`) === null && !this.getMeta(`job:billed:${id}`)) {
          this.setMeta(`job:billed:${id}`, 1);
          await this.addSpend({ model: 'unmetered', inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: this.pessimisticJobUsd() }, now);
        }
        if (urgent) {
          await this.recordOutcome(id, { status: 'timed_out', note: `no outcome within ${run.cap_min} min` }, now);
          continue;
        }
        const tries = (this.getMeta<number>(`job:tries:${id}`) ?? 0) + 1;
        this.setMeta(`job:tries:${id}`, tries);
        if (tries >= NIGHTLY_MAX_TRIES) {
          await this.recordOutcome(id, { status: 'timed_out', note: `run ${run.id} died ${tries} times without an outcome` }, now);
        } else {
          const fp = String(this.row('SELECT fp FROM jobs WHERE id = ?', id)?.fp);
          this.sql.exec(`UPDATE jobs SET status = 'queued', run_id = NULL, started_at = NULL WHERE id = ?`, id);
          this.sql.exec(`UPDATE findings SET status = 'queued' WHERE fp = ? AND status = 'dispatched'`, fp);
          this.setMeta('sweep:requeued', { at: now, n: (this.getMeta<{ at: number; n: number }>('sweep:requeued')?.n ?? 0) + 1 });
        }
      }
    }
    return swept;
  }

  /** Urgent lane: one run at a time, URGENT_RUNS_PER_DAY a day, one job per run, URGENT_RUN_CAP_MIN cap. */
  private async dispatchUrgent(now: number): Promise<void> {
    await this.sweepStuckRuns(now);
    const queued = this.unleased(this.jobsFor(`j.status = 'queued' AND j.lane = 'urgent' ORDER BY j.created_at`), now);
    if (!queued.length) return;
    if (this.halted() || this.budgetBlock(now)) return; // F-01: halted -> nothing starts; the findings stay queued
    if (this.row(`SELECT 1 FROM runs WHERE kind = 'urgent' AND status = 'running'`)) return; // one at a time; the rest wait
    const today = Number(this.row(`SELECT COUNT(*) AS n FROM runs WHERE kind = 'urgent' AND day = ?`, dayKey(now))?.n ?? 0);
    const guard = this.usage(now);
    const pullOnly = this.hands.pullOnly === true;
    // Ruling I-4 / F-C1: with a real provider an urgent container never boots on an unknown usage (only the stub may)
    const unknownBlocked = guard.unknown === true && this.hands.name !== 'stub';
    if (today >= this.policy.urgentRunsPerDay || !guard.allowed || unknownBlocked || pullOnly) {
      const why = pullOnly ? `hands provider ${this.hands.name} is pull-only` : !guard.allowed || unknownBlocked ? guard.reason : `urgent cap ${this.policy.urgentRunsPerDay}/day reached`;
      for (const j of queued) {
        // queued for the nightly batch and messaged ONCE per issue
        this.sql.exec(`UPDATE jobs SET lane = 'nightly' WHERE id = ?`, j.id);
        await this.emit({ dedupeKey: `p1:${j.fingerprint}:${j.id}`, kind: 'p1-unhealed', text: `Ebda OS: urgent issue not handled yet: ${j.finding.title}\nNo urgent run now (${why}); queued for tonight's batch.` }, now);
      }
      return;
    }
    await this.startRun('urgent', [queued[0]!], this.policy.urgentRunCapMin, now);
  }

  /** Nightly lane: the one batched run at the end of the day (cron 30 21 * * * UTC = 23:30 Cairo in winter). */
  async runNightly(now: number = Date.now()): Promise<{ started: boolean; jobs: number; reason: string; runId?: string }> {
    // final review 4: with a real provider an unknown usage (no report yet) starts ONE job, the bootstrap that produces the first report
    // (urgent refuses outright; here a hard refusal would deadlock, since only a hands run reports usage)
    const stop = this.halted() ?? this.budgetBlock(now);
    if (stop) return { started: false, jobs: 0, reason: stop };
    // F-13: no nightly batch while GitHub or Anthropic has an open major/critical incident (jobs stay queued; the digest says so)
    const outage = this.vendorOutage();
    if (outage) {
      this.setMeta('nightly:skipped-outage', { at: now, reason: outage });
      return { started: false, jobs: 0, reason: `vendor outage: ${outage}` };
    }
    const limit = this.unknownUsageLimit(this.usage(now), NIGHTLY_MAX_JOBS);
    const jobs = this.unleased(this.jobsFor(`j.status = 'queued' AND j.lane = 'nightly' ORDER BY j.created_at LIMIT ${limit}`), now);
    if (!jobs.length) return { started: false, jobs: 0, reason: 'queue empty: no container started' };
    if (this.hands.pullOnly) return { started: false, jobs: jobs.length, reason: `hands provider ${this.hands.name} is pull-only: the Mac claims the queue` };
    const guard = this.usage(now);
    if (!guard.allowed) {
      this.setMeta('usage:refused', { at: now, reason: guard.reason, jobs: jobs.length });
      await this.noteNightly(true, guard.reason, now);
      return { started: false, jobs: jobs.length, reason: guard.reason };
    }
    const b = await this.startRun('nightly', jobs, 45, now);
    if (!b) return { started: false, jobs: jobs.length, reason: `hands provider ${this.hands.name} failed to start; jobs stay queued` };
    return { started: true, jobs: jobs.length, reason: guard.reason, runId: b.runId };
  }

  /**
   * Ruling 4b-6: a nightly batch in which EVERY job was skipped by the usage guard (refused at start, or all jobs
   * came back skipped_usage) is "starved". After `usageStarvedAlertAfter` of them in a row (and every multiple of
   * that after), one urgent-class alert; any batch that made progress resets the streak.
   */
  private async noteNightly(starved: boolean, why: string, now: number): Promise<void> {
    const prev = this.getMeta<{ streak: number }>('nightly:starved')?.streak ?? 0;
    const streak = starved ? prev + 1 : 0;
    this.setMeta('nightly:starved', { streak, at: now });
    const n = this.policy.usageStarvedAlertAfter;
    const ident = { source: 'brain', kind: 'usage-starved', key: 'nightly:usage-starved' };
    if (starved && n > 0 && streak % n === 0) {
      // a digest item, not a message: it is not an outage, and it must not spend the urgent 3/day budget (final review)
      await this.ingestFinding({ ...ident, title: `the last ${streak} nightly batches did no work, every job was skipped by the usage guard. ${why}. Queued findings are waiting; check Claude usage.`, severity: 'P3', detail: { streak } }, now);
    } else if (!starved) {
      await this.resolveFinding(ident, 'a nightly batch made progress', now);
    }
  }

  /** Mac fallback: the mac-local hands claim queued nightly work themselves when awake. */
  async claim(providerName: string, max: number, now: number = Date.now()): Promise<HandsBatch | { refused: string }> {
    const stop = this.halted();
    if (stop) return { refused: stop };
    // F-07: the Mac has a daily job cap too (it spends Ahmad's own plan quota); counted from the jobs claimed today
    const macCap = intVar(this.env.HANDS_MAC_JOBS_PER_DAY, 5);
    const claimedToday = this.rows(`SELECT id FROM runs WHERE provider LIKE 'mac%' AND day = ?`, dayKey(now)).reduce((a, r) => a + (this.getMeta<number>(`run:jobs:${r.id}`) ?? 1), 0);
    if (claimedToday >= macCap) return { refused: `mac claim cap ${macCap}/day reached` };
    max = Math.min(max, macCap - claimedToday);
    const guard = this.usage(now, true);
    if (!guard.allowed) return { refused: guard.reason };
    const n = this.unknownUsageLimit(guard, Math.max(1, Math.min(max, NIGHTLY_MAX_JOBS)));
    // Ruling 4b-5 (I-10): the Mac runs as Ahmad with his files in reach, so it never claims work whose text comes from third parties
    // (advisories, PR titles, world-watch pages); those wait for the container
    const mac = providerName === 'mac-local' ? ` AND f.source != 'advisory' AND f.kind != 'pr-stuck' AND f.key NOT LIKE 'world-watch:%'` : '';
    const jobs = this.unleased(this.jobsFor(`j.status = 'queued' AND j.lane = 'nightly'${mac} ORDER BY j.created_at LIMIT ${n}`), now);
    if (!jobs.length) return { refused: 'queue empty' };
    const recorder: HandsProvider = { name: providerName, start: async (b) => ({ runId: b.runId, provider: providerName, startedAt: now }) };
    return (await this.startRun('nightly', jobs, 45, now, recorder)) ?? { refused: 'could not record the run' };
  }

  /** Which run (and provider) a job belongs to: the hands routes use it to scope a per-run token to its own jobs (F-06b). */
  runOfJob(jobId: string): { runId: string; provider: string } | null {
    const r = this.row(`SELECT r.id, r.provider FROM jobs j JOIN runs r ON r.id = j.run_id WHERE j.id = ?`, jobId);
    return r ? { runId: String(r.id), provider: String(r.provider) } : null;
  }

  runInfo(runId: string): { provider: string } | null {
    const r = this.row('SELECT provider FROM runs WHERE id = ?', runId);
    return r ? { provider: String(r.provider) } : null;
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
    // I1 (money re-review): spend is recorded FIRST, even for a late outcome of a job that is no longer running (swept, timed out); only then is
    // the state change refused. The meter (every API response, posted as it happens) is the source of truth; the outcome's own usage block is
    // used only when the forwarder metered nothing (fallback), and a job that ran Claude with no reading at all is charged the pessimistic amount.
    await this.billOutcome(jobId, o, now);
    if (j.status !== 'running') return { ok: false, reason: `job is ${j.status}, not running` };
    if (o.status === 'skipped_usage') {
      // the hands stopped at the usage threshold before this job: back to the queue, not a failure
      if (j.lane === 'urgent') {
        // Ruling F-C1: a refused P1 is never demoted silently. ONE message (same key as dispatchUrgent's), job kept for the next run.
        await this.emit({ dedupeKey: `p1:${j.fp}:${jobId}`, kind: 'p1-unhealed', text: `Ebda OS: could not self-heal: ${j.title}\nThe hands refused the urgent run (${o.note ?? 'usage guard'}); queued for tonight's batch.` }, now);
      }
      this.sql.exec(`UPDATE jobs SET status = 'queued', run_id = NULL, started_at = NULL, lane = 'nightly' WHERE id = ?`, jobId);
      this.sql.exec(`UPDATE findings SET status = 'queued' WHERE fp = ?`, j.fp);
    } else {
      if (j.lane === 'nightly' && j.run_id) this.setMeta(`run:progress:${j.run_id}`, 1);
      const ok = o.status === 'merged' || o.status === 'pr_opened' || o.status === 'fix_deployed';
      this.sql.exec(`UPDATE jobs SET status = ?, finished_at = ?, outcome = ? WHERE id = ?`, ok ? 'done' : 'failed', now, JSON.stringify(o), jobId);
      // a PR that is open keeps the finding in flight ('waiting') until the condition is gone; merged / deployed = done
      const fstatus = o.status === 'pr_opened' ? 'waiting' : ok ? 'done' : 'failed';
      this.sql.exec(`UPDATE findings SET status = ?, closed_at = ?, outcome = ? WHERE fp = ? AND status = 'dispatched'`, fstatus, fstatus === 'waiting' ? null : now, JSON.stringify(o), j.fp);
      if (j.lane === 'urgent') {
        const what = { merged: 'fixed and merged', pr_opened: 'PR opened, needs your review', fix_deployed: 'fix deployed', could_not_fix: 'could NOT fix', timed_out: 'could NOT fix in time', skipped_usage: '' }[o.status];
        await this.emit({ dedupeKey: `outcome:${jobId}`, kind: 'urgent-outcome', text: `Ebda OS urgent: ${what}\n${j.title}${o.prUrl ? `\n${o.prUrl}` : ''}${o.note ? `\n${o.note}` : ''}` }, now);
      } else if (o.status === 'pr_opened' && o.note?.startsWith('question:')) {
        // the hands left a PR they may not merge (not a pre-approved class, or the gate was not green): ONE question
        await this.emit({ dedupeKey: `pr-review:${jobId}`, kind: 'question', text: `Ebda OS: PR needs your review\n${j.title}${o.prUrl ? `\n${o.prUrl}` : ''}\n${o.note.slice('question:'.length).trim()}` }, now);
      }
    }
    if (j.run_id && !this.row(`SELECT 1 FROM jobs WHERE run_id = ? AND status = 'running'`, j.run_id)) {
      this.sql.exec(`UPDATE runs SET status = 'done', finished_at = ? WHERE id = ? AND status = 'running'`, now, j.run_id);
      if (this.row(`SELECT 1 FROM runs WHERE id = ? AND kind = 'nightly'`, j.run_id)) {
        const progressed = this.getMeta<number>(`run:progress:${j.run_id}`) === 1;
        await this.noteNightly(!progressed, 'every job in the batch was skipped by the usage guard', now);
      }
    }
    return { ok: true };
  }

  /** Pessimistic per-job charge for a Claude run nothing metered (config HANDS_JOB_PESSIMISTIC_USD, default 2): never $0. */
  pessimisticJobUsd(): number {
    return numberVar(this.env.HANDS_JOB_PESSIMISTIC_USD, 2);
  }

  /** The forwarder's meter: one API response's real usage (or a job-start beacon), posted as it happens. Idempotent per call id. */
  async recordMeter(runId: string, m: { jobId: string; started?: boolean; callId?: string; model?: string; inputTokens?: number; outputTokens?: number; cacheReadTokens?: number; cacheWriteTokens?: number; costUsd?: number }, now: number = Date.now()): Promise<{ ok: boolean }> {
    const owner = this.runOfJob(m.jobId);
    if (!owner || owner.runId !== runId) return { ok: false };
    if (m.started) {
      // a new attempt (a requeued job starts again): its meter and billing flags start clean, the earlier attempt was charged when it ended
      this.sql.exec(`DELETE FROM meta WHERE k IN ('job:metered:${m.jobId}', 'job:billed:${m.jobId}')`);
      this.setMeta(`job:started:${m.jobId}`, 1);
      return { ok: true };
    }
    const usage: JobUsage = { model: String(m.model ?? 'unknown'), inputTokens: Number(m.inputTokens ?? 0), outputTokens: Number(m.outputTokens ?? 0), cacheReadTokens: Number(m.cacheReadTokens ?? 0), cacheWriteTokens: Number(m.cacheWriteTokens ?? 0), costUsd: Number(m.costUsd ?? 0) };
    this.setMeta(`job:started:${m.jobId}`, 1);
    this.setMeta(`job:metered:${m.jobId}`, (this.getMeta<number>(`job:metered:${m.jobId}`) ?? 0) + usage.costUsd);
    await this.addSpend(usage, now);
    return { ok: true };
  }

  /** Charge a job's outcome exactly once (see recordOutcome). */
  private async billOutcome(jobId: string, o: JobOutcome, now: number): Promise<void> {
    if (this.getMeta(`job:billed:${jobId}`)) return;
    const metered = this.getMeta<number>(`job:metered:${jobId}`);
    if (metered !== null) {
      this.setMeta(`job:billed:${jobId}`, 1); // the meter already charged every call
      return;
    }
    if (o.usage) {
      this.setMeta(`job:billed:${jobId}`, 1);
      await this.addSpend(o.usage, now);
    } else if (o.claudeRan === true || this.getMeta(`job:started:${jobId}`)) {
      this.setMeta(`job:billed:${jobId}`, 1);
      await this.addSpend({ model: 'unmetered', inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: this.pessimisticJobUsd() }, now);
    }
  }

  reportUsage(u: Omit<UsageReport, 'reportedAt'>, now: number = Date.now()): void {
    // F-06b: inside one weekly window a report LOWER than the last one is ignored (usage only grows until the window resets), so a forged
    // 0 % cannot re-open dispatch. A moved `resetsAt` (or an expired window) starts a new window.
    const last = this.getMeta<UsageReport>('usage');
    if (last && u.weeklyUsedPct < last.weeklyUsedPct && last.resetsAt !== undefined && now < last.resetsAt && (u.resetsAt === undefined || u.resetsAt === last.resetsAt)) return;
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

  /**
   * M-6: a fix PR that stays open (finding 'waiting') for over 14 days moves to the digest instead of silencing the issue
   * forever; a PR closed unmerged is otherwise never noticed (no watcher reconciles dream findings).
   */
  private ageWaiting(now: number): void {
    for (const r of this.rows(`SELECT f.fp FROM findings f WHERE f.status = 'waiting' AND COALESCE((SELECT MAX(j.finished_at) FROM jobs j WHERE j.fp = f.fp), f.raised_at) < ?`, now - WAITING_MAX_MS)) {
      this.sql.exec(`UPDATE findings SET status = 'digest', lane = 'digest', reason = 'fix PR open for over 14 days: check it', closed_at = NULL WHERE fp = ?`, r.fp);
    }
  }

  /** The 5-minute tick: expire/send questions, dispatch urgent work, self-check. */
  async tick(now: number = Date.now()): Promise<{ osBugs: number }> {
    await this.retryFailed(now);
    await this.flushQuestions(now);
    await this.dispatchUrgent(now);
    this.ageWaiting(now);
    return { osBugs: this.selfCheck(now).length };
  }

  /** Build (never send) the daily digest: shared by the 05:00 send and the dashboard's preview. The preview writes nothing
   *  (the self-check's last result is read instead of re-run), so polling the dashboard costs no DO row writes. */
  private buildDigest(now: number, preview = false) {
    const since = now - DAY;
    const outcomes: Array<{ title: string; status: string; prUrl: string | null }> = this.rows(`SELECT f.title, j.outcome FROM jobs j JOIN findings f ON f.fp = j.fp WHERE j.finished_at > ? AND j.outcome IS NOT NULL ORDER BY j.finished_at`, since).map((r) => {
      const o = JSON.parse(String(r.outcome)) as JobOutcome;
      return { title: String(r.title), status: o.status, prUrl: o.prUrl ?? null };
    });
    for (const r of this.rows(`SELECT title, outcome FROM findings WHERE status = 'resolved' AND closed_at > ?`, since)) outcomes.push({ title: String(r.title), status: String(r.outcome ?? 'resolved'), prUrl: null });
    // digest-lane findings (monitor self-reports) are listed ONCE: the fingerprints already shown are remembered
    const shown = new Set(this.getMeta<string[]>('digest:shown') ?? []);
    // R-4a-3 closed: the shown fingerprints are excluded in SQL, so old shown rows can never crowd out a new one
    const shownList = [...shown];
    const watchRows = this.rows(`SELECT fp, title FROM findings WHERE lane = 'digest' AND status = 'digest' AND fp NOT IN (SELECT value FROM json_each(?)) ORDER BY first_seen LIMIT 500`, JSON.stringify(shownList));
    // only the notes the digest actually renders are marked shown; the rest wait for the next digest
    const rendered = watchRows.slice(0, MONITOR_NOTES_PER_DIGEST);
    const a24 = this.actedOn(now, DAY);
    const a7 = this.actedOn(now, 7 * DAY);
    const pending = this.rows(`SELECT id, text, default_opt FROM questions WHERE status = 'pending' ORDER BY created_at LIMIT 10`);
    const rolled = this.rows(`SELECT dedupe_key, text, status FROM messages WHERE status IN ('deferred', 'undelivered') ORDER BY at`);
    const refused = this.getMeta<{ at: number; reason: string }>('usage:refused');
    const msg = digestMessage({
      day: dayKey(now),
      outcomes,
      raised24h: a24.raised,
      acted24h: a24.acted,
      ratio7d: a7.ratio,
      pendingQuestions: pending.map((q) => ({ id: String(q.id), text: String(q.text), defaultOption: String(q.default_opt) })),
      rolledUp: rolled.map((r) => ({ text: String(r.text), failed: r.status === 'undelivered' })),
      monitorNotes: rendered.map((r) => String(r.title)),
      monitorMore: watchRows.length - rendered.length,
      osBugs: preview ? (this.getMeta<{ fps: string[] }>('os:bugs')?.fps.length ?? 0) : this.selfCheck(now).length,
      usageNote: refused && now - refused.at < DAY ? refused.reason : null,
      halted: this.halted(),
      budget: (() => { const sp = this.spent(now); const b = this.budgets(); return `Hands spend: $${sp.month.toFixed(2)} of $${b.monthly} this month ($${sp.day.toFixed(2)} today of $${b.daily}).`; })(),
      footprint: (() => { const f = this.getMeta<Footprint>('footprint:last'); if (!f) return null; if (f.unknown) return `Footprint (24 h): unknown (${f.note ?? 'read failed'}).`; return `Footprint (24 h): containers ${Math.round(f.containerMin ?? 0)} min, DO requests ${f.doRequests ?? 0}, DO rows written ${f.doRowsWritten ?? 0}, KV writes ${f.kvWrites ?? 0}${f.estUsd === undefined ? '' : `; est $${f.estUsd.toFixed(2)}/month`}.`; })(),
      requeued: (() => { const q = this.getMeta<{ at: number; n: number }>('sweep:requeued'); return q && now - q.at < DAY ? q.n : 0; })(),
    });
    return { msg, shown, rendered, rolled, pending };
  }

  /** The one daily digest: outcomes (not noticings), acted-on ratio, decisions waiting, rolled-up messages. */
  async digest(now: number = Date.now()): Promise<string> {
    const { msg, shown, rendered, rolled, pending } = this.buildDigest(now);
    const r = await this.emit(msg, now);
    if (r === 'sent') {
      if (rendered.length) this.setMeta('digest:shown', [...shown, ...rendered.map((x) => String(x.fp))].slice(-1000));
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
      leases: this.rows(`SELECT repo, holder, note, expires_at FROM leases WHERE expires_at > ? ORDER BY repo`, now),
      sources: { prodWatchSeenAt: this.getMeta<number>('source:seen:prod-watch') },
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
        budget: this.policy.messageBudgetPerDay + this.policy.urgentMessageBudgetPerDay,
        deferred: count(`SELECT COUNT(*) AS n FROM messages WHERE status IN ('deferred', 'undelivered')`),
        failed: count(`SELECT COUNT(*) AS n FROM messages WHERE day = ? AND status = 'failed'`, day),
      },
      actedOn: { d1: this.actedOn(now, DAY), d7: this.actedOn(now, 7 * DAY) },
      osBugs: bugs?.fps.length ?? 0,
      usage: { report: this.getMeta<UsageReport>('usage'), guard: this.usage(now), thresholdPct: this.policy.usageThresholdPct },
      health: this.getMeta<BrainState['health']>('health:last'),
      advisories: this.getMeta<AdvisoryRunSummary>('advisories:last'),
      unconfigured: this.rows(`SELECT key FROM findings WHERE kind = 'monitor-unconfigured' AND status NOT IN ('resolved')`).map((r) => String(r.key).split(':')[0]!).sort(),
      halt: this.halted(),
      spend: { ...this.spent(now), dailyBudget: this.budgets().daily, monthlyBudget: this.budgets().monthly, byModel: this.getMeta<Record<string, number>>(`spend:model:${monthKey(now)}`) ?? {} },
      footprint: this.getMeta<Footprint>('footprint:last'),
      cfLimits: (() => { const stop = numberVar(this.env.CF_STOP_USD, 20); return { warnUsd: Math.min(numberVar(this.env.CF_WARN_USD, 10), stop), stopUsd: stop }; })(),
      gaps: this.rows(`SELECT key, title FROM findings WHERE kind = 'monitor-unconfigured' AND status NOT IN ('resolved') ORDER BY key`).map((r) => ({ id: String(r.key).split(':')[0]!, missing: String(r.title).replace(/^watcher \S+ is not running: /, '').replace(/ is not set$/, '') })),
      digestPreview: this.buildDigest(now, true).msg.text,
    };
  }

  /** F-14: INGEST_TOKEN has a per-day ceiling (default 1000 findings); false = refuse the request. */
  admitIngest(n: number, now: number = Date.now()): boolean {
    const key = `ingest:${dayKey(now)}`;
    const used = this.getMeta<number>(key) ?? 0;
    if (used + n > intVar(this.env.INGEST_PER_DAY, 1000)) return false;
    this.setMeta(key, used + n);
    return true;
  }

  /**
   * RR-dash-auth: the dashboard Basic Auth rate limiter. Called only for requests that carry credentials. Returns true when the
   * caller may in: the credentials were right AND neither this IP (DASH_AUTH_FAILS_PER_IP, 10) nor everyone (DASH_AUTH_FAILS_GLOBAL,
   * 200) is over its failure budget in the last 15 minutes. A locked caller is refused even with the right password (no oracle).
   * Failures past the global cap are not stored (bounded writes).
   */
  dashAuthAttempt(ip: string, ok: boolean, now: number = Date.now()): boolean {
    const since = now - 15 * 60_000;
    this.sql.exec('DELETE FROM auth_fail WHERE at < ?', since);
    const ipKey = ip.slice(0, 64);
    const perIp = Number(this.row('SELECT COUNT(*) AS n FROM auth_fail WHERE ip = ?', ipKey)?.n ?? 0);
    const all = Number(this.row('SELECT COUNT(*) AS n FROM auth_fail')?.n ?? 0);
    const locked = perIp >= intVar(this.env.DASH_AUTH_FAILS_PER_IP, 10) || all >= intVar(this.env.DASH_AUTH_FAILS_GLOBAL, 200);
    if (!ok && !locked) this.sql.exec('INSERT INTO auth_fail (ip, at) VALUES (?, ?)', ipKey, now);
    return ok && !locked;
  }

  /** F-05: the footprint watcher stores its last reading (an unreadable one is `unknown`, never zero). */
  recordFootprint(f: Footprint | Record<string, unknown>): void {
    this.setMeta('footprint:last', f);
  }

  getMetaPublic(k: string): unknown {
    return this.getMeta(k);
  }

  setMetaPublic(k: string, v: unknown): void {
    this.setMeta(k, v);
  }
}
