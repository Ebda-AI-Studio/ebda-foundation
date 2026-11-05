#!/usr/bin/env python3
"""merge_gate.py - the pure logic behind ops/merge-gate.sh (no network, fully testable).

  merge_gate.py required <workflows-dir>          -> JSON array of check names that must be an explicit SUCCESS
  merge_gate.py evaluate <want-sha> <required-json> < pr.json
                                                    -> one verdict line: ok | wait:<why> | refuse:<why>

pr.json is `gh pr view --json headRefOid,mergeable,statusCheckRollup`.

`required` is DERIVED from the repo's own workflows so it cannot drift: a job is required when its workflow runs on
pull_request AND the job always runs on a PR (no job-level `if`, or exactly `github.event_name == 'pull_request'`),
and everything it `needs` is itself such a job. Conditional jobs may legitimately be SKIPPED, so they are only
checked for "completed and not failing". Jobs whose name is a matrix expression are skipped.
"""
import json, os, re, sys

ALWAYS_IF = re.compile(r"^github\.event_name == 'pull_request'$")
# an aggregator that runs even when the jobs it needs were legitimately skipped: always required on a PR
ALWAYS_RUN_IF = re.compile(r"^always\(\) && github\.event_name == 'pull_request'$")
OK_CONCLUSIONS = ("SUCCESS", "SKIPPED", "NEUTRAL")


def parse_workflow(text):
    lines = text.split("\n")
    on_pr = False
    idx = next((i for i, l in enumerate(lines) if re.match(r"^(on|'on'|\"on\"):\s*$", l)), None)
    if idx is None:
        on_pr = bool(re.search(r"^(on|'on'|\"on\"):.*pull_request", text, re.M))
    else:
        j = idx + 1
        while j < len(lines) and re.match(r"^(\s|$)", lines[j]):
            if re.match(r"^\s+pull_request\s*:", lines[j]) or re.match(r"^\s+-\s*pull_request\s*$", lines[j]):
                on_pr = True
            j += 1
    jobs, in_jobs, cur = {}, False, None
    for raw in lines:
        if re.match(r"^jobs:\s*$", raw):
            in_jobs = True
            continue
        if in_jobs and re.match(r"^\S", raw) and raw.strip():
            in_jobs, cur = False, None
        if not in_jobs:
            continue
        m = re.match(r"^  ([\w-]+):\s*$", raw)
        if m:
            cur = jobs[m.group(1)] = {"id": m.group(1), "name": None, "if": None, "needs": []}
            continue
        if cur is None:
            continue
        m = re.match(r"^    name:\s*(.+?)\s*$", raw)
        if m:
            cur["name"] = m.group(1).strip("'\"")
            continue
        m = re.match(r"^    if:\s*(.+?)\s*$", raw)
        if m:
            cur["if"] = m.group(1)
            continue
        m = re.match(r"^    needs:\s*(.+?)\s*$", raw)
        if m:
            cur["needs"] = [s.strip() for s in m.group(1).strip("[]").split(",") if s.strip()]
    return on_pr, jobs


def required_checks(wf_dir):
    out = set()
    for f in sorted(os.listdir(wf_dir)):
        if not re.search(r"\.ya?ml$", f):
            continue
        on_pr, jobs = parse_workflow(open(os.path.join(wf_dir, f), encoding="utf-8").read())
        if not on_pr:
            continue

        def always(jid, seen=()):
            j = jobs.get(jid)
            if not j or jid in seen:
                return False
            if j["if"] is not None and ALWAYS_RUN_IF.match(j["if"]):
                return True
            if j["if"] is not None and not ALWAYS_IF.match(j["if"]):
                return False
            return all(always(n, seen + (jid,)) for n in j["needs"])

        for j in jobs.values():
            if always(j["id"]):
                name = j["name"] or j["id"]
                if "${{" not in name:
                    out.add(name)
    return sorted(out)


def _status(c):
    if c.get("__typename") == "StatusContext":
        return "IN_PROGRESS" if c.get("state") in ("PENDING", "EXPECTED") else "COMPLETED"
    return c.get("status")


def _conclusion(c):
    if c.get("__typename") == "StatusContext":
        return c.get("state")
    return c.get("conclusion") or ""


def evaluate(pr, want, required):
    checks = pr.get("statusCheckRollup") or []
    head = pr.get("headRefOid") or ""
    name = lambda c: c.get("name") or c.get("context") or "?"
    if not head.startswith(want):
        return f"refuse:head moved to {head[:9]} (expected {want})"
    if pr.get("mergeable") == "CONFLICTING":
        # a conflicting PR can never go green: say so now instead of waiting hours (UNKNOWN is transient and still waits)
        return "refuse:rebase needed - this PR conflicts with main (mergeable=CONFLICTING) and can never go green; merge or rebase main, resolve, push, then run the gate again"
    cancelled = [name(c) for c in checks if _status(c) == "COMPLETED" and _conclusion(c) == "CANCELLED"]
    if cancelled:
        # a cancelled run is infra or the controller (concurrency group, runner restart), not a defect in the code
        return "refuse:cancelled (infra or controller), re-run: " + ", ".join(cancelled)
    bad = [name(c) for c in checks if _status(c) == "COMPLETED" and _conclusion(c) not in OK_CONCLUSIONS]
    if bad:
        return "refuse:failing check(s): " + ", ".join(bad)
    if not checks:
        return "wait:no checks have reported yet"  # ZERO checks is never green
    pend = [name(c) for c in checks if _status(c) != "COMPLETED"]
    if pend:
        return "wait:not finished: " + ", ".join(pend)
    if pr.get("mergeable") != "MERGEABLE":
        return f"wait:mergeable={pr.get('mergeable')}"
    succeeded = {name(c) for c in checks if _conclusion(c) == "SUCCESS"}
    missing = [r for r in required if r not in succeeded]
    if missing:
        return "wait:required check(s) without an explicit SUCCESS: " + ", ".join(missing)
    return "ok"


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "required":
        print(json.dumps(required_checks(sys.argv[2])))
    elif cmd == "evaluate":
        print(evaluate(json.load(sys.stdin), sys.argv[2], json.loads(sys.argv[3])))
    else:
        sys.exit("usage: merge_gate.py required <dir> | evaluate <sha> <required-json> < pr.json")
