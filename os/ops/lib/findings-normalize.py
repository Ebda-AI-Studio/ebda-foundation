#!/usr/bin/env python3
"""Findings normalizer — the signal-quality core of the Live Companion OS.

The dream cycle emits raw findings (one per site). Raw output is noisy:
  - the same root cause appears as N separate findings (24x "unbounded findMany"
    in one repo), and
  - many findings carry severity "unknown" — noise the companion must not surface.

normalize() turns the raw list into a trustworthy report:
  1. Drop `unknown`/empty-severity findings → a separate `needs_rule` bucket
     (logged, never surfaced) so the companion never cries wolf.
  2. Group by (repo, class, normalized-title) → ONE finding with every site listed.
  3. Apply a suppression list (accepted findings the OS must stop re-surfacing).

Pure stdlib. Used by dream-act (programmatic) and as a CLI for tests/inspection.

CLI:
  findings-normalize.py <findings.json> [--suppressions <file>] [--json|--summary]
"""
from __future__ import annotations

import json
import os
import re
import sys

VALID_SEVERITIES = ("critical", "high", "medium", "low")
_SEV_ORDER = {s: i for i, s in enumerate(VALID_SEVERITIES)}


def _norm_title(title: str) -> str:
    """Collapse a finding title to its root-cause key.

    Strips trailing specifics (file paths, line numbers, package versions,
    CVE ids in parens) so "unbounded findMany in a.ts" and "...in b.ts"
    share one key, while genuinely different titles stay distinct.
    """
    t = (title or "").strip().lower()
    t = re.sub(r"\bghsa-[a-z0-9-]+\b", "", t)          # CVE ids
    t = re.sub(r"\b\d+(\.\d+)+\b", "", t)               # version numbers
    t = re.sub(r"[`'\"].*?[`'\"]", "", t)               # quoted specifics
    t = re.sub(r"\s+", " ", t).strip(" -:·")
    return t


def _sev(f: dict) -> str:
    return str(f.get("severity") or "").strip().lower()


_SEV_WEIGHT = {"critical": 4.0, "high": 3.0, "medium": 2.0, "low": 1.0}
# revenue/operational weight by where the defect lives (path + class keywords)
_REV_HOT = re.compile(
    r"payment|checkout|order|cart|billing|invoice|refund|auth|login|session|"
    r"token|\brls\b|tenant|webhook|subscription", re.I
)
_REV_ADMIN = re.compile(r"admin|dashboard|merchant|console", re.I)
_REV_COLD = re.compile(r"demo|marketing|landing|docs?|storybook|example|fixture", re.I)


def _revenue_weight(group: dict) -> float:
    """How close to money/operations is this finding? path + class heuristic."""
    hay = " ".join(
        [group.get("class", ""), group.get("title", "")]
        + [str((s or {}).get("file") or "") for s in group.get("sites", [])]
    )
    if _REV_HOT.search(hay):
        return 3.0
    if _REV_ADMIN.search(hay):
        return 2.0
    if _REV_COLD.search(hay):
        return 0.8
    return 1.5


def impact_score(group: dict) -> float:
    """impact = severity-weight x revenue-weight x blast-radius(count). Higher = act first."""
    sev = _SEV_WEIGHT.get(group.get("severity", "low"), 1.0)
    rev = _revenue_weight(group)
    blast = 1.0 + min(max(int(group.get("count", 1)) - 1, 0), 9) * 0.1  # 1.0 .. 1.9
    return round(sev * rev * blast, 2)


def _supp_key(f: dict) -> str:
    """Title-keyed suppression key (legacy form, still supported)."""
    return f"{f.get('repo','')}|{f.get('class','')}|{_norm_title(f.get('title',''))}"


def _supp_file_key(f: dict) -> str:
    """File-keyed suppression key — the STABLE one.

    A finding's title is written by the LLM pass and gets reworded between runs.
    On 2026-08-18 `generateSectionPalette() is 104 lines` became
    `generateSectionPalette() — 104 lines` and a reviewed, evidence-backed
    suppression silently lapsed. The file path does not drift like that, so
    (repo, class, file) is the durable identity for "we looked at this and it is
    not a defect".
    """
    return f"{f.get('repo','')}|{f.get('class','')}|{(f.get('file') or '').strip()}"


def _load_one_suppression_file(path: str) -> set[str]:
    """Return suppression keys from one file.

    An entry may key on `file` (preferred — stable) or on `title` (legacy —
    lapses when the scanner rewords). Entries carrying both contribute both keys,
    so an existing title-keyed entry keeps working while the file key takes over.
    """
    if not path or not os.path.exists(path):
        return set()
    try:
        data = json.load(open(path))
    except Exception:
        return set()
    entries = data if isinstance(data, list) else data.get("suppress", [])
    out = set()
    for e in entries:
        if not isinstance(e, dict):
            continue
        if (e.get("file") or "").strip():
            # A bare (repo, class, file) key suppresses EVERY finding of that class
            # in the file — too blunt: it silently swallowed an unrelated
            # "GET() nesting depth 6" sitting in the same route file as a reviewed
            # POST() finding. `symbol` narrows it back to the thing actually
            # reviewed, and unlike prose titles a function name does not drift.
            sym = (e.get("symbol") or "").strip()
            out.add(_supp_file_key(e) + "|" + sym)
        if (e.get("title") or "").strip():
            out.add(_supp_key(e))
    return out


def _is_suppressed(f: dict, suppressions: set[str]) -> bool:
    """True if this finding matches a suppression entry.

    Three accepted forms, most precise first:
      file + symbol -> that symbol's findings of that class in that file
      file only     -> every finding of that class in that file (blunt; use sparingly)
      title         -> legacy exact-title match (lapses when the scanner rewords)
    """
    if _supp_key(f) in suppressions:
        return True
    file_key = _supp_file_key(f)
    if file_key + "|" in suppressions:  # file entry with no symbol
        return True
    title = f.get("title") or ""
    for entry in suppressions:
        if not entry.startswith(file_key + "|"):
            continue
        sym = entry[len(file_key) + 1 :]
        if sym and sym in title:
            return True
    return False


def load_suppressions(path: "str | list[str] | None") -> set[str]:
    """A suppression entry is {repo, class, title} (title matched normalized).

    Accepts one path or a list of paths, unioned. Two sources exist by design:
    a version-controlled BASELINE (ops/lib/findings-suppressions.base.json —
    deliberate, reviewed, arrives with a written rationale) and a mutable STATE
    file (~/.whisky-os-state/findings-suppressions.json — written automatically
    by acceptance-feedback.sh from wontfix issues).

    Absent/corrupt file → contributes nothing, rather than silently hiding
    findings. Each path is loaded independently, so one corrupt file cannot take
    a valid sibling down with it.
    """
    if not path:
        return set()
    paths = [path] if isinstance(path, str) else list(path)
    out: set[str] = set()
    for p in paths:
        if isinstance(p, str):
            out |= _load_one_suppression_file(p)
    return out


def normalize(findings: list[dict], suppressions: set[str] | None = None) -> dict:
    """Return {grouped, needs_rule, suppressed, counts}.

    grouped:    surfaced findings, one per (repo,class,root-title), with `sites`.
    needs_rule: dropped for unclassifiable severity (logged, not surfaced).
    suppressed: dropped by the suppression list.
    """
    suppressions = suppressions or set()
    needs_rule: list[dict] = []
    suppressed: list[dict] = []
    groups: dict[tuple, dict] = {}

    for f in findings or []:
        if not isinstance(f, dict):
            continue
        if _is_suppressed(f, suppressions):
            suppressed.append(f)
            continue
        sev = _sev(f)
        if sev not in VALID_SEVERITIES:
            needs_rule.append(f)
            continue
        key = (f.get("repo", ""), f.get("class", ""), _norm_title(f.get("title", "")))
        site = {
            "file": f.get("file"),
            "line": f.get("line"),
            "title": f.get("title"),
        }
        if key not in groups:
            groups[key] = {
                "repo": f.get("repo", ""),
                "class": f.get("class", ""),
                "title": f.get("title", ""),
                "severity": sev,
                "detail": f.get("detail"),
                "fix": f.get("fix"),
                "autofixable": bool(f.get("autofixable")),
                "sites": [site],
                "count": 1,
            }
        else:
            g = groups[key]
            g["sites"].append(site)
            g["count"] += 1
            # keep the highest severity seen for the group
            if _SEV_ORDER[sev] < _SEV_ORDER[g["severity"]]:
                g["severity"] = sev
            g["autofixable"] = g["autofixable"] or bool(f.get("autofixable"))

    for g in groups.values():
        g["impact_score"] = impact_score(g)
    # rank by business impact first (revenue x severity x blast), then severity/repo
    grouped = sorted(
        groups.values(),
        key=lambda g: (-g["impact_score"], _SEV_ORDER[g["severity"]], g["repo"]),
    )
    counts = {
        "raw": len(findings or []),
        "grouped": len(grouped),
        "needs_rule": len(needs_rule),
        "suppressed": len(suppressed),
        "by_severity": {
            s: sum(1 for g in grouped if g["severity"] == s) for s in VALID_SEVERITIES
        },
    }
    return {
        "grouped": grouped,
        "needs_rule": needs_rule,
        "suppressed": suppressed,
        "counts": counts,
    }


def _main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    path = argv[0]
    supp_path = None
    mode = "--summary"
    i = 1
    while i < len(argv):
        if argv[i] == "--suppressions" and i + 1 < len(argv):
            supp_path = argv[i + 1]
            i += 2
            continue
        if argv[i] in ("--json", "--summary"):
            mode = argv[i]
        i += 1
    try:
        data = json.load(open(path))
    except Exception as e:
        print(f"error: cannot read {path}: {e}", file=sys.stderr)
        return 1
    findings = data if isinstance(data, list) else data.get("findings", [])
    result = normalize(findings, load_suppressions(supp_path))
    if mode == "--json":
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    c = result["counts"]
    print(
        f"raw={c['raw']}  surfaced(grouped)={c['grouped']}  "
        f"needs_rule={c['needs_rule']}  suppressed={c['suppressed']}"
    )
    print(f"by severity: {c['by_severity']}")
    for g in result["grouped"]:
        tag = f" (x{g['count']})" if g["count"] > 1 else ""
        imp = g.get("impact_score", 0)
        print(f"  [imp {imp:>5}] [{g['severity']:>8}] {g['repo']}: {g['title'][:64]}{tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
