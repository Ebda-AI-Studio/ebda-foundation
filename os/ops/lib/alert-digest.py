#!/usr/bin/env python3
"""alert-digest.py — the pure digest builder behind alert-triage.sh.

Classifies normalized alert events into NEW / SURGING / CHANGED / ongoing by
diffing against the previous run's snapshot.

WHY THIS IS A SEPARATE MODULE: it used to be an inline heredoc inside
alert-triage.sh, which made the recency defect below untestable and therefore
undetected for weeks.

TWO COUNT SEMANTICS, DELIBERATELY NOT UNIFIED
---------------------------------------------
`count` on a sentry event is the issue's LIFETIME event total, because
alert-triage.sh reads the per-PROJECT Sentry issues endpoint, which ignores
`statsPeriod` (measured 2026-08-18: it returns issues last seen a month prior,
with lifetime counts, under `statsPeriod=24h`). The org-level endpoint does
honour the period — see ops/lib/sentry-impact.py, which uses it.

Lifetime counts are the CORRECT input for surge detection: they are monotonic,
so `count - previous_count` is exactly "events since the last run". A
period-scoped count would fall as the window slides, fabricating negative
deltas and destroying surge detection. So surge keeps using `count`.

They are the WRONG input for ranking what is currently bleeding: an issue that
fired 35 times and then stopped a month ago outranks one firing right now. That
is what `recent_days` fixes — `ongoing_top` is filtered by `last_seen` before
ranking, so only issues still firing can occupy it.

FAIL-OPEN: an event with a missing or unparseable `last_seen` is treated as
current. Channels other than sentry (uptimerobot DOWN, CI FAILURE) are
point-in-time signals describing the state right now and carry no `last_seen`;
treating those as stale would silently drop every live outage from the digest.
"""
from __future__ import annotations

import datetime as _dt

ONGOING_TOP_N = 12


def _parse_ts(value):
    """ISO8601 → aware datetime, or None if absent/unparseable (caller fails open)."""
    if not value or not isinstance(value, str):
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = _dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed


def is_recent(event: dict, now, recent_days: int) -> bool:
    """True unless the event carries a parseable last_seen older than recent_days."""
    last_seen = _parse_ts(event.get("last_seen"))
    if last_seen is None:
        return True
    reference = _parse_ts(now) if isinstance(now, str) else now
    if reference is None:
        return True
    if reference.tzinfo is None:
        reference = reference.replace(tzinfo=_dt.timezone.utc)
    return (reference - last_seen) <= _dt.timedelta(days=recent_days)


def build_digest(events, seen, surge_delta=5, recent_days=7, now=None):
    """Return (digest, nextseen).

    digest: {new, surging, changed, ongoing_top}
    nextseen: {key: {count, status}} to persist for the next run.
    """
    reference = _parse_ts(now) if isinstance(now, str) else now
    if reference is None:
        reference = _dt.datetime.now(_dt.timezone.utc)

    new, surging, changed, ongoing = [], [], [], []
    nextseen = {}

    for event in events or []:
        key = event.get("key")
        if not key:
            continue
        count = int(event.get("count", 0) or 0)
        status = event.get("status", "")
        nextseen[key] = {"count": count, "status": status}

        previous = seen.get(key) if isinstance(seen, dict) else None
        if previous is None:
            new.append(event)
        elif isinstance(previous, dict):
            grew = count - int(previous.get("count", 0) or 0)
            if grew >= surge_delta:
                surging.append(dict(event, grew=grew))
            elif status != previous.get("status", ""):
                changed.append(event)
            else:
                ongoing.append(event)
        else:
            ongoing.append(event)

    still_firing = [e for e in ongoing if is_recent(e, reference, recent_days)]
    digest = {
        "new": new,
        "surging": surging,
        "changed": changed,
        "ongoing_top": sorted(still_firing, key=lambda e: -int(e.get("count", 0) or 0))[
            :ONGOING_TOP_N
        ],
    }
    return digest, nextseen
