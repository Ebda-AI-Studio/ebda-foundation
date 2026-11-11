#!/usr/bin/env python3
"""osv-severity.py — advisory severity extraction for dream-research.sh.

WHY THIS EXISTS
---------------
On 2026-08-18 dream-research reported "39 new advisories, critical=0 high=0"
with every single one at severity `unknown`. That read as an all-clear. It was
not: the batch contained GHSA-ggr8-5vv4-36mx (CVE-2026-40345), a GitHub-reviewed
HIGH stack-exhaustion bug in deepmerge-ts, present in FOUR repos.

Two defects produced that:

1. osv.dev's /v1/querybatch returns ONLY {id, modified} per vuln — by design.
   It carries no severity, summary, aliases or database_specific. The old parser
   read those fields straight off the batch stub, so they were always absent and
   severity was always "unknown". Details require a second call to
   /v1/vulns/{id}; needs_hydration() marks the stubs that require it.

2. The CVSS fallback was inverted:
       float(...) if "CVSS" not in score else 5.0
   Every real CVSS vector string contains "CVSS", so the ternary always took the
   5.0 branch and bucketed everything as "medium". A
   CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H vector is 9.8 — CRITICAL.

DESIGN RULE: unknown is never rendered as zero. A count of zero criticals is a
finding; a count of 39 unknowns is a blind spot, and the two must never look
alike in a summary. is_all_clear() refuses to call a batch clear while any
severity is still unknown.
"""
from __future__ import annotations

_GITHUB_SEVERITY = {
    "CRITICAL": "critical",
    "HIGH": "high",
    "MODERATE": "medium",
    "MEDIUM": "medium",
    "LOW": "low",
}

# CVSS v3/v4 base-score metric weights, enough to score a vector string without
# pulling a dependency. Values from the CVSS v3.1 specification.
_AV = {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2}
_AC = {"L": 0.77, "H": 0.44}
_UI = {"N": 0.85, "R": 0.62}
_CIA = {"H": 0.56, "L": 0.22, "N": 0.0}
_PR_UNCHANGED = {"N": 0.85, "L": 0.62, "H": 0.27}
_PR_CHANGED = {"N": 0.85, "L": 0.68, "H": 0.50}


def _bucket(score: float) -> str:
    if score >= 9.0:
        return "critical"
    if score >= 7.0:
        return "high"
    if score >= 4.0:
        return "medium"
    if score > 0.0:
        return "low"
    return "unknown"


def _score_vector(vector: str):
    """Compute a CVSS v3.x base score from a vector string, or None."""
    parts = {}
    for chunk in vector.split("/"):
        if ":" in chunk:
            key, _, value = chunk.partition(":")
            parts[key] = value
    required = ("AV", "AC", "PR", "UI", "S", "C", "I", "A")
    if not all(k in parts for k in required):
        return None
    try:
        changed = parts["S"] == "C"
        pr_table = _PR_CHANGED if changed else _PR_UNCHANGED
        exploitability = (
            8.22 * _AV[parts["AV"]] * _AC[parts["AC"]] * pr_table[parts["PR"]] * _UI[parts["UI"]]
        )
        c, i, a = _CIA[parts["C"]], _CIA[parts["I"]], _CIA[parts["A"]]
        iss = 1 - ((1 - c) * (1 - i) * (1 - a))
        if changed:
            impact = 7.52 * (iss - 0.029) - 3.25 * pow(iss - 0.02, 15)
        else:
            impact = 6.42 * iss
        if impact <= 0:
            return 0.0
        raw = min((1.08 if changed else 1.0) * (impact + exploitability), 10.0)
        # CVSS rounds UP to one decimal
        return int(raw * 10 + 0.99999) / 10.0
    except (KeyError, ValueError, OverflowError):
        return None


def severity_of(vuln) -> str:
    """Normalised severity for an OSV vuln object: critical|high|medium|low|unknown."""
    if not isinstance(vuln, dict):
        return "unknown"

    # 1. GitHub-reviewed severity is the most reliable signal when present.
    db_specific = vuln.get("database_specific") or {}
    if isinstance(db_specific, dict):
        label = str(db_specific.get("severity") or "").strip().upper()
        if label in _GITHUB_SEVERITY:
            return _GITHUB_SEVERITY[label]

    # 2. Otherwise score the CVSS entry — numeric score or full vector.
    for entry in vuln.get("severity") or []:
        if not isinstance(entry, dict):
            continue
        score = str(entry.get("score") or "").strip()
        if not score:
            continue
        try:
            return _bucket(float(score))
        except ValueError:
            pass
        if score.upper().startswith("CVSS"):
            computed = _score_vector(score)
            if computed is not None:
                return _bucket(computed)
    return "unknown"


def needs_hydration(vuln) -> bool:
    """True if this is a /v1/querybatch stub that carries no severity data.

    A stub has only {id, modified}; the details live behind /v1/vulns/{id}.
    """
    if not isinstance(vuln, dict):
        return False
    has_detail = bool(vuln.get("database_specific")) or bool(vuln.get("severity"))
    return bool(vuln.get("id")) and not has_detail


def cve_ids_of(vuln) -> list:
    if not isinstance(vuln, dict):
        return []
    return [a for a in (vuln.get("aliases") or []) if str(a).startswith("CVE-")]


def summary_of(vuln, limit: int = 120) -> str:
    if not isinstance(vuln, dict):
        return ""
    text = vuln.get("summary") or vuln.get("details") or ""
    return str(text)[:limit]


def tally(advisories) -> dict:
    """Count advisories per bucket. `unknown` is a first-class bucket, never zero-folded."""
    counts = {"critical": 0, "high": 0, "medium": 0, "low": 0, "unknown": 0}
    for advisory in advisories or []:
        bucket = str((advisory or {}).get("severity") or "unknown").lower()
        counts[bucket if bucket in counts else "unknown"] += 1
    return counts


def is_all_clear(counts: dict) -> bool:
    """An all-clear requires knowing every severity AND none being high+.

    A batch of 39 unknowns is a BLIND SPOT, not a clean bill of health. Reporting
    'critical=0 high=0' for it is how a real HIGH went unnoticed on 2026-08-18.
    """
    counts = counts or {}
    if counts.get("unknown", 0) > 0:
        return False
    return counts.get("critical", 0) == 0 and counts.get("high", 0) == 0
