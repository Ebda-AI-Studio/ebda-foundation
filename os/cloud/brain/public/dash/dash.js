// Ebda OS dashboard. Reads GET /api/state (same-origin; the owner's Access session or Basic Auth travels with it, RR-dash-auth),
// renders with textContent only (finding titles, repo names and the digest are untrusted text), refreshes every 60 s while the
// tab is visible. Arabic is the default; the choice is remembered per browser. No inline handlers (CSP script-src 'self').
'use strict';
(() => {
  const T = {
    ar: {
      title: 'لوحة تشغيل Ebda OS', skip: 'انتقل للمحتوى', studio: 'ابدأ ستوديو للذكاء الاصطناعي', site: 'لوحة تشغيل النظام', refresh: 'حدّث', lang: 'English',
      loading: 'بنحمّل الحالة…', glance: 'النهارده باختصار', open: 'ملاحظات مفتوحة', queue: 'في الطابور', acted: 'اتعمل فيها حاجة (7 أيام)',
      messages: 'رسايل النهارده', bugs: 'فاتت 24 ساعة من غير تصرف', bugsNote: 'كل واحدة منهم غلطة في النظام نفسه.',
      decisions: 'قرارات مستنياك', noDecisions: 'مفيش حاجة مستنياك. النظام بيتصرف في الباقي لوحده.',
      findings: 'آخر الملاحظات', colFinding: 'الملاحظة', colLane: 'المسار', colStatus: 'الحالة', colRaised: 'اتسجلت',
      noFindings: 'لسه مفيش ملاحظات. أول ما مراقب يلاقي حاجة هتظهر هنا.',
      runs: 'اللي النظام عمله', noRuns: 'الأيدي لسه ما اشتغلتش ولا مرة، فمفيش تصليحات تتعرض هنا.',
      budget: 'المصروف قصاد الحدود', gaps: 'مراقبين مش شغالين', noGaps: 'كل المراقبين متوصلين وشغالين.',
      gapHint: (m) => `وصّل ${m} عشان المراقب ده يشتغل.`, health: 'صحة الإنتاج', noHealth: 'لسه مفيش فحص صحة. أول فحص بيحصل كل 5 دقايق.',
      digest: 'معاينة الملخص اليومي', digestNote: 'ده اللي هيتبعت على تليجرام الساعة 05:00 UTC لو الملخص اتعمل دلوقتي.',
      footer: 'ابدأ ستوديو للذكاء الاصطناعي · عقل Ebda OS · الصفحة دي ليك انت بس',
      updated: 'آخر تحديث', last24: (a, r) => `${a} من ${r} في آخر 24 ساعة`,
      queueNote: (u, n, q) => `${u} عاجل · ${n} الليلة · ${q} مستني رد`, msgsNote: (d) => (d ? `${d} اتضموا للملخص اليومي` : 'جوه الحد المسموح'),
      handsOff: 'الأيدي مقفولة', handsOn: 'الأيدي شغالة',
      offNote: 'النظام بيراقب ويسجّل ويسألك، بس مش هيصلّح أي حاجة لوحده. اللي محتاج تصليح بيستنى في الطابور لحد ما تفتحها.',
      onNote: 'النظام بيصلّح المشاكل اللي يقدر عليها لوحده جوه حدود المصروف، وبيسألك في أي قرار مينفعش يترجع فيه.',
      offVar: 'مقفولة من إعدادات النظام (HANDS_HALT)، ومش هتشتغل غير بقرار منك.', usagePaused: (r) => `حد الاستهلاك موقف التشغيلات: ${r}`,
      deadline: 'آخر ميعاد', silence: (o) => `لو مردتش، النظام هيمشي على "${o}".`, irreversible: 'ده قرار مينفعش يترجع فيه، فمش هيحصل أي حاجة غير لما ترد.',
      up: 'شغال', down: 'واقع', failed: 'معرفناش نحمّل البيانات. حدّث الصفحة، ولو فضلت كده سجّل دخولك تاني.',
      handsMonth: 'الأيدي: الشهر ده', handsDay: 'الأيدي: النهارده', cf: 'Cloudflare: تقدير الشهر',
      of: 'من', ofLimit: (v, l) => `$${v} من $${l}`, cfMarks: (w, s) => `تحذير عند $${w} · وقف عند $${s}`,
      cfNone: 'لسه مفيش قراءة لاستهلاك Cloudflare. وصّل CF_API_TOKEN و CF_ACCOUNT_ID عشان القراءة تبدأ.',
      cfUnknown: (n) => `القراءة الأخيرة فشلت (${n}). المراقب هيحاول تاني.`, byModel: 'حسب الموديل',
      lanes: { urgent: 'عاجل', nightly: 'الليلة', question: 'محتاجك', digest: 'الملخص' }, opt: { proceed: 'كمّل', hold: 'استنى' },
      status: { open: 'مفتوحة', queued: 'في الطابور', question: 'اتسألت فيها', dispatched: 'بتتصلح', waiting: 'الـPR مفتوح', done: 'خلصت', failed: 'متصلحتش', held: 'متوقفة', resolved: 'اتحلت', running: 'شغالة', timed_out: 'الوقت خلص', digest: 'في الملخص' },
    },
    en: {
      title: 'Ebda OS operations', skip: 'Skip to content', studio: 'Ebda AI Studio', site: 'OS operations', refresh: 'Refresh', lang: 'عربي',
      loading: 'Loading the state…', glance: 'Today at a glance', open: 'Open findings', queue: 'Queued', acted: 'Acted on (7 days)',
      messages: 'Messages today', bugs: 'Unacted after 24 h', bugsNote: 'Each one is a bug in the OS.',
      decisions: 'Decisions waiting for you', noDecisions: 'Nothing is waiting for you. The OS is handling everything else on its own.',
      findings: 'Recent findings', colFinding: 'Finding', colLane: 'Lane', colStatus: 'Status', colRaised: 'Raised',
      noFindings: 'No findings yet. The first thing a watcher notices shows up here.',
      runs: 'What the OS did', noRuns: 'The hands have not run yet, so there are no fixes to show.',
      budget: 'Spend against limits', gaps: 'Watchers not running', noGaps: 'Every watcher is connected and running.',
      gapHint: (m) => `Connect ${m} to enable this watcher.`, health: 'Production health', noHealth: 'No health check yet. The first one runs within 5 minutes.',
      digest: 'Daily digest preview', digestNote: 'This is what Telegram would get at 05:00 UTC if the digest ran now.',
      footer: 'Ebda AI Studio · Ebda OS brain · this page is for you only',
      updated: 'Updated', last24: (a, r) => `${a} of ${r} in the last 24 h`,
      queueNote: (u, n, q) => `${u} urgent · ${n} tonight · ${q} awaiting an answer`, msgsNote: (d) => (d ? `${d} rolled into the digest` : 'within budget'),
      handsOff: 'Hands are OFF', handsOn: 'Hands are ON',
      offNote: 'The OS watches, records and asks you, but fixes nothing on its own. Work that needs a fix waits in the queue until you turn the hands on.',
      onNote: 'The OS fixes what it can on its own within the spend limits, and asks you before anything that cannot be undone.',
      offVar: 'Switched off in the OS config (HANDS_HALT); they stay off until you decide.', usagePaused: (r) => `The usage guard is pausing runs: ${r}`,
      deadline: 'Deadline', silence: (o) => `If you do not answer, the OS goes with "${o}".`, irreversible: 'Irreversible: nothing happens until you answer.',
      up: 'Up', down: 'Down', failed: 'Could not load the data. Refresh the page; if it stays like this, sign in again.',
      handsMonth: 'Hands: this month', handsDay: 'Hands: today', cf: 'Cloudflare: month estimate',
      of: 'of', ofLimit: (v, l) => `$${v} of $${l}`, cfMarks: (w, s) => `warn at $${w} · stop at $${s}`,
      cfNone: 'No Cloudflare reading yet. Connect CF_API_TOKEN and CF_ACCOUNT_ID to start it.',
      cfUnknown: (n) => `The last reading failed (${n}). The watcher will try again.`, byModel: 'By model',
      lanes: { urgent: 'Urgent', nightly: 'Tonight', question: 'Needs you', digest: 'Digest' }, opt: { proceed: 'Go ahead', hold: 'Hold' },
      status: { open: 'Open', queued: 'Queued', question: 'Asked you', dispatched: 'Being fixed', waiting: 'PR open', done: 'Done', failed: 'Not fixed', held: 'On hold', resolved: 'Resolved', running: 'Running', timed_out: 'Timed out', digest: 'In the digest' },
    },
  };
  let lang = 'ar';
  try { lang = localStorage.getItem('ebda-os-lang') === 'en' ? 'en' : 'ar'; } catch { /* storage blocked: Arabic */ }
  let last = null;
  const $ = (id) => document.getElementById(id);
  const t = () => T[lang];
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = String(text); return e; };
  // untrusted / mixed-direction data (English titles inside the Arabic UI) gets its own bidi context
  const data = (tag, cls, text) => { const e = el(tag, cls, text); e.dir = 'auto'; return e; };
  const ltr = (tag, cls, text) => { const e = el(tag, cls, text); e.dir = 'ltr'; return e; };
  const st = (v) => t().status[v] || v;
  const money = (n) => (Number.isFinite(n) ? n.toFixed(2) : '–');
  const fmtTime = (ms) => (ms ? new Intl.DateTimeFormat(lang === 'ar' ? 'ar-EG-u-nu-latn' : 'en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Africa/Cairo' }).format(ms) : '–');
  const pct = (r) => (r === null || r === undefined ? '–' : `${Math.round(r * 100)}%`);

  function applyLang() {
    document.documentElement.lang = lang;
    document.documentElement.dir = lang === 'ar' ? 'rtl' : 'ltr';
    document.title = t().title;
    document.querySelectorAll('[data-i18n]').forEach((n) => { const v = t()[n.dataset.i18n]; if (typeof v === 'string') n.textContent = v; });
    const b = $('lang');
    b.textContent = t().lang;
    b.lang = lang === 'ar' ? 'en' : 'ar';
    if (last) render(last);
  }

  function renderState(s, L) {
    const box = $('state');
    const off = Boolean(s.halt);
    box.dataset.on = off ? 'off' : 'on';
    $('stateTitle').textContent = off ? L.handsOff : L.handsOn;
    const why = $('stateWhy');
    why.replaceChildren();
    if (off) {
      if (/HANDS_HALT/.test(s.halt)) why.textContent = L.offVar;
      else why.append(data('span', '', s.halt));
    } else if (s.usage && s.usage.guard && !s.usage.guard.allowed) {
      why.textContent = L.usagePaused(s.usage.guard.reason);
    }
    why.hidden = !why.textContent;
    $('stateNote').textContent = off ? L.offNote : L.onNote;
  }

  function meter(label, value, limit, opts = {}) {
    const m = el('div', 'meter');
    const head = el('div', 'head');
    const val = el('span', 'val num');
    val.append(ltr('bdi', '', `$${money(value)}`), ` ${t().of} `, ltr('bdi', '', `$${limit}`));
    head.append(el('span', 'label', label), val);
    m.append(head);
    const bar = el('div', 'bar');
    const max = opts.scale || limit;
    const fill = el('span', 'fill');
    fill.style.inlineSize = `${Math.max(0, Math.min(100, (value / max) * 100))}%`;
    bar.append(fill);
    for (const tick of opts.ticks || []) { const k = el('span', 'tick'); k.style.insetInlineStart = `${Math.min(100, (tick / max) * 100)}%`; bar.append(k); }
    bar.setAttribute('role', 'img');
    bar.setAttribute('aria-label', `${label}: ${t().ofLimit(money(value), limit)}`);
    m.append(bar);
    if (opts.note) m.append(el('p', 'sub', opts.note));
    if (value >= (opts.warnAt ?? limit)) m.classList.add('warn');
    return m;
  }

  function renderMeters(s, L) {
    const box = $('meters');
    box.replaceChildren();
    const sp = s.spend || { month: 0, day: 0, monthlyBudget: 150, dailyBudget: 10, byModel: {} };
    const models = Object.entries(sp.byModel || {}).filter(([, v]) => v > 0).map(([k, v]) => `${k} $${money(v)}`).join(' · ');
    box.append(meter(L.handsMonth, sp.month, sp.monthlyBudget, { warnAt: sp.monthlyBudget * 0.8, note: models ? `${L.byModel}: ${models}` : undefined }));
    box.append(meter(L.handsDay, sp.day, sp.dailyBudget));
    const lim = s.cfLimits || { warnUsd: 10, stopUsd: 20 };
    const f = s.footprint;
    if (!f) box.append(el('p', 'sub', `${L.cf}: ${L.cfNone}`));
    else if (f.unknown || !Number.isFinite(f.estUsd)) box.append(el('p', 'sub', `${L.cf}: ${L.cfUnknown(f.note || '?')}`));
    else box.append(meter(L.cf, f.estUsd, lim.stopUsd, { warnAt: lim.warnUsd, ticks: [lim.warnUsd], note: `${L.cfMarks(lim.warnUsd, lim.stopUsd)} · ${fmtTime(f.at)}` }));
  }

  function render(s) {
    last = s;
    const L = t();
    $('stamp').textContent = `${L.updated} ${fmtTime(s.generatedAt)}`;
    renderState(s, L);
    $('open').textContent = s.findings.open;
    $('queue').textContent = s.jobs.queuedUrgent + s.jobs.queuedNightly + s.jobs.awaitingAnswer;
    $('queueNote').textContent = L.queueNote(s.jobs.queuedUrgent, s.jobs.queuedNightly, s.jobs.awaitingAnswer);
    $('acted7').textContent = pct(s.actedOn.d7.ratio);
    $('acted1').textContent = L.last24(s.actedOn.d1.acted, s.actedOn.d1.raised);
    $('msgs').textContent = `${s.messages.sentToday}/${s.messages.budget}`;
    $('msgsNote').textContent = L.msgsNote(s.messages.deferred);
    $('bugs').textContent = s.osBugs;
    $('bugsBox').classList.toggle('warn', s.osBugs > 0);

    const qs = $('questions');
    qs.replaceChildren();
    $('questionsEmpty').hidden = s.questions.length > 0;
    for (const q of s.questions) {
      const li = el('li');
      li.append(data('p', 't', q.text));
      li.append(el('p', 'meta', q.reversible ? `${L.deadline}: ${fmtTime(q.deadline)} · ${L.silence(L.opt[q.default_opt] || q.default_opt)}` : L.irreversible));
      const opts = el('div', 'opts');
      for (const o of q.options) {
        const b = el('button', `btn ${o === q.default_opt ? 'primary' : 'ghost'}`, L.opt[o] || o);
        b.type = 'button';
        b.addEventListener('click', () => answer(q.id, o, b));
        opts.append(b);
      }
      li.append(opts);
      qs.append(li);
    }

    const tb = $('findings');
    tb.replaceChildren();
    if (!s.findings.recent.length) { const tr = el('tr'); const td = el('td', 'sub', L.noFindings); td.colSpan = 4; tr.append(td); tb.append(tr); }
    for (const f of s.findings.recent) {
      const tr = el('tr');
      const c1 = el('td');
      c1.append(data('span', 't', f.title), data('span', 'r', [f.repo, f.reason].filter(Boolean).join(' · ')));
      const c2 = el('td');
      c2.append(el('span', `tag ${f.lane}`, L.lanes[f.lane] || f.lane));
      const c3 = el('td');
      c3.append(el('span', `tag ${['done', 'resolved'].includes(f.status) ? 'ok' : ''}`, st(f.status)));
      tr.append(c1, c2, c3, el('td', 'when', fmtTime(f.raised_at)));
      tb.append(tr);
    }

    const runs = $('runs');
    runs.replaceChildren();
    if (!s.runs.length) runs.append(el('li', 'empty-row', L.noRuns));
    for (const r of s.runs) {
      const li = el('li');
      const who = el('span');
      who.append(el('span', '', `${L.lanes[r.kind] || r.kind} · `), ltr('span', '', r.provider));
      const right = el('span', 'sub');
      right.append(el('span', `tag ${r.status === 'done' ? 'ok' : r.status === 'failed' || r.status === 'timed_out' ? 'down' : ''}`, st(r.status)), el('span', '', ` ${fmtTime(r.started_at)}`));
      li.append(who, right);
      runs.append(li);
    }

    renderMeters(s, L);

    const gaps = $('gaps');
    gaps.replaceChildren();
    const g = s.gaps || [];
    if (!g.length) gaps.append(el('li', 'empty-row', L.noGaps));
    for (const x of g) {
      const li = el('li');
      li.append(ltr('span', 'id', x.id));
      const hint = el('p', 'sub');
      const parts = L.gapHint('\u0000').split('\u0000');
      hint.append(parts[0], ltr('code', '', x.missing), parts[1] || '');
      li.append(hint);
      gaps.append(li);
    }

    const health = $('health');
    health.replaceChildren();
    const obs = (s.health && s.health.obs) || [];
    if (!obs.length) health.append(el('li', 'empty-row', L.noHealth));
    for (const o of obs) {
      const li = el('li');
      const right = el('span');
      right.append(el('span', `tag ${o.ok ? 'ok' : 'down'}`, o.ok ? L.up : L.down), ltr('span', 'sub num', ` ${o.status} · ${o.ms} ms`));
      li.append(ltr('span', 'num', o.url), right);
      health.append(li);
    }

    $('digest').textContent = s.digestPreview || '–';
  }

  async function load() {
    const btn = $('refresh');
    btn.disabled = true;
    try {
      const r = await fetch('/api/state', { credentials: 'same-origin', headers: { accept: 'application/json' } });
      if (!r.ok) throw new Error(String(r.status));
      $('error').hidden = true;
      render(await r.json());
    } catch {
      $('error').textContent = t().failed;
      $('error').hidden = false;
    } finally {
      btn.disabled = false;
    }
  }

  async function answer(id, option, btn) {
    btn.disabled = true;
    try {
      const r = await fetch(`/api/questions/${encodeURIComponent(id)}/answer`, { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ option }) });
      if (!r.ok) throw new Error(String(r.status));
      await load();
    } catch {
      btn.disabled = false;
      $('error').textContent = t().failed;
      $('error').hidden = false;
    }
  }

  $('lang').addEventListener('click', () => {
    lang = lang === 'ar' ? 'en' : 'ar';
    try { localStorage.setItem('ebda-os-lang', lang); } catch { /* ignore */ }
    applyLang();
  });
  $('refresh').addEventListener('click', () => load());
  applyLang();
  load();
  setInterval(() => { if (document.visibilityState === 'visible') load(); }, 60000);
})();
