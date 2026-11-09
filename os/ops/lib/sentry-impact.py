#!/usr/bin/env python3
"""sentry-impact.py — decide whether unresolved Sentry issues are worth degrading
Mission Control over.

WHY: services-watch.sh:probe_sentry used to degrade the board whenever the
`age:-24h` query returned anything at all — no impact test of any kind. On
2026-08-18 that fired on FORCE-API-26: ONE event, ZERO users, a managed Postgres autosuspend
cold-start on ProductService.getCategories that never recurred. A gate that
fires on a single transient blip trains you to ignore it, and then it is worth
less than no gate.

Feed this the per-ORG issues endpoint:
    /api/0/organizations/{org}/issues/?query=is:unresolved&statsPeriod=24h
which (measured 2026-08-18) genuinely honours statsPeriod — so `count` and
`userCount` here are PERIOD totals, unlike the per-project endpoint used by
alert-triage.sh. Do not swap one for the other; see ops/lib/alert-digest.py.

A payload that is not a list of issues returns "skip", never "ok". A gate that
reports green because it could not read its input is the deadest kind of gate.

CLI:  echo '<issues json>' | sentry-impact.py   ->  "<verdict>\t<reason>"
"""
from __future__ import annotations

import json
import sys

# Any ONE of these clears the bar. Users first: a single real person hitting an
# error outranks a large volume of nobody-facing background noise.
DEFAULT_MIN_USERS = 1    # >= this many affected users on any one issue
DEFAULT_MIN_EVENTS = 10  # >= this many events on any one issue
DEFAULT_MIN_ISSUES = 3   # >= this many distinct issues firing at once


def _int(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def verdict(
    issues,
    min_users: int = DEFAULT_MIN_USERS,
    min_events: int = DEFAULT_MIN_EVENTS,
    min_issues: int = DEFAULT_MIN_ISSUES,
):
    """Return (verdict, reason) where verdict is 'ok' | 'warn' | 'skip'."""
    if not isinstance(issues, list):
        return "skip", "sentry: unreadable issues payload (not a list) — probe blind"

    if not issues:
        return "ok", "sentry: no unresolved issues in window"

    worst_by_events = max(issues, key=lambda i: _int(i.get("count")))
    worst_by_users = max(issues, key=lambda i: _int(i.get("userCount")))
    top_events = _int(worst_by_events.get("count"))
    top_users = _int(worst_by_users.get("userCount"))

    def _label(issue) -> str:
        return str(issue.get("shortId") or issue.get("id") or "?")

    if top_users >= min_users:
        return "warn", (
            f"Sentry: {_label(worst_by_users)} affecting {top_users} user(s) "
            f"({len(issues)} unresolved issue(s) in window)"
        )
    if top_events >= min_events:
        return "warn", (
            f"Sentry: {_label(worst_by_events)} fired {top_events} time(s) "
            f"({len(issues)} unresolved issue(s) in window)"
        )
    if len(issues) >= min_issues:
        return "warn", (
            f"Sentry: {len(issues)} distinct unresolved issue(s) firing "
            f"(worst {_label(worst_by_events)} at {top_events} event(s))"
        )
    return "ok", (
        f"sentry: {len(issues)} low-impact issue(s) "
        f"(worst {top_events} event(s), {top_users} user(s)) — below alert floor"
    )


def _env_int(name: str, fallback: int) -> int:
    """Env override, ignoring unset/blank/garbage rather than crashing the probe."""
    import os

    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return fallback
    try:
        return int(raw)
    except ValueError:
        return fallback


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else None
    except ValueError:
        payload = None
    result, reason = verdict(
        payload,
        min_users=_env_int("SENTRY_MIN_USERS", DEFAULT_MIN_USERS),
        min_events=_env_int("SENTRY_MIN_EVENTS", DEFAULT_MIN_EVENTS),
        min_issues=_env_int("SENTRY_MIN_ISSUES", DEFAULT_MIN_ISSUES),
    )
    print(f"{result}\t{reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
