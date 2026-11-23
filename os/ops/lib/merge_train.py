#!/usr/bin/env python3
"""merge_train.py - pure state + ordering logic for ops/merge-train.sh (register OS-M1). No network, no gh.

  merge_train.py state FILE add PR [WAVE]     queue a PR (wave default 1)
  merge_train.py state FILE after PR DEP      PR waits until DEP has merged (DEP must be queued or already merged)
  merge_train.py state FILE prio PR N         higher N goes first inside a wave
  merge_train.py state FILE remove PR [merged]
  merge_train.py state FILE show              one line per PR in train order: PR wave prio blocked-by
  merge_train.py migcheck MAIN_NUMBERS_FILE   stdin lines "PR<TAB>path" -> prints every migration-number collision, exit 1 if any
Order: wave ascending, then priority descending, then PR number ascending. A PR is BLOCKED while a dependency is still queued.
"""
import json, os, re, sys

MIG = re.compile(r"(?:^|/)migrations?/(\d+)[_.-]")


def load(path):
    try:
        with open(path) as f:
            d = json.load(f)
        if not isinstance(d, dict):
            raise ValueError("not an object")
    except FileNotFoundError:
        d = {}
    d.setdefault("prs", {})      # "123": {"wave": 1, "prio": 0, "after": [..]}
    d.setdefault("merged", [])
    return d


def save(path, d):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def order(d):
    prs = d["prs"]
    rows = []
    for k, v in prs.items():
        blocked = [x for x in v.get("after", []) if x in prs]
        rows.append((int(v.get("wave", 1)), -int(v.get("prio", 0)), int(k), k, blocked))
    rows.sort()
    return [(r[3], r[0], -r[1], r[4]) for r in rows]


def state(argv):
    path, cmd, args = argv[0], argv[1], argv[2:]
    try:
        d = load(path)
    except Exception as e:
        sys.stderr.write("merge_train: unreadable state %s (%s) - refusing, fix or remove the file\n" % (path, e))
        return 3
    prs = d["prs"]
    if cmd == "add":
        prs.setdefault(args[0], {"wave": 1, "prio": 0, "after": []})
        if len(args) > 1:
            prs[args[0]]["wave"] = int(args[1])
    elif cmd == "after":
        pr, dep = args
        if pr not in prs:
            sys.stderr.write("merge_train: PR %s is not queued\n" % pr); return 2
        if dep not in prs and dep not in d["merged"]:
            sys.stderr.write("merge_train: dependency %s is neither queued nor merged\n" % dep); return 2
        if dep == pr or pr in prs.get(dep, {}).get("after", []):
            sys.stderr.write("merge_train: dependency cycle %s <-> %s\n" % (pr, dep)); return 2
        if dep not in prs[pr]["after"]:
            prs[pr]["after"].append(dep)
    elif cmd == "prio":
        if args[0] not in prs:
            sys.stderr.write("merge_train: PR %s is not queued\n" % args[0]); return 2
        prs[args[0]]["prio"] = int(args[1])
    elif cmd == "remove":
        prs.pop(args[0], None)
        if len(args) > 1 and args[1] == "merged" and args[0] not in d["merged"]:
            d["merged"].append(args[0])
    elif cmd == "show":
        for pr, wave, prio, blocked in order(d):
            print(pr, wave, prio, ",".join(blocked) or "-")
        return 0
    else:
        sys.stderr.write("merge_train: unknown state command %s\n" % cmd); return 2
    save(path, d)
    return 0


def migcheck(main_file):
    try:
        with open(main_file) as f:
            main = {l.strip() for l in f if l.strip()}
    except FileNotFoundError:
        main = set()
    seen = {}
    bad = 0
    for line in sys.stdin:
        pr, _, path = line.rstrip("\n").partition("\t")
        m = MIG.search(path)
        if not m:
            continue
        n = str(int(m.group(1)))
        if n in main:
            print("COLLISION migration %s (PR %s %s) already exists on main" % (n, pr, path)); bad = 1
        if n in seen and seen[n] != pr:
            print("COLLISION migration %s used by PR %s and PR %s" % (n, seen[n], pr)); bad = 1
        seen.setdefault(n, pr)
    return bad


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a[0] == "state":
            sys.exit(state(a[1:]))
        if a[0] == "migcheck":
            sys.exit(migcheck(a[1]))
    except (IndexError, ValueError):
        pass
    sys.stderr.write(__doc__)
    sys.exit(2)
