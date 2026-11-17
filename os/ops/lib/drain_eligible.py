#!/usr/bin/env python3
"""drain_eligible.py - ONE definition of "a PR the drain can merge", shared by drain.sh and loop-watchdog.sh (G15).

WHY (2026-11-15). loop-watchdog counted every PR labelled ai-review-passed (not hold, not draft) as "approved and waiting", so the
stall alert on ebda-store said "64 approved PRs" while the drain could merge almost none of them (red or pending checks, conflicts,
risky-path PRs without ai-review-passed). Two copies of the rule drifted; now there is one.

classify(pr, strict) -> "ok" | "no"   a PR that is not a draft, not labelled `hold`, with checks that have not failed.
    strict=True  (drain): mergeable == MERGEABLE, at least one check, every check COMPLETED and not failing (zero checks = CI has not
                 started, never green).
    strict=False: no failed check and not CONFLICTING (pending counts). The stall alert uses strict=True: pending = still working, not a stall.
eligible(pr, hold_risky, strict, require_passed) -> bool
    classify == ok, and a `risky-path` PR needs `ai-review-passed` when hold_risky (the review gate; money PRs ride this label too),
    `risky` needs `money-review-passed` (per label, any repo),
    and with require_passed (stall alert: "approved") every PR needs `ai-review-passed`.

CLI: python3 drain_eligible.py --mode drain|stall [--hold-risky]   (gh pr list --json number,mergeable,statusCheckRollup,isDraft,labels,headRefOid on stdin)
    drain: prints "<pr> <sha> <risky 0|1> <passed 0|1> <fixes-main 0|1> <money-gated 0|1>" for every PR whose classify is ok (drain.sh applies the hold itself)
    stall: prints the number of eligible PRs
    heal:  prints "<pr> <sha>" for every PR that would be drain-eligible except that some check ended CANCELLED/TIMED_OUT (G47: a run
           cancelled by main-first or a hung job is not a failure; a real FAILURE anywhere excludes the PR)
    main   (stdin: gh run list --json databaseId,headSha,status,conclusion,attempt, newest first; argv: --max-ahead N --ahead A)
           prints "<verdict> <sha9> <run-id> <attempt>": verdict is
             green | full (green but A >= N merges sit on top of the last green: wait for main CI to cover them) |
             red | pending (a main run is queued/in progress) | unverified (the newest main run was cancelled: needs a re-run, G74) | unknown
    runs   (stdin: gh run list --commit <sha> --json databaseId,workflowName,status,conclusion,attempt) prints "<id> <attempt>" for the latest
           run of every workflow on that head that ended cancelled/timed_out, provided every workflow on the head is completed
    starved --min N  (stdin: gh run list --commit <sha> --json databaseId,status,createdAt,attempt) prints "<id> <attempt>" for every run
           still queued after N minutes (DRAIN-STARVE-1: runners take the newest queued job first, so an old one can wait for hours)
    status-ok --context C --creators a,b --file F  (gh api repos/R/commits/<head sha>/statuses --paginate output) exit 0 ONLY when the newest status of that context on
           that exact head sha, created by an account in --creators, is `success` (Ruling MONEY-SHA-1; creators filtered first). Fail closed: an empty list, an error body (a dict with `message`), anything that is
           not a list of status objects, or a newest status that is not success, exits 1.
"""
import json
import sys

BAD = ("FAILURE", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR")


def _labels(pr):
    return {l.get("name") for l in pr.get("labels") or []}


def _check(c):
    st = c.get("status") or ("COMPLETED" if c.get("state") in ("SUCCESS", "FAILURE", "ERROR") else "PENDING")
    co = c.get("conclusion") or {"SUCCESS": "SUCCESS", "FAILURE": "FAILURE", "ERROR": "FAILURE"}.get(c.get("state"), "")
    return st, co


def classify(pr, strict=True):
    if pr.get("isDraft") or "hold" in _labels(pr):
        return "no"
    cs = pr.get("statusCheckRollup") or []
    if strict:
        if pr.get("mergeable") != "MERGEABLE" or not cs:
            return "no"
        for c in cs:
            st, co = _check(c)
            if st != "COMPLETED" or co in BAD:
                return "no"
        return "ok"
    if pr.get("mergeable") == "CONFLICTING":
        return "no"
    for c in cs:
        st, co = _check(c)
        if co in BAD:
            return "no"
    return "ok"


def needs_review(names):
    return "risky-path" in names or "risky" in names


def money_ok(names):
    """The money gate is unconditional (no flag, no repo): a `risky` PR never passes without `money-review-passed`."""
    return "risky" not in names or "money-review-passed" in names


def review_ok(names):
    """Required reviews AND together: risky-path needs ai-review-passed, risky needs money-review-passed, both labels need both."""
    return ("risky-path" not in names or "ai-review-passed" in names) and ("risky" not in names or "money-review-passed" in names)


def eligible(pr, hold_risky=True, strict=True, require_passed=False):
    if classify(pr, strict) != "ok":
        return False
    names = _labels(pr)
    if require_passed and "ai-review-passed" not in names:
        return False
    if not money_ok(names):
        return False
    if hold_risky and not review_ok(names):
        return False
    return True


def classify_heal(pr):
    """CANCELLED/TIMED_OUT-only red: all checks completed, none a real failure, at least one cancelled/timed out."""
    if pr.get("isDraft") or "hold" in _labels(pr) or pr.get("mergeable") == "CONFLICTING":
        return False
    cancelled = False
    for c in pr.get("statusCheckRollup") or []:
        st, co = _check(c)
        if st != "COMPLETED":
            return False
        if co in ("CANCELLED", "TIMED_OUT"):
            cancelled = True
        elif co in BAD:
            return False
    return cancelled


def main_verdict(runs, max_ahead, ahead):
    if not runs:
        return "unknown", "-", 0, 0
    first = runs[0]
    sha = (first.get("headSha") or "-")[:9]
    rid, att = first.get("databaseId") or 0, first.get("attempt") or 1
    if any(r.get("status") != "completed" for r in runs[:3]):
        return "pending", sha, rid, att
    if first.get("conclusion") == "cancelled":
        return "unverified", sha, rid, att
    if first.get("conclusion") != "success":
        return "red", sha, rid, att
    return ("full" if ahead >= max_ahead else "green"), sha, rid, att


def heal_runs(runs):
    by = {}
    for r in runs:
        by.setdefault(r.get("workflowName"), []).append(r)
    if any(x.get("status") != "completed" for rs in by.values() for x in rs):
        return []
    out = []
    for rs in by.values():
        last = max(rs, key=lambda x: x.get("databaseId") or 0)
        if last.get("conclusion") in ("cancelled", "timed_out"):
            out.append((last["databaseId"], last.get("attempt") or 1))
    return out


def _load_many(text):
    dec, i, out = json.JSONDecoder(), 0, []
    text = text.strip()
    while i < len(text):
        v, j = dec.raw_decode(text, i)
        out.extend(v if isinstance(v, list) else [v])
        i = j
        while i < len(text) and text[i].isspace():
            i += 1
    return out


def status_ok(context, data, creators):
    """True only when the newest status of `context` CREATED BY AN ALLOWED ACCOUNT is success. `data` is the parsed `statuses` response (a list, or
    several pages concatenated). Rows are filtered by creator FIRST and the newest of what is left wins: a PR's own workflow can post any status with
    GITHUB_TOKEN (creator github-actions[bot]), so a row from another creator neither approves nor overrides. An empty allow-list refuses. Anything
    unreadable is False: a gate that cannot read its evidence refuses."""
    allowed = {c for c in (creators or []) if c}
    if not allowed or not isinstance(data, list) or not data:
        return False
    rows = [r for r in data if isinstance(r, dict) and r.get("context") == context and isinstance(r.get("created_at"), str)
            and isinstance(r.get("creator"), dict) and r["creator"].get("login") in allowed]
    if not rows:
        return False
    newest = max(rows, key=lambda r: r["created_at"])
    return newest.get("state") == "success"


def starved_runs(runs, min_minutes, now=None):
    import calendar, time
    now = now if now is not None else time.time()
    out = []
    for r in runs:
        if r.get("status") != "queued":
            continue
        try:
            t = calendar.timegm(time.strptime(r["createdAt"], "%Y-%m-%dT%H:%M:%SZ"))
        except (KeyError, ValueError):
            continue
        if now - t > min_minutes * 60:
            out.append((r["databaseId"], r.get("attempt") or 1))
    return out


def main(argv):
    mode = argv[argv.index("--mode") + 1] if "--mode" in argv else ""
    hold = "--hold-risky" in argv
    if mode == "main":
        n = int(argv[argv.index("--max-ahead") + 1]); a = int(argv[argv.index("--ahead") + 1])
        print(*main_verdict(json.load(sys.stdin), n, a))
        return
    if mode == "starved":
        for rid, att in starved_runs(json.load(sys.stdin), float(argv[argv.index("--min") + 1])):
            print(rid, att)
        return
    if mode == "runs":
        for rid, att in heal_runs(json.load(sys.stdin)):
            print(rid, att)
        return
    if mode == "status-ok":
        arg = lambda k: argv[argv.index(k) + 1]
        try:
            data = _load_many(open(arg("--file")).read())
        except Exception:
            sys.exit(1)
        creators = [c.strip() for c in (arg("--creators") if "--creators" in argv else "").split(",")]
        sys.exit(0 if status_ok(arg("--context"), data, creators) else 1)
    prs = json.load(sys.stdin)
    if mode == "heal":
        for p in prs:
            if classify_heal(p):
                print(p["number"], p["headRefOid"])
    elif mode == "drain":
        for p in prs:
            if classify(p, True) == "ok":
                n = _labels(p)
                if not money_ok(n):
                    continue   # never offered to the drain, so it cannot merge even without --hold-risky
                # drain.sh holds (risky=1, passed=0) PRs; the verdict is review_ok(), the same function eligible() uses
                print(p["number"], p["headRefOid"], int(needs_review(n)), int(review_ok(n)), int("fixes-main" in n), int("risky" in n))
    elif mode == "stall":
        print(sum(1 for p in prs if eligible(p, hold_risky=True, strict=True, require_passed=True)))
    else:
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
