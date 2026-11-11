// social-content.mjs pure parts: Cairo slots + ids, topic choice, template escaping, prompt rules, model-output parsing.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildPrompt, cairoToUtc, parseClaudeJson, renderHtml, slotsFor, topicFor } from '../social/social-content.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(readFileSync(join(HERE, '../social/social.config.json'), 'utf8'));

test('Cairo wall clock -> UTC, winter (UTC+2) and summer time (UTC+3)', () => {
  assert.equal(new Date(cairoToUtc(2026, 11, 17, 17, 0)).toISOString(), '2026-11-17T15:00:00.000Z');
  assert.equal(new Date(cairoToUtc(2026, 7, 14, 17, 0)).toISOString(), '2026-07-14T14:00:00.000Z');
});

test('slots: only facebook + linkedin, ids match the brain format, inside the 2-8 day horizon, a week gives the configured cadence', () => {
  const now = Date.UTC(2026, 10, 11, 2, 0);
  const s = slotsFor(config, now);
  assert.ok(s.length > 0);
  for (const x of s) {
    assert.match(x.id, /^(whisky11|ebda)-(facebook|linkedin)-\d{12}$/);
    assert.ok(['facebook', 'linkedin'].includes(x.network));
    assert.ok(x.scheduledAt > now + 1 * 86_400_000 && x.scheduledAt < now + 9 * 86_400_000);
  }
  // 7 consecutive days contain every cadence slot exactly once
  const week = slotsFor({ ...config, horizonDays: { min: 2, max: 8 } }, now);
  const expected = Object.values(config.brands).reduce((n, b) => n + b.cadence.facebook.length + b.cadence.linkedin.length, 0);
  assert.equal(week.length, expected);
  assert.ok(week.some((x) => x.id === 'whisky11-linkedin-202611171500')); // Tue 17 Nov 15:00 Cairo
  assert.equal(new Set(week.map((x) => x.id)).size, week.length);
});

test('topic choice is deterministic per slot id', () => {
  const b = config.brands.whisky11;
  assert.equal(topicFor(b, 'whisky11-facebook-202611171700'), topicFor(b, 'whisky11-facebook-202611171700'));
});

test('templates: copy is HTML-escaped; Ebda renders right-to-left Arabic', () => {
  const t = readFileSync(join(HERE, '../social/templates/ebda.html'), 'utf8');
  const html = renderHtml(t, { headline: '<script>x</script>', sub: 'a & b', lang: 'ar', dir: 'rtl' });
  assert.ok(!html.includes('<script>x'));
  assert.ok(html.includes('&#60;script&#62;') && html.includes('a &#38; b'));
  assert.ok(html.includes('dir="rtl"'));
  assert.ok(!/ff6e01|:\s*orange/i.test(t), 'Ebda template must not use orange');
});

test('the prompt carries the hard rules, only the configured facts, and the edit note on a rewrite', () => {
  const p = buildPrompt(config.brands.ebda, 'facebook', 'x', { text: 'old', note: 'shorter' });
  assert.match(p, /no emojis/);
  assert.match(p, /no numbers, percentages/);
  assert.match(p, /Egyptian Arabic first/);
  assert.match(p, /cash on delivery and InstaPay/);
  assert.match(p, /Ahmad asked for this change: shorter/);
});

test('model output: JSON inside the result (fenced or not) parses; missing fields throw', () => {
  const o = parseClaudeJson(JSON.stringify({ result: '```json\n{"headline":"h","sub":"s","text":"t","altText":"a"}\n```' }));
  assert.equal(o.text, 't');
  assert.throws(() => parseClaudeJson(JSON.stringify({ result: '{"headline":"h"}' })), /missing sub/);
});
