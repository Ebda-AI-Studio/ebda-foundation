#!/usr/bin/env python3
"""code-health.py — the code-health audit engine for the Whisky AI OS.

Scans ONE repo across ALL layers (apps/*, packages/*, src/, scripts/, ...) for
code-health debt and emits findings in the dream-cycle 9-field schema:

  unused-dep      a declared dependency that is never imported       (knip)
  unused-module   a source file with zero inbound references          (knip)
  unused-export   an exported symbol no other module imports          (knip)
  duplication     a code block copy-pasted across files               (jscpd | native)
  overcomplexity  a function that is too long / deep / branchy        (native heuristic)

DETECTION = tools-first, LLM-second (optional, --llm):
  1. Deterministic tools (knip, jscpd) when present — precise. They are OPTIONAL:
     a missing tool is SKIPPED (fail-open), NEVER installed on the fly (dependency
     discipline / no surprise installs under launchd). We invoke via `npx --no-install`.
  2. Native stdlib fallbacks always run: a hash-window duplication detector (only
     when jscpd produced nothing) and a control-flow complexity heuristic — so the
     audit yields signal even with zero tools installed.
  3. --llm: ONE `claude -p --model sonnet` pass that (a) filters tool/heuristic
     false positives (framework entrypoints, intentional dupes, generated code),
     (b) confirms/raises severity, and (c) adds SEMANTIC dead code + overcomplexity
     the tools cannot see. Strictly fail-open: any error keeps the tool findings.

Every finding: {repo, class, severity, file, line, title, detail, fix, autofixable}.
Mechanical classes (unused-dep, unused-export — knip-verified zero references) are
autofixable=True and flow into dream-act Tier A (worktree + verify + PR, still
gated by can_auto_merge; DREAM_AUTOMERGE off = PR-only). Judgment classes
(unused-module, duplication, overcomplexity) stay autofixable=False → Tier-B
proposals. Changed 2026-07-11: the fleet only ever reported and never closed
the loop on even the mechanical findings.

CLI:
  code-health.py --repo NAME --dir PATH [--llm] [--cap N]
  → prints a JSON array of findings to stdout. Always exits 0 (fail-open).

Deps: python3 stdlib only. knip/jscpd/claude are optional and probed at runtime.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys

SRC_EXT = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte")
IGNORE_DIRS = {
    "node_modules", ".next", ".nuxt", "dist", "build", "out", ".git",
    "coverage", "graphify-out", ".turbo", ".vercel", ".cache", "public",
    "__tests__", "__mocks__", "migrations", ".expo",
}
TOOL_TIMEOUT = int(os.environ.get("CODE_HEALTH_TOOL_TIMEOUT", "150"))
LLM_TIMEOUT = int(os.environ.get("CODE_HEALTH_LLM_TIMEOUT", "180"))


# knip-verified zero-reference classes whose fix is mechanical (npm uninstall /
# strip an export) — safe for dream-act Tier A. The rest need human judgment.
AUTOFIX_CLASSES = {"unused-dep", "unused-export"}


def finding(repo, cls, sev, title, detail, fix, file="", line=0):
    return {
        "repo": repo, "class": cls, "severity": sev, "file": file, "line": line,
        "title": title[:120], "detail": detail[:240], "fix": fix[:160],
        "autofixable": cls in AUTOFIX_CLASSES,
    }


def walk_sources(root):
    """Yield (abspath, relpath) for source files across all layers."""
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS and not d.startswith(".")]
        for fn in files:
            if fn.endswith(SRC_EXT) and not fn.endswith((".d.ts", ".test.ts", ".test.tsx", ".spec.ts")):
                ap = os.path.join(base, fn)
                yield ap, os.path.relpath(ap, root)


# ---------------------------------------------------------------------------
# Deterministic tools (optional, fail-open)
# ---------------------------------------------------------------------------
def _has_npx():
    return shutil.which("npx") is not None


def run_knip(repo, dir_, cap):
    """knip → unused files / exports / deps. Empty list if knip not resolvable."""
    if not _has_npx() or not os.path.isfile(os.path.join(dir_, "package.json")):
        return []
    try:
        p = subprocess.run(
            ["npx", "--no-install", "knip", "--reporter", "json", "--no-progress"],
            cwd=dir_, capture_output=True, text=True, timeout=TOOL_TIMEOUT,
        )
    except Exception:
        return []
    out = (p.stdout or "").strip()
    if not out or "{" not in out:
        return []  # knip absent (npx --no-install errored) or no JSON
    try:
        data = json.loads(out[out.index("{"):])
    except Exception:
        return []
    res = []
    for f in (data.get("files") or [])[:cap]:
        res.append(finding(
            repo, "unused-module", "medium",
            "unused file (zero inbound references): " + os.path.basename(str(f)),
            "knip reports this file is never imported by any other module.",
            "verify no dynamic import / framework entrypoint, then delete.",
            file=str(f),
        ))
    for issue in (data.get("issues") or []):
        fpath = issue.get("file", "")
        for dep in (issue.get("dependencies") or []) + (issue.get("devDependencies") or []):
            name = dep.get("name") if isinstance(dep, dict) else dep
            res.append(finding(
                repo, "unused-dep", "low",
                "unused dependency: " + str(name),
                "knip reports this declared dependency is never imported.",
                "remove from package.json after confirming no runtime/CLI use.",
                file=fpath,
            ))
        for exp in (issue.get("exports") or []) + (issue.get("types") or []):
            name = exp.get("name") if isinstance(exp, dict) else exp
            ln = exp.get("line", 0) if isinstance(exp, dict) else 0
            res.append(finding(
                repo, "unused-export", "low",
                "unused export: " + str(name),
                "knip reports this exported symbol is imported by no other module.",
                "drop the export (or the symbol) if it is not a public API.",
                file=fpath, line=ln or 0,
            ))
        if len(res) >= cap * 3:
            break
    return res[: cap * 3]


def run_jscpd(repo, dir_, cap):
    """jscpd → cross-file duplication. Empty list if jscpd not resolvable."""
    if not _has_npx():
        return []
    import tempfile
    tmp = tempfile.mkdtemp(prefix="jscpd-")
    ignore = ",".join("**/%s/**" % d for d in IGNORE_DIRS)
    try:
        subprocess.run(
            ["npx", "--no-install", "jscpd", dir_, "--silent", "--reporters", "json",
             "--output", tmp, "--ignore", ignore, "--min-lines", "8", "--min-tokens", "70"],
            cwd=dir_, capture_output=True, text=True, timeout=TOOL_TIMEOUT,
        )
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        return []
    report = os.path.join(tmp, "jscpd-report.json")
    res = []
    if os.path.isfile(report):
        try:
            data = json.load(open(report))
            for d in (data.get("duplicates") or [])[:cap]:
                a = d.get("firstFile", {}) or {}
                b = d.get("secondFile", {}) or {}
                lines = d.get("lines", 0)
                af = _rel(a.get("name", ""), dir_)
                bf = _rel(b.get("name", ""), dir_)
                if af == bf:
                    continue
                sev = "medium" if lines >= 40 else "low"
                res.append(finding(
                    repo, "duplication", sev,
                    "duplicated block (%d lines) with %s" % (lines, bf),
                    "jscpd: this block is copy-pasted from %s." % bf,
                    "extract the shared block into a function / shared module.",
                    file=af, line=(a.get("start") or 0),
                ))
        except Exception:
            pass
    shutil.rmtree(tmp, ignore_errors=True)
    return res


def _rel(path, root):
    try:
        return os.path.relpath(path, root)
    except Exception:
        return path


# ---------------------------------------------------------------------------
# Native fallbacks (always available — stdlib only)
# ---------------------------------------------------------------------------
_WS = re.compile(r"\s+")


_DUP_WINDOW = 20  # lines per duplication-detection window (native fallback)


def native_duplication(repo, dir_, cap):
    """Hash sliding normalized windows; flag identical cross-file blocks."""
    w = _DUP_WINDOW
    seen = {}  # hash -> (relfile, lineno)
    res = []
    reported = set()
    for ap, rel in walk_sources(dir_):
        try:
            lines = open(ap, errors="replace").readlines()
        except Exception:
            continue
        norm = [_WS.sub(" ", ln).strip() for ln in lines]
        n = len(norm)
        i = 0
        while i <= n - w:
            block = "\n".join(norm[i:i + w])
            if len(block.replace(" ", "")) < 150:  # too trivial to matter
                i += 1
                continue
            h = hash(block)
            if h in seen:
                src_f, src_l = seen[h]
                if src_f != rel and (rel, src_f) not in reported:
                    reported.add((rel, src_f))
                    res.append(finding(
                        repo, "duplication", "low",
                        "duplicated %d-line block with %s" % (w, src_f),
                        "An identical %d-line block exists in %s:%d." % (w, src_f, src_l),
                        "extract the shared block into a function / shared module.",
                        file=rel, line=i + 1,
                    ))
                    if len(res) >= cap:
                        return res
                i += w  # skip past the matched window
                continue
            seen[h] = (rel, i + 1)
            i += 1
    return res


_FUNC_RE = re.compile(
    r"(?:^|\s)(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\("  # function foo(
    r"|(?:^|\s)(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\([^)]*\)\s*=>"  # const foo = (...) =>
    r"|(?:^|\s)(\w+)\s*\([^)]*\)\s*\{",  # method foo(...) {  (rough)
)
_BRANCH_RE = re.compile(r"\b(if|for|while|switch|case|catch)\b|&&|\|\||\?\.")


def native_complexity(repo, dir_, cap):
    """Flag over-long / deeply-nested / heavily-branched functions (JS/TS).

    Heuristic, brace-matched: for each detected function start, walk its body and
    measure length, max nesting depth, and branch count. Thresholds are deliberately
    conservative (the --llm pass refines / discards borderline cases).
    """
    res = []
    for ap, rel in walk_sources(dir_):
        if not ap.endswith((".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs")):
            continue
        try:
            text = open(ap, errors="replace").read()
        except Exception:
            continue
        for m in _FUNC_RE.finditer(text):
            name = m.group(1) or m.group(2) or m.group(3) or "anonymous"
            if name in ("if", "for", "while", "switch", "catch", "function", "return"):
                continue
            # find first { at/after the match, then brace-match to its close
            open_idx = text.find("{", m.start())
            if open_idx == -1:
                continue
            depth, max_depth, j = 0, 0, open_idx
            in_body_start = open_idx
            while j < len(text):
                c = text[j]
                if c == "{":
                    depth += 1
                    max_depth = max(max_depth, depth)
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            body = text[in_body_start:j]
            length = body.count("\n")
            branches = len(_BRANCH_RE.findall(body))
            nesting = max_depth - 1  # subtract the function's own brace level
            reasons = []
            if length > 90:
                reasons.append("%d lines" % length)
            if nesting >= 5:
                reasons.append("nesting depth %d" % nesting)
            if branches >= 18:
                reasons.append("%d branches" % branches)
            if reasons:
                sev = "medium" if (length > 160 or nesting >= 6 or branches >= 28) else "low"
                lineno = text[:m.start()].count("\n") + 1
                res.append(finding(
                    repo, "overcomplexity", sev,
                    "complex function %s() — %s" % (name, ", ".join(reasons)),
                    "Function %s exceeds complexity thresholds (%s)." % (name, ", ".join(reasons)),
                    "decompose into smaller helpers; flatten guard clauses early.",
                    file=rel, line=lineno,
                ))
                if len(res) >= cap:
                    return res
    return res


# ---------------------------------------------------------------------------
# LLM judgment pass (optional, fail-open)
# ---------------------------------------------------------------------------
def llm_refine(repo, dir_, tool_findings, cap):
    """ONE sonnet pass: filter false positives + add semantic findings.

    Returns the curated list on success, or `tool_findings` unchanged on ANY
    failure (claude missing, timeout, non-JSON, empty result).
    """
    claude = shutil.which("claude")
    if not claude:
        return tool_findings

    # Gather excerpts of the most-flagged files (cap total input).
    by_file = {}
    for f in tool_findings:
        by_file.setdefault(f.get("file") or "", 0)
        by_file[f.get("file") or ""] += 1
    top_files = [f for f, _ in sorted(by_file.items(), key=lambda kv: -kv[1]) if f][:10]
    excerpts = []
    budget = 36000
    for rel in top_files:
        ap = os.path.join(dir_, rel)
        try:
            txt = open(ap, errors="replace").read()
        except Exception:
            continue
        # cut at a line boundary + mark the cut — a mid-token cut made the LLM
        # reason over half a function body and misjudge the batch's last file
        if len(txt) > 4000:
            txt = txt[:4000].rsplit("\n", 1)[0] + "\n... [excerpt truncated — file continues]"
        chunk = "\n--- %s ---\n%s" % (rel, txt)
        if budget - len(chunk) < 0:
            break
        budget -= len(chunk)
        excerpts.append(chunk)

    prompt = (
        "You are a code-health auditor for the repo '%s'. Below are candidate findings "
        "from static tools (dead code, duplication, unused modules/exports/deps, "
        "overcomplexity) plus excerpts of the most-flagged files.\n\n"
        "Your job: (1) DROP false positives — framework entrypoints, route files, "
        "generated code, public-API exports, intentional/config duplication. "
        "(2) Keep real findings, fixing severity if wrong. (3) ADD any SEMANTIC dead "
        "code or genuine overcomplexity the tools missed that you can see in the excerpts.\n\n"
        "Return ONLY a JSON array (no prose, no markdown fence) of objects with EXACTLY "
        "these keys: repo, class, severity, file, line, title, detail, fix, autofixable. "
        "class must be one of: unused-dep, unused-module, unused-export, duplication, "
        "overcomplexity. severity one of: critical, high, medium, low. autofixable: true only "
        "for unused-dep/unused-export (the system re-derives it anyway). "
        "repo must be '%s'. Cap at %d items.\n\n"
        "CANDIDATE FINDINGS:\n%s\n\nFILE EXCERPTS:\n%s\n"
        % (repo, repo, cap, json.dumps([
            {k: f[k] for k in ("class", "severity", "file", "line", "title")}
            for f in tool_findings[: cap * 2]
        ], indent=0), "\n".join(excerpts))
    )

    try:
        p = subprocess.run(
            ["claude", "-p", "--model", "sonnet"],
            input=prompt, capture_output=True, text=True, timeout=LLM_TIMEOUT,
        )
    except Exception:
        return tool_findings
    out = (p.stdout or "").strip()
    if "[" not in out:
        return tool_findings
    try:
        arr = json.loads(out[out.index("["): out.rindex("]") + 1])
    except Exception:
        return tool_findings
    if not isinstance(arr, list) or not arr:
        return tool_findings  # never let the LLM zero-out signal silently
    valid_cls = {"unused-dep", "unused-module", "unused-export", "duplication", "overcomplexity"}
    valid_sev = {"critical", "high", "medium", "low"}
    curated = []
    for f in arr:
        if not isinstance(f, dict):
            continue
        if f.get("class") not in valid_cls or f.get("severity") not in valid_sev:
            continue
        curated.append(finding(
            repo, f["class"], f["severity"],
            str(f.get("title", ""))[:120], str(f.get("detail", ""))[:240],
            str(f.get("fix", ""))[:160],
            file=str(f.get("file", "")), line=int(f.get("line") or 0),
        ))
    return curated[:cap * 3] if curated else tool_findings


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
def scan(repo, dir_, use_llm, cap):
    findings = []
    findings += run_knip(repo, dir_, cap)
    dup = run_jscpd(repo, dir_, cap)
    if not dup:  # jscpd absent / nothing — fall back to native
        dup = native_duplication(repo, dir_, cap)
    findings += dup
    findings += native_complexity(repo, dir_, cap)
    if use_llm and findings:
        findings = llm_refine(repo, dir_, findings, cap)
    return findings


def main(argv):
    repo = dir_ = None
    use_llm = False
    cap = 25
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--repo" and i + 1 < len(argv):
            repo = argv[i + 1]; i += 2; continue
        if a == "--dir" and i + 1 < len(argv):
            dir_ = argv[i + 1]; i += 2; continue
        if a == "--cap" and i + 1 < len(argv):
            try:
                cap = int(argv[i + 1])
            except Exception:
                cap = 25
            i += 2; continue
        if a == "--llm":
            use_llm = True
        i += 1
    if not repo or not dir_ or not os.path.isdir(dir_):
        print("[]")
        return 0
    try:
        findings = scan(repo, dir_, use_llm, cap)
    except Exception:
        findings = []  # fail-open: a scan must never crash the fleet
    print(json.dumps(findings))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
