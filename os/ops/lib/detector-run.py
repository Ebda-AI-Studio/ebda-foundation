#!/usr/bin/env python3
"""detector-run.py — the memory->detector engine (compounding loop, feature #1).

Every `feedback-*.md` lesson Ahmad paid for in a P0 is a DEFECT CLASS. This runs a
registry of ENCODED detectors (ops/detectors/*.json) so the same class can never
recur silently. A detector is a small declarative rule that emits findings in the
dream 9-field schema. New detectors are drafted from memory lessons via
ops/encode-lesson.sh and reviewed before activation.

Detector spec (ops/detectors/<name>.json):
  {
    "name": "rls-enable-without-write-policy",
    "class": "security-rls", "severity": "high",
    "title": "...", "detail": "...", "fix": "...",
    "globs": ["**/*.sql"],            # which files this applies to
    "match_mode": "file-present-absent" | "file-present" | "line-present",
    "include_regex": "ENABLE ROW LEVEL SECURITY",
    "absent_regex": "FOR (INSERT|UPDATE|DELETE|ALL)",   # only for *-present-absent
    "cap": 25,                         # optional, default 25
    "source_lesson": "feedback-rls-enable-needs-policy-per-command.md"
  }

match_mode:
  file-present-absent : file matches a glob, CONTAINS include_regex, and does NOT
                        contain absent_regex  -> one finding (the "present X without Y" shape)
  file-present        : file CONTAINS include_regex                 -> one finding
  line-present        : EACH line matching include_regex            -> one finding (capped)

CLI:
  detector-run.py --repo NAME --dir PATH [--detectors DIR] [--cap N]
  -> prints a JSON array of findings. Always exits 0 (fail-open).

Pure stdlib. Detectors in _candidates/ and any file starting with "_" are skipped.
"""
from __future__ import annotations

import json
import os
import re
import sys

IGNORE_DIRS = {
    "node_modules", ".next", ".nuxt", "dist", "build", "out", ".git", "coverage",
    "graphify-out", ".turbo", ".vercel", ".cache", ".expo", "_candidates",
    "__tests__", "__mocks__", "e2e", "test", "tests", "fixtures",
}
DEFAULT_CAP = 25
MAX_FILE_BYTES = 400_000


def _glob_to_re(glob):
    """Translate a ** / * glob to a regex matched against a POSIX relpath."""
    out, i, n = [], 0, len(glob)
    while i < n:
        c = glob[i]
        if glob.startswith("**/", i):
            out.append("(?:.*/)?"); i += 3
        elif c == "*":
            out.append("[^/]*"); i += 1
        elif c == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(c)); i += 1
    return re.compile("^" + "".join(out) + "$")


def load_detectors(detectors_dir):
    dets = []
    if not os.path.isdir(detectors_dir):
        return dets
    for fn in sorted(os.listdir(detectors_dir)):
        if not fn.endswith(".json") or fn.startswith("_"):
            continue
        try:
            d = json.load(open(os.path.join(detectors_dir, fn)))
        except Exception:
            continue
        if not d.get("name") or not d.get("include_regex") or not d.get("globs"):
            continue
        try:
            d["_inc"] = re.compile(d["include_regex"], re.IGNORECASE)
            d["_abs"] = re.compile(d["absent_regex"], re.IGNORECASE) if d.get("absent_regex") else None
            d["_globs"] = [_glob_to_re(g) for g in d["globs"]]
        except Exception:
            continue
        dets.append(d)
    return dets


def _finding(repo, d, file, line):
    return {
        "repo": repo, "class": d.get("class", "encoded"),
        "severity": d.get("severity", "low"), "file": file, "line": line,
        "title": str(d.get("title", d["name"]))[:120],
        "detail": str(d.get("detail", ""))[:240],
        "fix": str(d.get("fix", ""))[:160],
        "autofixable": False,
    }


_IMPORT_RE = re.compile(r"""(?:from|import|require)\s*\(?\s*['"]([^'"\n]+)['"]""")
_TEST_WALK_IGNORE = {"node_modules", ".next", ".nuxt", "dist", "build", "out",
                     ".git", "coverage", "graphify-out", ".turbo", ".vercel", ".cache"}


def collect_test_module_refs(dir_):
    """Set of module basenames imported by ANY test/spec file in the tree.

    Lets the `file-without-sibling-test` mode tell whether a handler is exercised
    by SOME test (a central `tests/unit/foo.test.ts` importing it) rather than
    only a same-named sibling — otherwise every handler tested by a
    differently-named central test would be a false positive.
    """
    refs = set()
    for base, dirs, files in os.walk(dir_):
        dirs[:] = [x for x in dirs if x not in _TEST_WALK_IGNORE and not x.startswith(".")]
        relbase = os.path.relpath(base, dir_).replace(os.sep, "/")
        in_test_dir = any(seg in ("__tests__", "test", "tests", "e2e", "__mocks__")
                          for seg in relbase.split("/"))
        for fn in files:
            low = fn.lower()
            if not (in_test_dir or ".test." in low or ".spec." in low):
                continue
            ap = os.path.join(base, fn)
            try:
                if os.path.getsize(ap) > MAX_FILE_BYTES:
                    continue
                t = open(ap, errors="replace").read()
            except Exception:
                continue
            for m in _IMPORT_RE.finditer(t):
                # imports omit the extension, so basename == the module stem
                refs.add(os.path.basename(m.group(1)))
    return refs


def run(repo, dir_, detectors_dir, hard_cap):
    dets = load_detectors(detectors_dir)
    if not dets:
        return []
    # Only pay for the extra test-tree walk when a coverage-gap detector is loaded.
    need_tests = any(d.get("match_mode") == "file-without-sibling-test" for d in dets)
    test_refs = collect_test_module_refs(dir_) if need_tests else set()
    findings = []
    per_det = {d["name"]: 0 for d in dets}
    for base, dirs, files in os.walk(dir_):
        dirs[:] = [x for x in dirs if x not in IGNORE_DIRS and not x.startswith(".")]
        for fn in files:
            ap = os.path.join(base, fn)
            rel = os.path.relpath(ap, dir_)
            relp = rel.replace(os.sep, "/")
            applicable = [d for d in dets if any(g.match(relp) for g in d["_globs"])]
            if not applicable:
                continue
            try:
                if os.path.getsize(ap) > MAX_FILE_BYTES:
                    continue
                text = open(ap, errors="replace").read()
            except Exception:
                continue
            for d in applicable:
                cap = min(int(d.get("cap", DEFAULT_CAP)), hard_cap)
                if per_det[d["name"]] >= cap:
                    continue
                mode = d.get("match_mode", "file-present-absent")
                if mode == "line-present":
                    for m in d["_inc"].finditer(text):
                        ln = text[:m.start()].count("\n") + 1
                        findings.append(_finding(repo, d, rel, ln))
                        per_det[d["name"]] += 1
                        if per_det[d["name"]] >= cap:
                            break
                elif mode == "file-without-sibling-test":
                    # this file matched the glob (a revenue-critical handler);
                    # a finding fires only if NO test anywhere imports its module.
                    if not d["_inc"].search(text):
                        continue
                    stem = os.path.splitext(fn)[0]
                    if stem in test_refs:
                        continue  # exercised by some test -> covered
                    ln = 1
                    findings.append(_finding(repo, d, rel, ln))
                    per_det[d["name"]] += 1
                else:
                    m = d["_inc"].search(text)
                    if not m:
                        continue
                    if mode == "file-present-absent" and d["_abs"] and d["_abs"].search(text):
                        continue  # the guard IS present -> not a finding
                    ln = text[:m.start()].count("\n") + 1
                    findings.append(_finding(repo, d, rel, ln))
                    per_det[d["name"]] += 1
    return findings


def main(argv):
    repo = dir_ = None
    here = os.path.dirname(os.path.abspath(__file__))
    detectors_dir = os.path.normpath(os.path.join(here, "..", "detectors"))
    cap = 50
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--repo" and i + 1 < len(argv):
            repo = argv[i + 1]; i += 2; continue
        if a == "--dir" and i + 1 < len(argv):
            dir_ = argv[i + 1]; i += 2; continue
        if a == "--detectors" and i + 1 < len(argv):
            detectors_dir = argv[i + 1]; i += 2; continue
        if a == "--cap" and i + 1 < len(argv):
            try:
                cap = int(argv[i + 1])
            except Exception:
                cap = 50
            i += 2; continue
        i += 1
    if not repo or not dir_ or not os.path.isdir(dir_):
        print("[]")
        return 0
    try:
        print(json.dumps(run(repo, dir_, detectors_dir, cap)))
    except Exception:
        print("[]")  # fail-open: a detector run must never crash the fleet
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
