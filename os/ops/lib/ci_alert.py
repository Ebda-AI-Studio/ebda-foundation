#!/usr/bin/env python3
"""CI alert poller core (plan 2026-10-26 S1, incident I15). Runs on the Mac, NOT in a workflow and NOT on the CI fleet:
a dead fleet leaves runs queued forever, which never turn red, so a notify-failure job on that fleet can never fire.

Pages (via notify.sh, deduplicated per run):
  failed-main     a run on the default branch / schedule / dispatch concluded `failure` or `timed_out` (deploys included)
  failed-pr       a pull_request run is red on its 2nd attempt or later (one red attempt is a retry, not an alert)
  queued          a run has been queued/waiting > QUEUED_MIN minutes (dead runner = silent queue)
  unknown         `gh` could not be read for a repo (never "no alerts"): paged at most every UNKNOWN_REPEAT seconds
NEVER pages: cancelled, skipped, neutral, success, in_progress. A run the merge train cancelled is not a failure.
Exit: 0 nothing new / 1 alerted / 3 a repo was UNKNOWN.
"""
import calendar, json, os, subprocess, sys, time

HOME = os.path.expanduser("~")
STATE = os.environ.get("CI_ALERT_STATE", f"{HOME}/.whisky-os-state/ci-alert")
REPOS = os.environ.get("CI_ALERT_REPOS", f'{os.environ.get("OS_ORG", "")}/ebda-store {os.environ.get("OS_REPO_SLUG", "")} umbra').split()
NOTIFY = os.environ.get("CI_ALERT_NOTIFY", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "notify.sh"))
NOW = int(os.environ.get("CI_ALERT_NOW", str(int(time.time()))))
QUEUED_MIN = int(os.environ.get("CI_ALERT_QUEUED_MIN", "20"))
UNKNOWN_REPEAT = int(os.environ.get("CI_ALERT_UNKNOWN_REPEAT", "21600"))
MAIN_BRANCHES = ("main", "master", "production")
MAX_FAIL_AGE_H = int(os.environ.get("CI_ALERT_MAX_FAIL_AGE_H", "24"))   # a failure older than this is history, not news
MAX_PER_TICK = int(os.environ.get("CI_ALERT_MAX_PER_TICK", "5"))
RED = ("failure", "timed_out", "startup_failure")


def parse_ts(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None


def fetch(repo):
    """-> list of run dicts, or None when UNKNOWN."""
    cmd = os.environ.get("CI_ALERT_RUNS_CMD")
    try:
        if cmd:
            r = subprocess.run(cmd, shell=True, env={**os.environ, "REPO": repo}, capture_output=True, text=True, timeout=60)
        else:
            r = subprocess.run(["gh", "api", f"repos/{repo}/actions/runs?per_page=60", "--jq", ".workflow_runs"],
                               capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            return None
        runs = json.loads(r.stdout)
        return runs if isinstance(runs, list) else None
    except Exception:
        return None


def classify(run):
    """-> (kind, detail) or None."""
    status, concl, ev = run.get("status"), run.get("conclusion"), run.get("event")
    created = parse_ts(run.get("created_at") or "")
    if status in ("queued", "waiting", "pending"):
        if created is None:
            return None
        age = (NOW - created) // 60
        return ("queued", f"queued {age} min") if age > QUEUED_MIN else None
    if status != "completed" or concl not in RED:
        return None
    if created is not None and (NOW - created) > MAX_FAIL_AGE_H * 3600:
        return None
    if ev == "pull_request":
        return ("failed-pr", f"attempt {run.get('run_attempt', 1)}") if int(run.get("run_attempt") or 1) >= 2 else None
    if ev in ("schedule", "workflow_dispatch") or run.get("head_branch") in MAIN_BRANCHES:
        return ("failed-main", f"{ev} on {run.get('head_branch')}")
    return None


def load(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def save(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w") as fh:
        json.dump(obj, fh)
    os.replace(tmp, path)


def notify(title, body):
    try:
        return subprocess.run([NOTIFY, title, body], capture_output=True, timeout=30).returncode == 0
    except Exception:
        return False


def main():
    seen_path = os.path.join(STATE, "seen.json")
    seen = load(seen_path, {})
    seen = {k: v for k, v in seen.items() if NOW - v < 7 * 86400}
    alerted, unknown, pending = [], [], []
    for repo in REPOS:
        runs = fetch(repo)
        if runs is None:
            unknown.append(repo)
            key = f"unknown:{repo}"
            if NOW - seen.get(key, 0) >= UNKNOWN_REPEAT:
                notify("ci-alert UNKNOWN", f"Could not read Actions runs for {repo}. CI health is NOT known (never treated as green).")
                seen[key] = NOW
            continue
        for run in runs:
            c = classify(run)
            if not c:
                continue
            kind, detail = c
            key = f"{kind}:{repo}#{run.get('id')}.{run.get('run_attempt', 1)}"
            if key not in seen:
                pending.append((key, f"CI {kind}: {repo}", f"{run.get('name')} ({detail}) {run.get('html_url', '')}"))
    # a burst (first run, outage recovery) is a few pages plus ONE summary, never a flood
    for i, (key, title, body) in enumerate(pending):
        if i < MAX_PER_TICK:
            # a delivery that fails stays unseen so the next tick retries it
            if notify(title, body):
                seen[key] = NOW
                alerted.append(key)
        else:
            seen[key] = NOW
            alerted.append(key)
    if len(pending) > MAX_PER_TICK:
        notify("CI alerts (summary)", f"{len(pending) - MAX_PER_TICK} more CI alerts this tick were not listed: " +
               ", ".join(k for k, _, _ in pending[MAX_PER_TICK:MAX_PER_TICK + 10]))
    save(seen_path, seen)
    out = {"alerted": alerted, "unknown": unknown, "checked_at": NOW}
    save(os.path.join(STATE, "status.json"), out)
    print(json.dumps(out) if "--json" in sys.argv else f"ci-alert: alerted={len(alerted)} unknown={len(unknown)}")
    return 3 if unknown else (1 if alerted else 0)


if __name__ == "__main__":
    sys.exit(main())
