"""Notify on NEW code-health findings, not on their existence.

2026-08-25: code-health-scan notified whenever `grouped > 0`, which for any
real codebase is always. Six runs in one day produced six Telegram digests
reading 89 / 85 / 94 / 96 / 86 / 96 grouped and 18 / 15 / 14 / 13 / 16 / 19
high — on code with no commits between runs. The counts move because the scan
ends in a `claude -p --model sonnet` judgment pass, so every run resamples the
same distribution. A number that swings +/-6 on unchanged code is not a signal,
and a notification that fires unconditionally trains you to ignore it.

Status and bus events still carry the full picture every run; only the
NOTIFICATION is gated, and only on genuinely new high+ findings.

The key must survive the LLM rewording the same finding. Line counts drift
("510-line" -> "512-line") and phrasing varies, so the key is
repo | class | file | symbol, where symbol is the leading identifier of the
title. That is stable across reruns while still separating two findings in the
same file.
"""

import json
import os
import re
import tempfile

# The called symbol anywhere in the title. Must come FIRST: the engine emits
# both "CheckoutClient() is a 1794-line ..." and "complex function onKey() — 39
# branches", and keying on the leading word collapsed every "complex function
# X()" in a file to the single key "complex" — masking all but one of them.
_CALLED = re.compile(r'([A-Za-z_$][A-Za-z0-9_$.]*)\s*\(')
# Component-style titles carry no parens: "WaOrderingClient is a 555-line ...".
_SUBJECT = re.compile(r'^\s*([A-Za-z_$][A-Za-z0-9_$.]*)\s+(?:is|has|was|mixes|owns|combines|handles|contains)\b')
_DIGITS = re.compile(r'\d+')


def finding_key(f):
    """Stable identity for a grouped finding. Never returns None."""
    repo = (f.get("repo") or "?").strip()
    cls = (f.get("class") or "?").strip()
    sites = f.get("sites") or []
    site = sites[0] if isinstance(sites, list) and sites and isinstance(sites[0], dict) else {}
    path = (site.get("file") or "?").strip()
    title = f.get("title") or site.get("title") or ""

    m = _CALLED.search(title)
    if not m:
        m = _SUBJECT.match(title)
    if m:
        symbol = m.group(1)
    else:
        # A prose title (most duplication findings). Strip digits so a
        # "20-line block" becoming a "22-line block" does not re-key, and
        # keep the rest: for these, DISTINCTNESS beats reword-stability. A
        # re-keyed finding notifies once more; a collided one is masked
        # entirely, and silence is the worse failure.
        symbol = _DIGITS.sub("#", re.sub(r'\s+', ' ', title.lower())).strip()[:80]
    return "|".join((repo, cls, path, symbol))


def load_seen(path):
    """Previously-seen keys. A missing or corrupt file reads as EMPTY-UNKNOWN."""
    if not path or not os.path.exists(path):
        return None                       # None = no baseline, distinct from {}
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception:
        return None
    seen = d.get("seen")
    return seen if isinstance(seen, dict) else None


def save_seen(path, findings, now):
    """Persist every current key. Written atomically: a half-written baseline
    would read as corrupt on the next run and re-notify the whole backlog."""
    seen = {}
    for f in findings:
        k = finding_key(f)
        seen[k] = {"severity": f.get("severity") or "", "last_seen": now}
    tmp = None
    try:
        d = os.path.dirname(path) or "."
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".findings-delta-")
        with os.fdopen(fd, "w") as fh:
            json.dump({"seen": seen, "updated_at": now}, fh)
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
    return seen


def delta(findings, seen, high_severities=("critical", "high")):
    """-> dict(new_high, new_total, resolved, first_run, notify)

    first_run (no baseline) does NOT notify: the first run after this ships
    would otherwise announce the entire existing backlog as brand new.
    """
    first_run = seen is None
    base = seen or {}
    cur = {finding_key(f): f for f in findings}

    new_keys = [k for k in cur if k not in base]
    new_high = [k for k in new_keys
                if (cur[k].get("severity") or "").lower() in high_severities]
    resolved = [k for k in base if k not in cur]

    return {
        "new_high": len(new_high),
        "new_total": len(new_keys),
        "resolved": len(resolved),
        "first_run": first_run,
        # Only a genuinely new high+ finding is worth interrupting for.
        "notify": (not first_run) and len(new_high) > 0,
        "new_high_keys": sorted(new_high),
    }
