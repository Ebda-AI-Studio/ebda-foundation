// Social posting on workerd: the real BrainDO (SQLite) + KV, the platforms mocked at the HTTP boundary with response shapes recorded
// from the Graph API / LinkedIn REST docs (docs/plans/2026-11-11-social-posting.md links them).
import { env } from 'cloudflare:workers';
import { runInDurableObject, SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import type { BrainDO } from '../src/brain-do';
import { FacebookAdapter } from '../src/social/adapters/facebook';
import { escapeLittleText, LinkedInAdapter } from '../src/social/adapters/linkedin';
import { SocialEngine } from '../src/social/engine';
import { copyViolations, validateDraft } from '../src/social/rules';
import { decisionLink } from '../src/social/telegram';

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const T0 = Date.UTC(2026, 10, 16, 6, 0, 0);
const SLOT = T0 + 2 * DAY; // 2026-11-18 06:00 UTC
const PAGE = '102030405060';
const IMG = btoa(String.fromCharCode(...new Uint8Array(2048).map((_, i) => i % 251)));

// recorded shapes
const FB_PHOTO_OK = { id: '987654321', post_id: `${PAGE}_111222333` };
const FB_TOKEN_ERR = { error: { message: 'Error validating access token: Session has expired.', type: 'OAuthException', code: 190, error_subcode: 463, fbtrace_id: 'AbCdEf' } };
const FB_TRANSIENT = { error: { message: 'An unexpected error has occurred. Please retry your request later.', type: 'OAuthException', is_transient: true, code: 2, fbtrace_id: 'AbCdEf' } };
const LI_INIT = { value: { uploadUrlExpiresAt: 1650567510704, uploadUrl: 'https://www.linkedin.com/dms-uploads/C4E10AQFoyyAjHPMQuQ/uploaded-image/0?ca=vector_ads&cn=uploads&m=AQ', image: 'urn:li:image:C4E10AQFoyyAjHPMQuQ' } };

type Call = { url: string; method: string; body: unknown };
type Route = (url: string, init?: RequestInit) => Response | Promise<Response>;

interface H {
  calls: Call[];
  routes: Record<string, Route>;
  run<R>(fn: (b: BrainDO) => R | Promise<R>): Promise<R>;
  fb(): Call[];
  tg(): Call[];
}

const j = (d: unknown, status = 200, headers: Record<string, string> = {}) => new Response(JSON.stringify(d), { status, headers: { 'content-type': 'application/json', ...headers } });

async function harness(opts: { facebook?: boolean; linkedin?: boolean; envPatch?: Record<string, string> } = { facebook: true }): Promise<H> {
  const stub = env.BRAIN.get(env.BRAIN.idFromName(crypto.randomUUID()));
  const calls: Call[] = [];
  const routes: Record<string, Route> = {
    'api.telegram.org': () => j({ ok: true, result: {} }),
    '/photos': () => j(FB_PHOTO_OK),
    '/feed': () => j({ data: [] }),
  };
  const run = <R>(fn: (b: BrainDO) => R | Promise<R>) => runInDurableObject(stub, (b: BrainDO) => fn(b));
  await run((b) => {
    b.fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      calls.push({ url, method: init?.method ?? 'GET', body: init?.body });
      const key = Object.keys(routes).find((k) => url.includes(k));
      if (!key) throw new Error(`unrouted ${url}`);
      return routes[key]!(url, init);
    }) as typeof fetch;
    if (opts.envPatch) (b as any)._social = new SocialEngine((b as any).sql, { ...b['env'], ...opts.envPatch } as any, () => b.fetchImpl, async () => undefined);
    const s = b.social();
    s.adapters.facebook = new FacebookAdapter(opts.facebook ? JSON.stringify({ whisky11: { pageId: PAGE, pageToken: 'EAAG'.padEnd(40, 'x') }, ebda: { pageId: '605040302010', pageToken: 'EAAG'.padEnd(40, 'y') } }) : undefined, 'v27.0');
    s.adapters.linkedin = new LinkedInAdapter(opts.linkedin ? JSON.stringify({ whisky11: { orgUrn: 'urn:li:organization:5515715', token: 'AQV'.padEnd(40, 'z'), expiresAt: '2026-11-20' } }) : undefined, '202610');
  });
  return {
    calls,
    routes,
    run,
    fb: () => calls.filter((c) => c.url.includes('/photos')),
    tg: () => calls.filter((c) => c.url.includes('api.telegram.org')),
  };
}

const draft = (x: Record<string, unknown> = {}) => ({
  id: 'whisky11-facebook-202611180600',
  brand: 'whisky11',
  network: 'facebook',
  scheduledAt: SLOT,
  text: 'We build web apps and internal tools for small teams in the US and UK. Tell us what slows your team down.',
  imageBase64: IMG,
  imageType: 'image/jpeg',
  origin: 'os',
  ...x,
});

describe('copy rules (the edge gate)', () => {
  it('flags emojis, the GCC contracts company, a bare "Ebda", percentages, client counts and social proof', () => {
    expect(copyViolations('Ship faster \u{1F680}')).toContain('contains an emoji');
    expect(copyViolations(`Built with ${['Fo', 'rce'].join('')} AI`)).toContain('mentions the GCC contracts company');
    expect(copyViolations('Start with Ebda today')[0]).toMatch(/bare "Ebda"/);
    expect(copyViolations('Cut costs by 40%')).toContain('contains a percentage');
    expect(copyViolations('Trusted by 120 merchants')).toEqual(expect.arrayContaining(['contains a count of clients/customers/users']));
    expect(copyViolations('Our customer reviews say it all')).toContain('contains a rating/review/social-proof claim');
  });
  it('clean copy passes: "Ebda AI Studio", "Ebda Store", COD + InstaPay facts, Arabic', () => {
    expect(copyViolations('Ebda Store by Ebda AI Studio: cash on delivery and InstaPay from day one.')).toEqual([]);
    expect(copyViolations('افتح متجرك على Ebda Store والدفع عند الاستلام وانستاباي من أول يوم.')).toEqual([]);
  });
  it('refuses Instagram/TikTok drafts and anything not originated by the OS (never re-post Instagram content)', () => {
    expect(validateDraft(draft({ network: 'instagram', id: 'whisky11-instagram-202611180600' }), T0)).toMatch(/^id must be|facebook and linkedin/);
    expect(validateDraft(draft({ origin: 'instagram' }), T0)).toMatch(/origin/);
    expect(validateDraft(draft(), T0)).toBeNull();
  });
});

describe('approval window gate', () => {
  it('NOTHING publishes unapproved in the window: a draft at its slot, and a forged auto-approval, both stay unpublished', async () => {
    const h = await harness();
    expect(await h.run((b) => b.socialIngest(draft(), T0))).toMatchObject({ ok: true, status: 'draft', rev: 1 });
    for (let t = T0; t <= SLOT + 13 * HOUR; t += HOUR) await h.run((b) => b.socialTick(t));
    expect(h.fb()).toHaveLength(0);
    // forged row: approved but not by Ahmad, brand still in approval
    const h2 = await harness();
    await h2.run((b) => b.socialIngest(draft(), T0));
    await h2.run((b) => (b as any).sql.exec(`UPDATE social_posts SET status = 'approved', approved_by = 'auto'`));
    await h2.run((b) => (b as any).social().publishDue(SLOT + MIN));
    expect(h2.fb()).toHaveLength(0);
  });

  it('the preview goes to Telegram a day ahead (photo + text with Approve / Edit / Skip), then publishes once after approval', async () => {
    const h = await harness();
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialTick(SLOT - 25 * HOUR));
    expect(h.tg()).toHaveLength(0);
    await h.run((b) => b.socialTick(SLOT - 24 * HOUR));
    expect(h.tg().map((c) => c.url.split('/').pop())).toEqual(['sendPhoto', 'sendMessage']);
    const kb = JSON.parse(String(h.tg()[1]!.body)).reply_markup.inline_keyboard[0];
    expect(kb.map((k: any) => k.callback_data)).toEqual(['s:whisky11-facebook-202611180600:a', 's:whisky11-facebook-202611180600:e', 's:whisky11-facebook-202611180600:k']);
    expect(await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'approve', 'test', SLOT - 20 * HOUR))).toMatchObject({ ok: true, status: 'approved' });
    await h.run((b) => b.socialTick(SLOT - MIN));
    expect(h.fb()).toHaveLength(0); // not before the slot
    await h.run((b) => b.socialTick(SLOT));
    await h.run((b) => b.socialTick(SLOT + 5 * MIN));
    await h.run((b) => b.socialTick(SLOT + HOUR));
    expect(h.fb()).toHaveLength(1); // exactly once
    const form = h.fb()[0]!.body as FormData;
    expect(form.get('caption')).toBe(draft().text);
    expect(form.get('published')).toBe('true');
    expect(h.fb()[0]!.url).toBe(`https://graph.facebook.com/v27.0/${PAGE}/photos`);
    expect(await h.run((b) => b.socialPost('whisky11-facebook-202611180600'))).toMatchObject({ status: 'published', remote_id: FB_PHOTO_OK.post_id });
  });

  it('the 14-day clock starts at the first approved post; after it new posts auto-publish without a preview; keepApproval turns it back', async () => {
    const h = await harness();
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'approve', 'test', T0 + HOUR));
    const later = T0 + HOUR + 14 * DAY;
    const d2 = draft({ id: 'whisky11-facebook-202612030600', scheduledAt: later + DAY });
    expect(await h.run((b) => b.socialIngest(d2, later - MIN))).toMatchObject({ status: 'draft' }); // still in the window
    expect(await h.run((b) => b.socialIngest(d2, later))).toMatchObject({ status: 'approved' }); // window over (new revision)
    const tgBefore = h.tg().length;
    await h.run((b) => b.socialTick(later + DAY));
    expect(h.fb()).toHaveLength(1);
    expect(h.tg().length).toBe(tgBefore);
    // Ahmad keeps approval on: an auto-approved, unpublished post is asked again, not published
    const d3 = draft({ id: 'whisky11-facebook-202612050600', scheduledAt: later + 3 * DAY });
    await h.run((b) => b.socialIngest(d3, later + DAY));
    await h.run((b) => b.socialSetBrand('whisky11', { keepApproval: true }));
    await h.run((b) => b.socialTick(later + 3 * DAY));
    expect(h.fb()).toHaveLength(1);
    expect(await h.run((b) => b.socialPost('whisky11-facebook-202612050600'))).toMatchObject({ status: 'asked' });
  });

  it('an unanswered post expires after the slot; a paused brand neither asks nor posts', async () => {
    const h = await harness();
    await h.run((b) => b.socialSetBrand('whisky11', { paused: true }));
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialTick(SLOT - HOUR));
    expect(h.tg()).toHaveLength(0);
    await h.run((b) => b.socialTick(SLOT + 13 * HOUR));
    expect(await h.run((b) => b.socialPost('whisky11-facebook-202611180600'))).toMatchObject({ status: 'expired' });
  });
});

describe('edits', () => {
  it('an edit request is listed for the Mac job; the re-submit is revision 2 and an old-revision approval is refused', async () => {
    const h = await harness();
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'edit', 'test', T0, { note: 'shorter, mention UK' }));
    expect(await h.run((b) => b.socialEdits())).toEqual([expect.objectContaining({ id: 'whisky11-facebook-202611180600', rev: 1, note: 'shorter, mention UK' })]);
    expect(await h.run((b) => b.socialIngest(draft({ text: 'Web apps for small UK and US teams.' }), T0 + MIN))).toMatchObject({ rev: 2, status: 'draft' });
    expect(await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'approve', 'link', T0 + 2 * MIN, { rev: 1 }))).toMatchObject({ ok: false });
    await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'approve', 'link', T0 + 2 * MIN, { rev: 2 }));
    expect(await h.run((b) => b.socialIngest(draft(), T0 + 3 * MIN))).toMatchObject({ ok: false, code: 409 }); // approved = frozen
  });
});

describe('at most once + retries', () => {
  async function approved(h: H) {
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'approve', 'test', T0));
  }

  it('a lost answer is uncertain; the Page feed shows the post, so it is recorded, never posted again', async () => {
    const h = await harness();
    await approved(h);
    h.routes['/photos'] = () => Promise.reject(new Error('connection reset'));
    await h.run((b) => b.socialTick(SLOT));
    expect(await h.run((b) => b.socialPost('whisky11-facebook-202611180600'))).toMatchObject({ status: 'uncertain' });
    h.routes['/feed'] = () => j({ data: [{ id: `${PAGE}_555`, message: draft().text, created_time: '2026-11-18T06:00:05+0000' }] });
    await h.run((b) => b.socialTick(SLOT + 6 * MIN));
    expect(h.fb()).toHaveLength(1);
    expect(await h.run((b) => b.socialPost('whisky11-facebook-202611180600'))).toMatchObject({ status: 'published', remote_id: `${PAGE}_555` });
  });

  it('a lost answer and an empty feed: it never went out, so one retry posts it', async () => {
    const h = await harness();
    await approved(h);
    h.routes['/photos'] = () => Promise.reject(new Error('connection reset'));
    await h.run((b) => b.socialTick(SLOT));
    h.routes['/photos'] = () => j(FB_PHOTO_OK);
    await h.run((b) => b.socialTick(SLOT + 6 * MIN));
    expect(h.fb()).toHaveLength(2);
    expect(await h.run((b) => b.socialPost('whisky11-facebook-202611180600'))).toMatchObject({ status: 'published' });
  });

  it('a transient Graph error retries with backoff; an expired token fails at once and alerts Ahmad once', async () => {
    const h = await harness();
    await approved(h);
    h.routes['/photos'] = () => j(FB_TRANSIENT, 500);
    await h.run((b) => b.socialTick(SLOT));
    await h.run((b) => b.socialTick(SLOT + 5 * MIN)); // backoff 10 min: no call
    expect(h.fb()).toHaveLength(1);
    h.routes['/photos'] = () => j(FB_TOKEN_ERR, 400);
    await h.run((b) => b.socialTick(SLOT + 11 * MIN));
    await h.run((b) => b.socialTick(SLOT + 60 * MIN));
    expect(h.fb()).toHaveLength(2);
    expect(await h.run((b) => b.socialPost('whisky11-facebook-202611180600'))).toMatchObject({ status: 'failed', alerted: 1 });
    expect(h.tg().filter((c) => String(c.body).includes('is failed'))).toHaveLength(1);
  });
});

describe('Instagram-share spacing on Facebook', () => {
  it('a Page post the OS did not make 30 min ago defers the OS post to 3 h after it', async () => {
    const h = await harness();
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'approve', 'test', T0));
    const igAt = SLOT - 30 * MIN;
    h.routes['/feed'] = () => j({ data: [{ id: `${PAGE}_777`, created_time: new Date(igAt).toISOString().replace('.000Z', '+0000'), application: { name: 'Instagram', id: '124024574287414' } }] });
    await h.run((b) => b.socialTick(SLOT));
    expect(h.fb()).toHaveLength(0);
    expect(await h.run((b) => b.socialPost('whisky11-facebook-202611180600'))).toMatchObject({ scheduled_at: igAt + 3 * HOUR });
    await h.run((b) => b.socialTick(igAt + 3 * HOUR + MIN));
    expect(h.fb()).toHaveLength(1);
  });
});

describe('LinkedIn adapter (recorded shapes) and disabled networks', () => {
  it('initializeUpload -> PUT bytes -> POST /rest/posts as the organization, escaped commentary, versioned headers', async () => {
    const h = await harness({ linkedin: true });
    h.routes['initializeUpload'] = () => j(LI_INIT);
    h.routes['dms-uploads'] = () => new Response(null, { status: 201 });
    h.routes['/rest/posts'] = () => new Response(null, { status: 201, headers: { 'x-restli-id': 'urn:li:share:7200000000000000000' } });
    const d = draft({ id: 'whisky11-linkedin-202611180600', network: 'linkedin', text: 'Internal tools (done right) for #ops teams.' });
    await h.run((b) => b.socialIngest(d, T0));
    await h.run((b) => b.socialDecide(d.id, 'approve', 'test', T0));
    await h.run((b) => b.socialTick(SLOT));
    const post = h.calls.find((c) => c.url.endsWith('/rest/posts'))!;
    const body = JSON.parse(String(post.body));
    expect(body).toMatchObject({ author: 'urn:li:organization:5515715', visibility: 'PUBLIC', lifecycleState: 'PUBLISHED', content: { media: { id: LI_INIT.value.image } } });
    expect(body.commentary).toBe(escapeLittleText(d.text as string));
    expect(body.commentary).toContain('\\(done right\\)');
    expect(h.calls.map((c) => c.method)).toEqual(expect.arrayContaining(['PUT']));
    expect(await h.run((b) => b.socialPost(d.id))).toMatchObject({ status: 'published', remote_id: 'urn:li:share:7200000000000000000' });
  });

  it('with no credentials nothing is called, and the digest says why each network is disabled', async () => {
    const h = await harness({ facebook: false, linkedin: false });
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'approve', 'test', T0));
    await h.run((b) => b.socialTick(SLOT));
    expect(h.fb()).toHaveLength(0);
    const text = await h.run((b) => b.social().buildDigest(SLOT));
    expect(text).toMatch(/facebook: disabled \(SOCIAL_FACEBOOK secret unset/);
    expect(text).toMatch(/linkedin: disabled \(SOCIAL_LINKEDIN secret unset/);
    expect(text).toMatch(/Ebda AI Studio: approval/);
  });

  it('the digest lists Instagram shares on the Page, the window day, the LinkedIn token expiry, and is sent once a day', async () => {
    const h = await harness({ facebook: true, linkedin: true });
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialDecide('whisky11-facebook-202611180600', 'approve', 'test', T0));
    h.routes['/feed'] = () => j({ data: [{ id: `${PAGE}_9`, created_time: '2026-11-15T20:00:00+0000', application: { name: 'Instagram' } }] });
    const text = (await h.run((b) => b.social().buildDigest(T0 + HOUR)))!;
    expect(text).toMatch(/Whisky 11: approval, day 1 of 14/);
    expect(text).toMatch(/not from the OS \(24 h\): 1 \(1 shared from Instagram\)/);
    expect(text).toMatch(/LinkedIn token expires/);
    expect(await h.run((b) => b.socialDigest(T0 + HOUR))).toBe('sent');
    expect(await h.run((b) => b.socialDigest(T0 + 2 * HOUR))).toBe('duplicate');
  });
});

describe('routes', () => {
  it('drafts need INGEST_TOKEN; decide needs SOCIAL_DECIDE_TOKEN (the content job cannot approve its own drafts)', async () => {
    const id = `whisky11-linkedin-${new Date(Date.now() + 3 * DAY).toISOString().slice(0, 16).replace(/\D/g, '')}`;
    const d = draft({ id, network: 'linkedin', scheduledAt: Date.now() + 3 * DAY });
    expect((await SELF.fetch('https://brain.test/social/drafts', { method: 'POST', body: JSON.stringify(d) })).status).toBe(401);
    const ok = await SELF.fetch('https://brain.test/social/drafts', { method: 'POST', headers: { Authorization: 'Bearer test-ingest-token' }, body: JSON.stringify(d) });
    expect(ok.status).toBe(200);
    const asIngest = await SELF.fetch('https://brain.test/social/decide', { method: 'POST', headers: { Authorization: 'Bearer test-ingest-token' }, body: JSON.stringify({ id, decision: 'approve' }) });
    expect(asIngest.status).toBe(401);
    const asCtl = await SELF.fetch('https://brain.test/social/decide', { method: 'POST', headers: { Authorization: 'Bearer test-social-decide-token' }, body: JSON.stringify({ id, decision: 'skip' }) });
    expect(await asCtl.json()).toMatchObject({ ok: true, status: 'skipped' });
  });

  it('the signed link: GET only renders (prefetch-safe), POST decides, a tampered signature is 403', async () => {
    const id = `ebda-facebook-${new Date(Date.now() + 2 * DAY).toISOString().slice(0, 16).replace(/\D/g, '')}`;
    const d = draft({ id, brand: 'ebda', text: 'Ebda Store من Ebda AI Studio: الدفع عند الاستلام وانستاباي من أول يوم.', scheduledAt: Date.now() + 2 * DAY });
    await SELF.fetch('https://brain.test/social/drafts', { method: 'POST', headers: { Authorization: 'Bearer test-ingest-token' }, body: JSON.stringify(d) });
    const exp = Math.floor((Date.now() + 3 * DAY) / 1000);
    const link = (await decisionLink('https://brain.test', 'test-social-link-secret', { id, rev: 1 }, exp)) + '&d=approve';
    const get = await SELF.fetch(link);
    expect(get.status).toBe(200);
    expect(get.headers.get('content-security-policy')).toContain("form-action 'self'");
    expect(await get.text()).toContain('Approve this post');
    const cal = await (await SELF.fetch('https://brain.test/social/calendar', { headers: { Authorization: 'Bearer test-ingest-token' } })).json<any[]>();
    expect(cal.find((r) => r.id === id)).toMatchObject({ status: 'draft' }); // GET decided nothing
    const u = new URL(link);
    const form = new FormData();
    for (const k of ['r', 'exp', 'sig', 'd']) form.append(k, u.searchParams.get(k)!);
    const bad = new FormData();
    for (const k of ['r', 'exp', 'd']) bad.append(k, u.searchParams.get(k)!);
    bad.append('sig', 'f'.repeat(64));
    expect((await SELF.fetch(`https://brain.test/social/d/${id}`, { method: 'POST', body: bad })).status).toBe(403);
    expect((await SELF.fetch(`https://brain.test/social/d/${id}`, { method: 'POST', body: form })).status).toBe(200);
    const cal2 = await (await SELF.fetch('https://brain.test/social/calendar', { headers: { Authorization: 'Bearer test-ingest-token' } })).json<any[]>();
    expect(cal2.find((r) => r.id === id)).toMatchObject({ status: 'approved', approved_by: 'ahmad' });
  });

  it('the preview carries signed URL buttons when SOCIAL_LINK_SECRET and the brain URL are set', async () => {
    const h = await harness({ facebook: true, envPatch: { HANDS_BRAIN_URL: 'https://brain.example.test' } });
    await h.run((b) => b.socialIngest(draft(), T0));
    await h.run((b) => b.socialTick(SLOT - 24 * HOUR));
    const kb = JSON.parse(String(h.tg()[1]!.body)).reply_markup.inline_keyboard[0];
    expect(kb.map((k: any) => k.text)).toEqual(['Approve', 'Ask for an edit', 'Skip']);
    expect(kb[0].url).toMatch(/^https:\/\/brain\.example\.test\/social\/d\/whisky11-facebook-202611180600\?r=1&exp=\d+&sig=[0-9a-f]{64}&d=approve$/);
  });
});
