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
    drain: prints "<pr> <sha> <risky 0|1> <passed 0|1>" for every PR whose classify is ok (drain.sh applies the hold itself)
    stall: prints the number of eligible PRs
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


def eligible(pr, hold_risky=True, strict=True, require_passed=False):
    if classify(pr, strict) != "ok":
        return False
    names = _labels(pr)
    if require_passed and "ai-review-passed" not in names:
        return False
    if hold_risky and "risky-path" in names and "ai-review-passed" not in names:
        return False
    # money gate, per LABEL not per repo: a PR carrying `risky` needs the Opus money reviewer's `money-review-passed`
    if hold_risky and "risky" in names and "money-review-passed" not in names:
        return False
    return True


def main(argv):
    mode = argv[argv.index("--mode") + 1] if "--mode" in argv else ""
    hold = "--hold-risky" in argv
    prs = json.load(sys.stdin)
    if mode == "drain":
        for p in prs:
            if classify(p, True) == "ok":
                n = _labels(p)
                # drain.sh holds (risky=1, passed=0) PRs: `risky` is held until money-review-passed, `risky-path` until ai-review-passed
                money = "risky" in n
                print(p["number"], p["headRefOid"], int("risky-path" in n or money),
                      int(("money-review-passed" in n) if money else ("ai-review-passed" in n)) if money else int("ai-review-passed" in n))
    elif mode == "stall":
        print(sum(1 for p in prs if eligible(p, hold_risky=True, strict=True, require_passed=True)))
    else:
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
