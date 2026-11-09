#!/usr/bin/env python3
"""merge_gate.py - the pure logic behind ops/merge-gate.sh (no network, fully testable).

  merge_gate.py required <workflows-dir>          -> JSON array of check names that must be an explicit SUCCESS
  merge_gate.py secrets-exposure <workflows-dir>  -> JSON array of "<file>:<job>:<SECRET>" a PR's own code could reach (I-8)
  merge_gate.py evaluate <want-sha> <required-json> < pr.json
                                                    -> one verdict line: ok | wait:<why> | refuse:<why>

pr.json is `gh pr view --json headRefOid,mergeable,statusCheckRollup`.

`required` is DERIVED from the repo's own workflows so it cannot drift: a job is required when its workflow runs on
EVERY pull_request (no `paths` / `paths-ignore` filter on that trigger) AND the job always runs on a PR (no job-level
`if`, or exactly `github.event_name == 'pull_request'`, or exactly the fork guard), and everything it `needs` is itself
such a job. Conditional jobs may legitimately be SKIPPED, so they are only checked for "completed and not failing".
Jobs whose name is a matrix expression are skipped. A path-filtered workflow creates NO check run for a PR outside its
filter, so it can never be required; when it does run, its checks still have to finish and not fail.

`evaluate` judges the LATEST run of each check name: the rollup keeps superseded runs of the same name on the same
head (a run cancelled by a concurrency group, then re-run green), and an old run must not decide the verdict.
"""
import json, os, re, sys

# the fork guard skips only fork PRs, so on a same-repo PR the job always runs (same rule as ops/merge-gate-required.mjs)
ALWAYS_IF = re.compile(
    r"^(github\.event_name == 'pull_request'"
    r"|github\.event_name != 'pull_request' \|\| github\.event\.pull_request\.head\.repo\.full_name == github\.repository)$"
)
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


def pr_path_filtered(text):
    """True when the pull_request trigger itself carries `paths` / `paths-ignore` (block or inline form). GitHub then
    creates no check run for a PR that touches nothing inside the filter. A filter on `push` only does not count."""
    if re.search(r"^(on|'on'|\"on\"):.*pull_request\s*:\s*\{[^}]*\bpaths(-ignore)?\s*:", text, re.M):
        return True
    lines = text.split("\n")
    i = next((k for k, l in enumerate(lines) if re.match(r"^\s+pull_request\s*:", l)), None)
    if i is None:
        return False
    if re.search(r"\bpaths(-ignore)?\s*:", lines[i]):
        return True
    indent = len(lines[i]) - len(lines[i].lstrip())
    for l in lines[i + 1:]:
        if not l.strip() or l.lstrip().startswith("#"):
            continue
        if len(l) - len(l.lstrip()) <= indent:
            break
        if re.match(r"^\s+paths(-ignore)?\s*:", l):
            return True
    return False


def required_checks(wf_dir):
    out = set()
    for f in sorted(os.listdir(wf_dir)):
        if not re.search(r"\.ya?ml$", f):
            continue
        text = open(os.path.join(wf_dir, f), encoding="utf-8").read()
        on_pr, jobs = parse_workflow(text)
        if not on_pr or pr_path_filtered(text):
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


# a job gated to push-to-a-branch (or "not a PR") never runs for PR code, so its secrets are not exposed to it
PUSH_ONLY_IF = re.compile(r"github\.event_name\s*==\s*'push'|github\.event_name\s*!=\s*'pull_request(_target)?'|github\.ref(_name)?\s*==")
SECRET_REF = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_]*)")


def _triggers_pr(text):
    """True when the workflow runs on pull_request or pull_request_target (any YAML spelling of the `on:` block)."""
    return bool(re.search(r"^(on|'on'|\"on\"):.*pull_request", text, re.M)) or bool(
        re.search(r"^(on|'on'|\"on\"):\s*$(\n(?:[ \t].*|)$)*?\n\s+-?\s*pull_request(_target)?\s*:?\s*$", text, re.M)
    )


def secrets_exposure(wf_dir):
    """Secrets (other than GITHUB_TOKEN) that code in a PR can reach: referenced at workflow level or in a job that is not
    gated to push / non-PR events, in a workflow triggered by pull_request or pull_request_target. A hands PR is same-repo,
    so GitHub hands it these secrets; the gate refuses to auto-merge where the PR's own code could read them."""
    out = set()
    for f in sorted(os.listdir(wf_dir)):
        if not re.search(r"\.ya?ml$", f):
            continue
        text = open(os.path.join(wf_dir, f), encoding="utf-8").read()
        if not _triggers_pr(text):
            continue
        head, _, rest = text.partition("\njobs:")
        for m in SECRET_REF.finditer(head):
            if m.group(1) != "GITHUB_TOKEN":
                out.add(f"{f}:(workflow env):{m.group(1)}")
        blocks, cur, cur_id = {}, [], None
        for raw in rest.split("\n"):
            m = re.match(r"^  ([\w-]+):\s*$", raw)
            if m:
                cur_id, cur = m.group(1), []
                blocks[cur_id] = cur
            elif cur_id is not None:
                cur.append(raw)
        for jid, lines in blocks.items():
            body = "\n".join(lines)
            cond = re.search(r"^    if:\s*(.+?)\s*$", body, re.M)
            if cond and PUSH_ONLY_IF.search(cond.group(1)):
                continue
            for m in SECRET_REF.finditer(body):
                if m.group(1) != "GITHUB_TOKEN":
                    out.add(f"{f}:{jid}:{m.group(1)}")
    return sorted(out)


def _status(c):
    if c.get("__typename") == "StatusContext":
        return "IN_PROGRESS" if c.get("state") in ("PENDING", "EXPECTED") else "COMPLETED"
    return c.get("status")


def _conclusion(c):
    if c.get("__typename") == "StatusContext":
        return c.get("state")
    return c.get("conclusion") or ""


def _name(c):
    return c.get("name") or c.get("context") or "?"


def latest_runs(checks):
    """One entry per check name: its LATEST run, by startedAt // createdAt // completedAt; a tie keeps rollup order (the
    later entry wins). `gh` prints a null timestamp as the year-1 zero time, which counts as missing. A run that is not
    finished and has no start time has not started yet, so it is the newest: it can never lose to an older green run."""
    best = {}
    for i, c in enumerate(checks):
        ts = next((t for t in (c.get("startedAt"), c.get("createdAt"), c.get("completedAt")) if t and not t.startswith("0001-")), "")
        if not ts and _status(c) != "COMPLETED":
            ts = "~"  # sorts after every ISO timestamp
        k = _name(c)
        if k not in best or (ts, i) >= best[k][0]:
            best[k] = ((ts, i), c)
    return [c for _, c in sorted(best.values(), key=lambda b: b[0][1])]


def evaluate(pr, want, required):
    checks = latest_runs(pr.get("statusCheckRollup") or [])
    head = pr.get("headRefOid") or ""
    name = _name
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
    elif cmd == "secrets-exposure":
        print(json.dumps(secrets_exposure(sys.argv[2])))
    elif cmd == "evaluate":
        print(evaluate(json.load(sys.stdin), sys.argv[2], json.loads(sys.argv[3])))
    else:
        sys.exit("usage: merge_gate.py required <dir> | secrets-exposure <dir> | evaluate <sha> <required-json> < pr.json")
