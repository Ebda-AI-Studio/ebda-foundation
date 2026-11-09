// Ebda OS dashboard. Reads GET /api/state (Cloudflare Access session cookie travels with same-origin fetch), renders
// with textContent only (finding titles are untrusted text), refreshes every 60 s while the tab is visible.
'use strict';
(() => {
  const T = {
    en: {
      title: 'Ebda OS operations', subtitle: 'What the OS noticed, what it did about it, and what is waiting for you.', now: 'Right now',
      acted: 'Acted on (7 days)', open: 'Open findings', queue: 'Queue', messages: 'Messages today', bugs: 'Unacted after 24 h',
      bugsNote: 'Each one is a bug in the OS.', usage: 'Hands usage guard', decisions: 'Decisions waiting for you',
      noDecisions: 'Nothing is waiting for you. The OS is handling everything else on its own.', findings: 'Recent findings',
      colFinding: 'Finding', colLane: 'Lane', colStatus: 'Status', colRaised: 'Raised', runs: 'Hands runs', health: 'Production health',
      footer: 'Ebda AI Studio · Ebda OS brain', lang: 'عربي', updated: 'Updated', last24: (a, r) => `${a} of ${r} in the last 24 h`,
      queueNote: (u, n, q) => `${u} urgent · ${n} tonight · ${q} awaiting an answer`, msgsNote: (d) => (d ? `${d} rolled into the digest` : 'within budget'),
      allowed: 'Running', paused: 'Paused', deadline: 'Deadline', silence: (o) => `If you do not answer, the OS goes with "${o}".`,
      irreversible: 'Irreversible: nothing happens until you answer.', noRuns: 'No hands runs yet.', noHealth: 'No health check yet.',
      halted: (r) => `Hands HALTED: ${r}`, spend: (m, mb, d, db) => `Spend: $${m.toFixed(2)} of $${mb} this month · $${d.toFixed(2)} of $${db} today`, noFindings: 'No findings yet.', up: 'Up', down: 'Down', answered: 'Recorded.', failed: 'Could not load the dashboard. Check your Access session and try again.',
      lanes: { urgent: 'Urgent', nightly: 'Tonight', question: 'Needs you' }, opt: { proceed: 'Go ahead', hold: 'Hold' },
      status: { open: 'Open', queued: 'Queued', question: 'Asked you', dispatched: 'Being fixed', waiting: 'PR open', done: 'Done', failed: 'Not fixed', held: 'On hold', resolved: 'Resolved', running: 'Running', timed_out: 'Timed out' },
    },
    ar: {
      title: 'تشغيل Ebda OS', subtitle: 'هنا هتلاقي اللي النظام لاحظه، واللي عمله فيه، واللي مستني قرارك.', now: 'دلوقتي',
      acted: 'اتعمل فيها حاجة (7 أيام)', open: 'ملاحظات مفتوحة', queue: 'الطابور', messages: 'رسايل النهارده', bugs: 'فاتت 24 ساعة من غير تصرف',
      bugsNote: 'كل واحدة منهم غلطة في النظام نفسه.', usage: 'حد استهلاك الأيدي', decisions: 'قرارات مستنياك',
      noDecisions: 'مفيش حاجة مستنياك. النظام بيتصرف في الباقي لوحده.', findings: 'آخر الملاحظات',
      colFinding: 'الملاحظة', colLane: 'المسار', colStatus: 'الحالة', colRaised: 'اتسجلت', runs: 'تشغيلات الأيدي', health: 'صحة الإنتاج',
      footer: 'Ebda AI Studio · عقل Ebda OS', lang: 'English', updated: 'آخر تحديث', last24: (a, r) => `${a} من ${r} في آخر 24 ساعة`,
      queueNote: (u, n, q) => `${u} عاجل · ${n} الليلة · ${q} مستني رد`, msgsNote: (d) => (d ? `${d} اتضموا للملخص اليومي` : 'جوه الحد المسموح'),
      allowed: 'شغال', paused: 'متوقف', deadline: 'آخر ميعاد', silence: (o) => `لو مردتش، النظام هيمشي على "${o}".`,
      irreversible: 'ده قرار مينفعش يترجع فيه، فمش هيحصل أي حاجة غير لما ترد.', noRuns: 'لسه مفيش تشغيلات.', noHealth: 'لسه مفيش فحص صحة.',
      halted: (r) => `الأيدي واقفة: ${r}`, spend: (m, mb, d, db) => `المصروف: $${m.toFixed(2)} من $${mb} الشهر ده · $${d.toFixed(2)} من $${db} النهارده`, noFindings: 'لسه مفيش ملاحظات.', up: 'شغال', down: 'واقع', answered: 'اتسجل ردك.', failed: 'معرفناش نحمّل اللوحة. اتأكد من جلسة الدخول وجرب تاني.',
      lanes: { urgent: 'عاجل', nightly: 'الليلة', question: 'محتاجك' }, opt: { proceed: 'كمّل', hold: 'استنى' },
      status: { open: 'مفتوحة', queued: 'في الطابور', question: 'اتسألت فيها', dispatched: 'بتتصلح', waiting: 'الـPR مفتوح', done: 'خلصت', failed: 'متصلحتش', held: 'متوقفة', resolved: 'اتحلت', running: 'شغال', timed_out: 'الوقت خلص' },
    },
  };
  let lang = 'en';
  try { lang = localStorage.getItem('ebda-os-lang') === 'ar' ? 'ar' : 'en'; } catch { /* storage blocked: default */ }
  let last = null;
  const $ = (id) => document.getElementById(id);
  const t = () => T[lang];
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = String(text); return e; };
  // untrusted / mixed-direction data (English titles inside the Arabic UI) gets its own bidi context
  const data = (tag, cls, text) => { const e = el(tag, cls, text); e.dir = 'auto'; return e; };
  const st = (v) => t().status[v] || v;
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

  function render(s) {
    last = s;
    const L = t();
    $('stamp').textContent = `${L.updated} ${fmtTime(s.generatedAt)}`;
    $('acted7').textContent = pct(s.actedOn.d7.ratio);
    $('acted1').textContent = L.last24(s.actedOn.d1.acted, s.actedOn.d1.raised);
    $('open').textContent = s.findings.open;
    $('queue').textContent = s.jobs.queuedUrgent + s.jobs.queuedNightly + s.jobs.awaitingAnswer;
    $('queueNote').textContent = L.queueNote(s.jobs.queuedUrgent, s.jobs.queuedNightly, s.jobs.awaitingAnswer);
    $('msgs').textContent = `${s.messages.sentToday}/${s.messages.budget}`;
    $('msgsNote').textContent = L.msgsNote(s.messages.deferred);
    $('bugs').textContent = s.osBugs;
    $('bugsTile').classList.toggle('warn', s.osBugs > 0);
    $('usage').textContent = s.usage.guard.allowed ? L.allowed : L.paused;
    $('usageNote').textContent = s.usage.report ? `${s.usage.report.weeklyUsedPct}% / ${s.usage.thresholdPct}%` : `– / ${s.usage.thresholdPct}%`;
    const haltEl = $('halt');
    haltEl.hidden = !s.halt;
    if (s.halt) haltEl.textContent = L.halted(s.halt);
    if (s.spend) $('usageNote').textContent += ` · ${L.spend(s.spend.month, s.spend.monthlyBudget, s.spend.day, s.spend.dailyBudget)}`;

    const qs = $('questions');
    qs.replaceChildren();
    $('questionsEmpty').hidden = s.questions.length > 0;
    for (const q of s.questions) {
      const li = el('li');
      li.append(data('span', 't', q.text));
      li.append(el('span', 'meta', q.reversible ? `${L.deadline}: ${fmtTime(q.deadline)} · ${L.silence(L.opt[q.default_opt] || q.default_opt)}` : L.irreversible));
      const opts = el('div', 'opts');
      for (const o of q.options) {
        const b = el('button', o === q.default_opt ? 'primary' : '', L.opt[o] || o);
        b.type = 'button';
        b.addEventListener('click', () => answer(q.id, o, b));
        opts.append(b);
      }
      li.append(opts);
      qs.append(li);
    }

    const tb = $('findings');
    tb.replaceChildren();
    if (!s.findings.recent.length) { const tr = el('tr'); const td = el('td', 'empty', L.noFindings); td.colSpan = 4; tr.append(td); tb.append(tr); }
    for (const f of s.findings.recent) {
      const tr = el('tr');
      const c1 = el('td');
      c1.append(data('span', 't', f.title), data('span', 'r', [f.repo, f.reason].filter(Boolean).join(' · ')));
      const c2 = el('td');
      c2.append(el('span', `pill ${f.lane}`, L.lanes[f.lane] || f.lane));
      const c3 = el('td');
      c3.append(el('span', `pill ${['done', 'resolved'].includes(f.status) ? 'ok' : ''}`, st(f.status)));
      const c4 = el('td', 'num', fmtTime(f.raised_at));
      tr.append(c1, c2, c3, c4);
      tb.append(tr);
    }

    const runs = $('runs');
    runs.replaceChildren();
    if (!s.runs.length) runs.append(el('li', 'empty', L.noRuns));
    for (const r of s.runs) {
      const li = el('li');
      const right = el('span');
      right.append(el('span', '', `${st(r.status)} · `), el('span', 'num', fmtTime(r.started_at)));
      li.append(el('span', '', `${L.lanes[r.kind] || r.kind} · ${r.provider}`), right);
      runs.append(li);
    }

    const health = $('health');
    health.replaceChildren();
    const obs = (s.health && s.health.obs) || [];
    if (!obs.length) health.append(el('li', 'empty', L.noHealth));
    for (const o of obs) {
      const li = el('li');
      const url = el('span', 'num', o.url);
      url.dir = 'ltr';
      const pill = el('span', `pill ${o.ok ? 'ok' : 'urgent'}`, `${o.ok ? L.up : L.down} · `);
      const n = el('span', 'num', `${o.status} · ${o.ms} ms`);
      n.dir = 'ltr';
      pill.append(n);
      li.append(url, pill);
      health.append(li);
    }
  }

  async function load() {
    try {
      const r = await fetch('/api/state', { credentials: 'same-origin', headers: { accept: 'application/json' } });
      if (!r.ok) throw new Error(String(r.status));
      $('error').hidden = true;
      render(await r.json());
    } catch {
      $('error').textContent = t().failed;
      $('error').hidden = false;
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
  applyLang();
  load();
  setInterval(() => { if (document.visibilityState === 'visible') load(); }, 60000);
})();
