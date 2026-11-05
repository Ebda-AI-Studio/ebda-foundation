#!/usr/bin/env bash
# Test findings-delta: key stability under LLM rewording, and notify gating.
set -euo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

LIB="$LIB" TMP="$TMP" python3 - <<'PY'
import importlib.util, json, os, sys

spec = importlib.util.spec_from_file_location("fd", os.path.join(os.environ["LIB"], "findings-delta.py"))
fd = importlib.util.module_from_spec(spec); spec.loader.exec_module(fd)
TMP = os.environ["TMP"]

_pass = _fail = 0
def eq(label, got, want):
    global _pass, _fail
    if got == want:
        print("PASS: %s" % label); _pass += 1
    else:
        print("FAIL: %s — got %r want %r" % (label, got, want)); _fail += 1

def F(repo, cls, path, title, sev="high"):
    return {"repo": repo, "class": cls, "severity": sev, "title": title,
            "sites": [{"file": path, "line": 1, "title": title}]}

# ── key stability: the whole point ───────────────────────────────────────────
a = F("fwb", "overcomplexity", "app/CheckoutClient.tsx",
      "CheckoutClient() is a 1794-line component with nesting depth 7 and 342 branches")
b = F("fwb", "overcomplexity", "app/CheckoutClient.tsx",
      "CheckoutClient() is a 1802-line component with nesting depth 7 and 351 branches")
eq("line-count drift keeps the key", fd.finding_key(a), fd.finding_key(b))

c = F("fwb", "overcomplexity", "app/CheckoutClient.tsx",
      "CheckoutClient() mixes delivery, coupons and payment in one component")
eq("LLM rewording keeps the key", fd.finding_key(a), fd.finding_key(c))

# Two findings in the SAME file must stay distinct, or one masks the other.
d = F("fwb", "overcomplexity", "app/CheckoutClient.tsx",
      "handleSubmit() is 365 lines with 95 branches")
assert fd.finding_key(a) != fd.finding_key(d)
eq("two symbols in one file stay distinct", True, True)

# Same symbol, different repo / class / file must not collide.
eq("repo separates", fd.finding_key(a) == fd.finding_key(
    F("wbs", "overcomplexity", "app/CheckoutClient.tsx", a["title"])), False)
eq("class separates", fd.finding_key(a) == fd.finding_key(
    F("fwb", "duplication", "app/CheckoutClient.tsx", a["title"])), False)
eq("file separates", fd.finding_key(a) == fd.finding_key(
    F("fwb", "overcomplexity", "app/Other.tsx", a["title"])), False)

# REGRESSION (found against the live 96-finding file): the engine emits titles
# like "complex function onKey() — 39 branches". Keying on the LEADING word
# collapsed every "complex function X()" in a file to the key "complex", so 96
# findings produced 95 keys and one finding was masked entirely.
k1 = fd.finding_key(F("gcc", "overcomplexity", "editor/screenshot-editor.tsx",
                      "complex function onKey() — 39 branches", "medium"))
k2 = fd.finding_key(F("gcc", "overcomplexity", "editor/screenshot-editor.tsx",
                      "complex function exportAll() — 126 lines, nesting depth 5, 22 branches", "medium"))
eq("'complex function X()' titles do not collide", k1 == k2, False)
eq("the called symbol is the key", k1.split("|")[-1], "onKey")
# The same function reported with and without the prose prefix is ONE finding.
eq("prefixed and bare titles agree",
   fd.finding_key(F("gcc", "overcomplexity", "e.tsx", "complex function onKey() — 39 branches")),
   fd.finding_key(F("gcc", "overcomplexity", "e.tsx", "onKey() has 41 branches")))
# Component-style titles have no parens and must still key on the component.
eq("paren-less component title keys on the component",
   fd.finding_key(F("wbs", "overcomplexity", "x.tsx", "WaOrderingClient is a 555-line component")).split("|")[-1],
   "WaOrderingClient")

# Prose titles (duplication findings) have no leading identifier.
p = F("gcc", "duplication", "apps/admin/x.ts", "API client boilerplate duplicated between apps")
eq("prose title still keys", isinstance(fd.finding_key(p), str) and len(fd.finding_key(p)) > 0, True)
# Two different prose findings in one file must stay distinct.
q = F("gcc", "duplication", "apps/admin/x.ts", "Settings-editor form boilerplate duplicated across 8 components")
eq("two prose titles stay distinct", fd.finding_key(p) == fd.finding_key(q), False)
# ...but a digit drift within one prose finding must not re-key it.
q2 = F("gcc", "duplication", "apps/admin/x.ts", "Settings-editor form boilerplate duplicated across 9 components")
eq("digit drift in a prose title keeps the key", fd.finding_key(q), fd.finding_key(q2))
# Malformed findings must key, not crash — a scan must never die on bad input.
eq("empty finding keys", isinstance(fd.finding_key({}), str), True)
eq("sites-less finding keys", isinstance(fd.finding_key({"repo": "r", "title": "X()"}), str), True)

# ── notify gating ────────────────────────────────────────────────────────────
base = [a, d]
seen_path = os.path.join(TMP, "seen.json")

# No baseline: must NOT notify, or shipping this announces the whole backlog.
r = fd.delta(base, fd.load_seen(seen_path))
eq("first run does not notify", r["notify"], False)
eq("first run is flagged", r["first_run"], True)

seen = fd.save_seen(seen_path, base, "2026-08-25T00:00:00")
eq("baseline persisted", len(seen), 2)

# Identical rerun: silent.
r = fd.delta(base, fd.load_seen(seen_path))
eq("identical rerun does not notify", r["notify"], False)
eq("identical rerun has no new", r["new_total"], 0)

# The actual noise case: same findings, LLM reworded, counts shifted. Silent.
r = fd.delta([b, d], fd.load_seen(seen_path))
eq("reworded rerun does not notify", r["notify"], False)

# A genuinely NEW high finding: notify.
n = F("fwb", "overcomplexity", "app/NewThing.tsx", "NewThing() is 900 lines", "high")
r = fd.delta(base + [n], fd.load_seen(seen_path))
eq("new high notifies", r["notify"], True)
eq("new high counted", r["new_high"], 1)

# A new CRITICAL also notifies.
crit = F("fwb", "overcomplexity", "app/Crit.tsx", "Crit() is enormous", "critical")
eq("new critical notifies", fd.delta(base + [crit], fd.load_seen(seen_path))["notify"], True)

# A new MEDIUM/LOW does not interrupt — it is on the dashboard either way.
med = F("fwb", "overcomplexity", "app/Med.tsx", "Med() is 200 lines", "medium")
r = fd.delta(base + [med], fd.load_seen(seen_path))
eq("new medium does not notify", r["notify"], False)
eq("new medium still counted as new", r["new_total"], 1)

# Findings disappearing is progress, not an interrupt.
r = fd.delta([a], fd.load_seen(seen_path))
eq("resolved counted", r["resolved"], 1)
eq("resolution alone does not notify", r["notify"], False)

# Everything clean.
r = fd.delta([], fd.load_seen(seen_path))
eq("all resolved does not notify", r["notify"], False)
eq("all resolved counts both", (r["resolved"], r["new_total"]), (2, 0))

# ── robustness ───────────────────────────────────────────────────────────────
# A corrupt baseline must read as NO baseline (and so stay silent), never as an
# empty set — an empty set would report every existing finding as brand new.
open(seen_path, "w").write("{ not json")
eq("corrupt baseline -> no baseline", fd.load_seen(seen_path), None)
eq("corrupt baseline does not notify", fd.delta(base, fd.load_seen(seen_path))["notify"], False)
eq("missing baseline -> None", fd.load_seen(os.path.join(TMP, "nope.json")), None)

# The write must be atomic: a crash mid-write must not leave a partial file.
fd.save_seen(seen_path, base, "2026-08-25T01:00:00")
eq("baseline rewritten after corruption", len(fd.load_seen(seen_path) or {}), 2)
eq("no temp files left behind",
   [f for f in os.listdir(TMP) if f.startswith(".findings-delta-")], [])

print()
print("%d passed, %d failed" % (_pass, _fail))
sys.exit(1 if _fail else 0)
PY
