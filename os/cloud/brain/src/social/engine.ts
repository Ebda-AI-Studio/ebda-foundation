// The social calendar, approval gate and publisher. Runs inside BrainDO (one SQLite-backed Durable Object = single-threaded, so a
// claim is never raced), driven by the existing 5-minute `tick` cron and the 05:00 `digest` cron: no new cron, no always-on compute.
//
// Safety properties (each has a test in test/social.test.ts):
//  - APPROVAL GATE: while a brand is in its approval window, a post publishes only if Ahmad approved THAT revision. Checked twice:
//    when the post is selected and again right before the network call.
//  - AT MOST ONCE: the row is claimed (status 'publishing', durable) before the network call. A lost answer becomes 'uncertain' and is
//    never blindly retried; Facebook is reconciled by reading the Page feed for the exact text, LinkedIn waits for Ahmad.
//  - Instagram content is never re-posted (drafts must be origin 'os'); Facebook posts keep SOCIAL_FB_SPACING_MIN away from any post the
//    OS did not make (Ahmad's Instagram shares), deferring at most SOCIAL_FB_MAX_DEFER_HOURS.
import type { Env } from '../env';
import { FacebookAdapter } from './adapters/facebook';
import { LinkedInAdapter } from './adapters/linkedin';
import type { NetworkAdapter } from './adapters/types';
import { validateDraft } from './rules';
import { cairoTime, decisionLink, sendPreview, sendText } from './telegram';
import { BRAND_LABEL, BRANDS, NETWORKS, type Brand, type Decision, type DraftInput, type Network, type PostRow } from './types';

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
/** after the slot, an approved post may still go out for this long (late approval, short outage); then it expires */
export const PUBLISH_GRACE_MS = 12 * HOUR;
export const RETRY_BACKOFF_MS = [10 * MIN, 30 * MIN, 2 * HOUR];
export const STUCK_CLAIM_MS = 10 * MIN;
/** Facebook needs a moment before a new post shows in the feed: reconcile an uncertain post only after this */
export const RECONCILE_AFTER_MS = 5 * MIN;
export const MAX_PUBLISH_PER_TICK = 5;
export const MAX_PER_DAY_PER_CHANNEL = 2;

type Row = Record<string, SqlStorageValue>;

export interface BrandMode {
  brand: Brand;
  mode: 'approval' | 'auto';
  paused: boolean;
  keepApproval: boolean;
  firstApprovedAt: number | null;
  /** when auto-posting starts (null = window not started: no approved post yet, or forced) */
  autoFrom: number | null;
}

export function num(v: string | undefined, d: number): number {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : d;
}

export function adaptersFrom(env: Env): Record<Network, NetworkAdapter> {
  return {
    facebook: new FacebookAdapter(env.SOCIAL_FACEBOOK, env.SOCIAL_GRAPH_VERSION || 'v27.0'),
    linkedin: new LinkedInAdapter(env.SOCIAL_LINKEDIN, env.SOCIAL_LINKEDIN_VERSION || '202610'),
  };
}

export class SocialEngine {
  adapters: Record<Network, NetworkAdapter>;
  constructor(
    private sql: SqlStorage,
    private env: Env,
    private fetchImpl: () => typeof fetch,
    private sync: () => Promise<void>,
  ) {
    this.adapters = adaptersFrom(env);
  }

  static migrate(sql: SqlStorage): void {
    sql.exec(`
      CREATE TABLE IF NOT EXISTS social_posts (
        id TEXT PRIMARY KEY, brand TEXT NOT NULL, network TEXT NOT NULL, rev INTEGER NOT NULL, status TEXT NOT NULL,
        scheduled_at INTEGER NOT NULL, orig_scheduled_at INTEGER NOT NULL, text TEXT NOT NULL, alt_text TEXT,
        image_key TEXT NOT NULL, image_type TEXT NOT NULL, approved_by TEXT, approved_at INTEGER, decided_via TEXT, edit_note TEXT,
        attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER, claim_at INTEGER, remote_id TEXT, last_error TEXT,
        published_at INTEGER, asked_at INTEGER, alerted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS social_posts_due ON social_posts (status, scheduled_at);
      CREATE TABLE IF NOT EXISTS social_brands (brand TEXT PRIMARY KEY, paused INTEGER NOT NULL DEFAULT 0, keep_approval INTEGER NOT NULL DEFAULT 0, first_approved_at INTEGER);
      CREATE TABLE IF NOT EXISTS social_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
    `);
  }

  private rows(q: string, ...b: unknown[]): Row[] {
    return this.sql.exec(q, ...b).toArray() as Row[];
  }
  private post(id: string): PostRow | null {
    return (this.rows('SELECT * FROM social_posts WHERE id = ?', id)[0] as unknown as PostRow) ?? null;
  }
  private meta<T>(k: string): T | null {
    const r = this.rows('SELECT v FROM social_meta WHERE k = ?', k)[0];
    return r ? (JSON.parse(String(r.v)) as T) : null;
  }
  private setMeta(k: string, v: unknown): void {
    this.sql.exec('INSERT INTO social_meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', k, JSON.stringify(v));
  }
  private kv(): KVNamespace {
    return this.env.EVENTS;
  }

  approvalDays(): number {
    return num(this.env.SOCIAL_APPROVAL_DAYS, 14);
  }

  brandMode(brand: Brand, now: number): BrandMode {
    const r = this.rows('SELECT paused, keep_approval, first_approved_at FROM social_brands WHERE brand = ?', brand)[0];
    const paused = Number(r?.paused ?? 0) === 1;
    const keepApproval = Number(r?.keep_approval ?? 0) === 1;
    const first = r?.first_approved_at == null ? null : Number(r.first_approved_at);
    const autoFrom = keepApproval || first === null ? null : first + this.approvalDays() * DAY;
    return { brand, mode: autoFrom !== null && now >= autoFrom ? 'auto' : 'approval', paused, keepApproval, firstApprovedAt: first, autoFrom };
  }

  setBrand(brand: Brand, patch: { paused?: boolean; keepApproval?: boolean }): BrandMode {
    this.sql.exec('INSERT INTO social_brands (brand) VALUES (?) ON CONFLICT(brand) DO NOTHING', brand);
    if (patch.paused !== undefined) this.sql.exec('UPDATE social_brands SET paused = ? WHERE brand = ?', patch.paused ? 1 : 0, brand);
    if (patch.keepApproval !== undefined) this.sql.exec('UPDATE social_brands SET keep_approval = ? WHERE brand = ?', patch.keepApproval ? 1 : 0, brand);
    return this.brandMode(brand, Date.now());
  }

  /** A draft (or a new revision of one) from the Mac content job. */
  async ingest(raw: unknown, now: number): Promise<{ ok: true; id: string; rev: number; status: string } | { ok: false; id?: string; error: string; code: number }> {
    const err = validateDraft(raw, now);
    const id = (raw as { id?: unknown })?.id;
    if (err) return { ok: false, ...(typeof id === 'string' ? { id } : {}), error: err, code: 400 };
    const d = raw as DraftInput;
    const cur = this.post(d.id);
    if (cur && !['draft', 'asked', 'edit_requested'].includes(cur.status)) return { ok: false, id: d.id, error: `post is already ${cur.status}`, code: 409 };
    const rev = cur ? cur.rev + 1 : 1;
    const imageKey = `social:img:${d.id}:${rev}`;
    const bytes = Uint8Array.from(atob(d.imageBase64), (c) => c.charCodeAt(0));
    // resource-frugal: images expire from KV 90 days after upload (the post is long published or dead by then)
    await this.kv().put(imageKey, bytes, { expirationTtl: 90 * 86_400 });
    const auto = this.brandMode(d.brand, now).mode === 'auto';
    const status = auto ? 'approved' : 'draft';
    if (cur) {
      this.sql.exec(
        `UPDATE social_posts SET rev = ?, status = ?, scheduled_at = ?, orig_scheduled_at = ?, text = ?, alt_text = ?, image_key = ?, image_type = ?,
         approved_by = ?, approved_at = ?, decided_via = NULL, edit_note = NULL, asked_at = NULL, last_error = NULL, updated_at = ? WHERE id = ?`,
        rev, status, d.scheduledAt, d.scheduledAt, d.text, d.altText ?? null, imageKey, d.imageType, auto ? 'auto' : null, auto ? now : null, now, d.id,
      );
      if (cur.image_key !== imageKey) await this.kv().delete(cur.image_key).catch(() => undefined);
    } else {
      this.sql.exec(
        `INSERT INTO social_posts (id, brand, network, rev, status, scheduled_at, orig_scheduled_at, text, alt_text, image_key, image_type, approved_by, approved_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        d.id, d.brand, d.network, rev, status, d.scheduledAt, d.scheduledAt, d.text, d.altText ?? null, imageKey, d.imageType, auto ? 'auto' : null, auto ? now : null, now, now,
      );
    }
    return { ok: true, id: d.id, rev, status };
  }

  /** Ahmad's answer (signed link, Telegram button, or the controller forwarding his Telegram text). */
  decide(id: string, decision: Decision, via: string, now: number, opts: { rev?: number; note?: string } = {}): { ok: boolean; reason?: string; status?: string } {
    const p = this.post(id);
    if (!p) return { ok: false, reason: 'no such post' };
    if (opts.rev !== undefined && opts.rev !== p.rev) return { ok: false, reason: `this is revision ${opts.rev}; the current one is ${p.rev}` };
    if (decision === 'skip') {
      if (!['draft', 'asked', 'approved', 'edit_requested'].includes(p.status)) return { ok: false, reason: `post is ${p.status}` };
      this.sql.exec(`UPDATE social_posts SET status = 'skipped', decided_via = ?, updated_at = ? WHERE id = ?`, via, now, id);
      return { ok: true, status: 'skipped' };
    }
    if (!['draft', 'asked'].includes(p.status)) return { ok: false, reason: `post is ${p.status}` };
    if (decision === 'edit') {
      const note = (opts.note ?? '').trim().slice(0, 1000) || 'Ahmad asked for an edit without a note: rewrite with a different angle.';
      this.sql.exec(`UPDATE social_posts SET status = 'edit_requested', edit_note = ?, decided_via = ?, updated_at = ? WHERE id = ?`, note, via, now, id);
      return { ok: true, status: 'edit_requested' };
    }
    if (now > p.scheduled_at + PUBLISH_GRACE_MS) return { ok: false, reason: 'the slot has passed; the post expired' };
    this.sql.exec(`UPDATE social_posts SET status = 'approved', approved_by = 'ahmad', approved_at = ?, decided_via = ?, updated_at = ? WHERE id = ?`, now, via, now, id);
    // the 2-week clock starts at the first post Ahmad approves (per brand)
    this.sql.exec('INSERT INTO social_brands (brand, first_approved_at) VALUES (?, ?) ON CONFLICT(brand) DO UPDATE SET first_approved_at = COALESCE(first_approved_at, excluded.first_approved_at)', p.brand, now);
    return { ok: true, status: 'approved' };
  }

  /** The gate, as one predicate: may this row be published now? */
  mayPublish(p: PostRow, now: number): boolean {
    if (p.status !== 'approved') return false;
    const m = this.brandMode(p.brand, now);
    if (m.paused) return false;
    return p.approved_by === 'ahmad' || (p.approved_by === 'auto' && m.mode === 'auto');
  }

  async tick(now: number): Promise<{ asked: number; published: number; expired: number }> {
    await this.reconcile(now);
    const out = { asked: 0, published: 0, expired: 0 };
    // expired: never approved in time, or approved but the network stayed unavailable past the grace
    out.expired = this.sql.exec(`UPDATE social_posts SET status = 'expired', updated_at = ? WHERE status IN ('draft', 'asked', 'edit_requested', 'approved') AND scheduled_at + ? < ?`, now, PUBLISH_GRACE_MS, now).rowsWritten;
    for (const brand of BRANDS) {
      const m = this.brandMode(brand, now);
      if (m.mode === 'approval') {
        // a brand back in approval (forced): auto-approved posts must be asked again
        this.sql.exec(`UPDATE social_posts SET status = 'draft', approved_by = NULL, approved_at = NULL, updated_at = ? WHERE brand = ? AND status = 'approved' AND approved_by = 'auto'`, now, brand);
      } else {
        this.sql.exec(`UPDATE social_posts SET status = 'approved', approved_by = 'auto', approved_at = ?, updated_at = ? WHERE brand = ? AND status IN ('draft', 'asked')`, now, now, brand);
      }
    }
    out.asked = await this.askDue(now);
    out.published = await this.publishDue(now);
    return out;
  }

  private async askDue(now: number): Promise<number> {
    const lead = num(this.env.SOCIAL_APPROVAL_LEAD_HOURS, 24) * HOUR;
    const due = this.rows(`SELECT * FROM social_posts WHERE status = 'draft' AND scheduled_at - ? <= ? ORDER BY scheduled_at LIMIT 10`, lead, now) as unknown as PostRow[];
    let n = 0;
    for (const p of due) {
      if (this.brandMode(p.brand, now).paused) continue;
      const exp = Math.floor((p.scheduled_at + PUBLISH_GRACE_MS) / 1000);
      const secret = this.env.SOCIAL_LINK_SECRET;
      const base = this.env.HANDS_BRAIN_URL;
      const buttons =
        secret && base && /^https:\/\//.test(base)
          ? [
              { text: 'Approve', url: await decisionLink(base, secret, p, exp) + '&d=approve' },
              { text: 'Ask for an edit', url: await decisionLink(base, secret, p, exp) + '&d=edit' },
              { text: 'Skip', url: await decisionLink(base, secret, p, exp) + '&d=skip' },
            ]
          : [
              { text: 'Approve', callback_data: `s:${p.id}:a` },
              { text: 'Edit', callback_data: `s:${p.id}:e` },
              { text: 'Skip', callback_data: `s:${p.id}:k` },
            ];
      const image = await this.kv().get(p.image_key, 'arrayBuffer');
      const r = await sendPreview({ token: this.env.TELEGRAM_BOT_TOKEN, chatId: this.env.TELEGRAM_CHAT_ID, post: p, image, buttons, fetchImpl: this.fetchImpl() });
      if (r.ok) {
        this.sql.exec(`UPDATE social_posts SET status = 'asked', asked_at = ?, last_error = NULL, updated_at = ? WHERE id = ? AND rev = ?`, now, now, p.id, p.rev);
        n++;
      } else {
        this.sql.exec(`UPDATE social_posts SET last_error = ?, updated_at = ? WHERE id = ?`, r.reason ?? 'preview not sent', now, p.id);
      }
    }
    return n;
  }

  private publishedToday(p: PostRow, now: number): number {
    return Number(this.rows(`SELECT COUNT(*) AS n FROM social_posts WHERE brand = ? AND network = ? AND status IN ('published', 'publishing', 'uncertain') AND COALESCE(published_at, claim_at) > ?`, p.brand, p.network, now - DAY)[0]?.n ?? 0);
  }

  private async publishDue(now: number): Promise<number> {
    const due = this.rows(`SELECT * FROM social_posts WHERE status = 'approved' AND scheduled_at <= ? AND (next_at IS NULL OR next_at <= ?) ORDER BY scheduled_at LIMIT ?`, now, now, MAX_PUBLISH_PER_TICK) as unknown as PostRow[];
    let n = 0;
    for (const p of due) {
      if (!this.mayPublish(p, now)) continue;
      const adapter = this.adapters[p.network];
      if (adapter.disabledReason(p.brand)) continue; // reported in the digest; the post waits until the grace ends
      if (this.publishedToday(p, now) >= MAX_PER_DAY_PER_CHANNEL) {
        this.sql.exec('UPDATE social_posts SET next_at = ?, updated_at = ? WHERE id = ?', now + HOUR, now, p.id);
        continue;
      }
      const fetchImpl = this.fetchImpl();
      if (p.network === 'facebook') {
        // a retry after an ambiguous platform error: if the earlier attempt did create the post, record it instead of posting twice
        if (p.attempts > 0 && p.claim_at && adapter.findByText) {
          const found = await adapter.findByText(p.brand, p.text, p.claim_at, fetchImpl);
          if (found) {
            this.markPublished(p, found, now);
            continue;
          }
          if (found === undefined) {
            this.markUncertain(p, 'could not read the Page feed before a retry', now);
            await this.alertOnce(p, now);
            continue;
          }
        }
        if (await this.deferForSpacing(p, now, fetchImpl)) continue;
      }
      const image = await this.kv().get(p.image_key, 'arrayBuffer');
      if (!image) {
        this.sql.exec(`UPDATE social_posts SET status = 'failed', last_error = 'image missing from KV', updated_at = ? WHERE id = ?`, now, p.id);
        await this.alertOnce(p, now);
        continue;
      }
      // re-read and re-check right before the call (the gate is checked twice), then claim durably
      const fresh = this.post(p.id);
      if (!fresh || fresh.rev !== p.rev || !this.mayPublish(fresh, now)) continue;
      this.sql.exec(`UPDATE social_posts SET status = 'publishing', claim_at = ?, attempts = attempts + 1, updated_at = ? WHERE id = ? AND status = 'approved'`, now, now, p.id);
      await this.sync();
      const r = await adapter.publish({ brand: p.brand, text: p.text, altText: p.alt_text, image, imageType: p.image_type }, fetchImpl);
      const attempts = p.attempts + 1;
      if (r.kind === 'ok') {
        this.markPublished(p, r.remoteId, now);
        n++;
      } else if (r.kind === 'retry' && attempts < RETRY_BACKOFF_MS.length + 1) {
        this.sql.exec(`UPDATE social_posts SET status = 'approved', next_at = ?, last_error = ?, updated_at = ? WHERE id = ?`, now + RETRY_BACKOFF_MS[attempts - 1]!, r.error, now, p.id);
      } else if (r.kind === 'uncertain') {
        this.markUncertain(p, r.error, now);
        if (p.network !== 'facebook') await this.alertOnce(p, now);
      } else {
        this.sql.exec(`UPDATE social_posts SET status = 'failed', last_error = ?, updated_at = ? WHERE id = ?`, r.error, now, p.id);
        await this.alertOnce(p, now);
      }
    }
    return n;
  }

  private markPublished(p: PostRow, remoteId: string, now: number): void {
    this.sql.exec(`UPDATE social_posts SET status = 'published', remote_id = ?, published_at = ?, last_error = NULL, updated_at = ? WHERE id = ?`, remoteId, now, now, p.id);
  }
  private markUncertain(p: PostRow, error: string, now: number): void {
    this.sql.exec(`UPDATE social_posts SET status = 'uncertain', last_error = ?, claim_at = COALESCE(claim_at, ?), updated_at = ? WHERE id = ?`, error, now, now, p.id);
  }

  /** Facebook spacing around posts the OS did not make (Ahmad's Instagram shares). true = deferred this tick. */
  private async deferForSpacing(p: PostRow, now: number, fetchImpl: typeof fetch): Promise<boolean> {
    const spacing = num(this.env.SOCIAL_FB_SPACING_MIN, 180) * MIN;
    const maxDefer = num(this.env.SOCIAL_FB_MAX_DEFER_HOURS, 24) * HOUR;
    const recent = await this.adapters.facebook.recentPosts?.(p.brand, now - spacing, fetchImpl);
    if (!recent) {
      // unknown is not clear: the post goes out at its slot and the digest says spacing could not be checked (ruling RR-social-spacing)
      this.setMeta(`spacing-unknown:${p.brand}`, now);
      return false;
    }
    const ours = new Set(this.rows(`SELECT remote_id FROM social_posts WHERE brand = ? AND network = 'facebook' AND remote_id IS NOT NULL`, p.brand).map((r) => String(r.remote_id)));
    // filter locally too: `since` is a hint to the API, not a guarantee
    const others = recent.filter((x) => !ours.has(x.id) && Number.isFinite(x.createdAt) && x.createdAt > now - spacing);
    if (!others.length) return false;
    const until = Math.max(...others.map((x) => x.createdAt)) + spacing;
    if (until <= now || until > p.orig_scheduled_at + maxDefer) return false;
    this.sql.exec('UPDATE social_posts SET scheduled_at = ?, updated_at = ? WHERE id = ?', until, now, p.id);
    return true;
  }

  /** Stuck claims and uncertain Facebook posts: resolved from the Page feed, never by posting again blind. */
  private async reconcile(now: number): Promise<void> {
    this.sql.exec(`UPDATE social_posts SET status = 'uncertain', last_error = COALESCE(last_error, 'publish claim never finished') WHERE status = 'publishing' AND claim_at < ?`, now - STUCK_CLAIM_MS);
    const unc = this.rows(`SELECT * FROM social_posts WHERE status = 'uncertain' AND claim_at < ? LIMIT 5`, now - RECONCILE_AFTER_MS) as unknown as PostRow[];
    for (const p of unc) {
      const a = this.adapters[p.network];
      const found = p.network === 'facebook' && a.findByText && !a.disabledReason(p.brand) ? await a.findByText(p.brand, p.text, p.claim_at ?? now - DAY, this.fetchImpl()) : undefined;
      if (found) this.markPublished(p, found, now);
      else if (found === null && now <= p.scheduled_at + PUBLISH_GRACE_MS) {
        // the feed was read and the post is not there: it never went out, so it is safe to try again
        this.sql.exec(`UPDATE social_posts SET status = 'approved', next_at = ?, updated_at = ? WHERE id = ?`, now, now, p.id);
      } else await this.alertOnce(p, now);
    }
  }

  private async alertOnce(p: PostRow, now: number): Promise<void> {
    const cur = this.post(p.id);
    if (!cur || cur.alerted) return;
    const r = await sendText(this.env.TELEGRAM_BOT_TOKEN, this.env.TELEGRAM_CHAT_ID, `Social: ${BRAND_LABEL[p.brand]} ${p.network} post ${p.id} is ${cur.status}: ${cur.last_error ?? 'no detail'}. Nothing will be retried automatically.`, this.fetchImpl());
    if (r.ok) this.sql.exec('UPDATE social_posts SET alerted = 1, updated_at = ? WHERE id = ?', now, p.id);
  }

  edits(): Array<{ id: string; rev: number; brand: string; network: string; scheduledAt: number; text: string; note: string }> {
    return this.rows(`SELECT id, rev, brand, network, scheduled_at, text, edit_note FROM social_posts WHERE status = 'edit_requested' ORDER BY scheduled_at LIMIT 50`).map((r) => ({
      id: String(r.id), rev: Number(r.rev), brand: String(r.brand), network: String(r.network), scheduledAt: Number(r.scheduled_at), text: String(r.text), note: String(r.edit_note ?? ''),
    }));
  }

  calendar(from: number, to: number): Array<Record<string, unknown>> {
    return this.rows(`SELECT id, brand, network, rev, status, scheduled_at, approved_by, remote_id, last_error FROM social_posts WHERE orig_scheduled_at BETWEEN ? AND ? ORDER BY orig_scheduled_at LIMIT 500`, from, to);
  }

  getPost(id: string): PostRow | null {
    return this.post(id);
  }

  /** The one daily social digest (05:00 Cairo with the OS digest). null = nothing to say (no posts, no configured network). */
  async buildDigest(now: number): Promise<string | null> {
    const lines: string[] = [];
    let anything = false;
    for (const brand of BRANDS) {
      const m = this.brandMode(brand, now);
      const mode = m.paused
        ? 'paused'
        : m.keepApproval
          ? 'approval (kept on by Ahmad)'
          : m.firstApprovedAt === null
            ? `approval (the ${this.approvalDays()}-day window starts at the first approved post)`
            : m.mode === 'approval'
              ? `approval, day ${Math.floor((now - m.firstApprovedAt) / DAY) + 1} of ${this.approvalDays()}; auto-post from ${cairoTime(m.autoFrom!)}`
              : 'auto-post';
      const sect: string[] = [`${BRAND_LABEL[brand]}: ${mode}`];
      for (const net of NETWORKS) {
        const why = this.adapters[net].disabledReason(brand);
        if (why) sect.push(`  ${net}: disabled (${why})`);
      }
      const rows = this.rows(`SELECT id, network, status, scheduled_at, remote_id, last_error, published_at, updated_at FROM social_posts WHERE brand = ? AND (scheduled_at BETWEEN ? AND ? OR updated_at > ?) ORDER BY scheduled_at`, brand, now - DAY, now + 2 * DAY, now - DAY);
      for (const r of rows) {
        anything = true;
        const s = String(r.status);
        const link = s === 'published' && r.remote_id ? (r.network === 'facebook' ? ` https://www.facebook.com/${r.remote_id}` : ` https://www.linkedin.com/feed/update/${r.remote_id}`) : '';
        const err = ['failed', 'uncertain'].includes(s) && r.last_error ? ` (${String(r.last_error).slice(0, 120)})` : '';
        sect.push(`  ${r.network} ${cairoTime(Number(r.scheduled_at))}: ${s}${link}${err}`);
      }
      // what Instagram shared to the Page in the last 24 h: one cheap feed read per brand, only when Facebook is configured
      if (!this.adapters.facebook.disabledReason(brand) && this.adapters.facebook.recentPosts) {
        const recent = await this.adapters.facebook.recentPosts(brand, now - DAY, this.fetchImpl());
        if (recent) {
          const ours = new Set(this.rows(`SELECT remote_id FROM social_posts WHERE brand = ? AND remote_id IS NOT NULL`, brand).map((r) => String(r.remote_id)));
          const others = recent.filter((x) => !ours.has(x.id));
          const ig = others.filter((x) => /instagram/i.test(x.app ?? '')).length;
          if (others.length) sect.push(`  Facebook Page, not from the OS (24 h): ${others.length}${ig ? ` (${ig} shared from Instagram)` : ''}`);
        } else sect.push('  Facebook Page feed unreadable (needs pages_read_user_content): Instagram-share spacing is off');
        anything = true;
      }
      const li = this.adapters.linkedin as LinkedInAdapter;
      const exp = li.tokenExpiry?.(brand);
      if (exp && exp - now < 7 * DAY) sect.push(`  LinkedIn token expires ${cairoTime(exp)}: re-authorize (see the plan)`);
      lines.push(...sect);
    }
    return anything ? `Social digest ${new Date(now).toISOString().slice(0, 10)}\n${lines.join('\n')}` : null;
  }

  async digest(now: number): Promise<'sent' | 'nothing' | 'duplicate' | 'failed'> {
    const day = new Date(now).toISOString().slice(0, 10);
    if (this.meta<string>('digest:day') === day) return 'duplicate';
    const text = await this.buildDigest(now);
    if (!text) return 'nothing';
    const r = await sendText(this.env.TELEGRAM_BOT_TOKEN, this.env.TELEGRAM_CHAT_ID, text, this.fetchImpl());
    if (!r.ok) return 'failed';
    this.setMeta('digest:day', day);
    return 'sent';
  }
}
