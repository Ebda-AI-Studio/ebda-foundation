#!/usr/bin/env bash
#
# pending.sh — deferred approval queue for side-effecting autonomous actions.
#
# WHY THIS EXISTS
# ---------------
# Whisky OS remediation is binary today: autonomy ON means a watcher acts
# unsupervised on production; autonomy OFF (/kill) means it only notifies. There
# is no middle setting, so the practical choice has been "let it loose" or "do it
# all by hand" — which is why /kill exists at all.
#
# Cloudflare OS's Gatekeepers solve exactly this, and their framing is the
# reason this file exists (cloudflare/cloudflare-os, Apache-2.0):
#
#   "Traditionally, human-in-the-loop setups require the human to approve
#    actions *synchronously*... you give your agent a task, then walk away and
#    get a coffee, only to come back and find the agent got stuck on an approval
#    on the first step. As a result, people often give in and set their agents to
#    auto-approve, or --dangerously-skip-permissions, which is, obviously, unsafe."
#
# Their fix: the gatekeeper SIMULATES the action, lets the agent continue, and
# the human approves in bulk later. This is the Whisky OS version of that: a
# watcher that wants to do something irreversible ENQUEUES it instead of firing
# it, keeps going, and Ahmad approves or rejects from Telegram whenever he likes.
#
# We deliberately do NOT simulate return values — Cloudflare needs that because
# their agent reads results back mid-run. Our watchers are fire-and-forget shell
# actions, so recording the intent is enough and simulation would be a lie we'd
# have to maintain.
#
# Usage (from any watcher):
#   . "$HOME/.claude/scripts/lib/pending.sh"
#   pending_enqueue "cors-fix" "Fix CORS allowlist on ebda-api" "bash /path/fix.sh"
#
# Then from Telegram: /pending, /approve <n|all>, /reject <n|all>

STATE_DIR="${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}"
PENDING_FILE="$STATE_DIR/pending-actions.jsonl"

mkdir -p "$STATE_DIR"

# pending_enqueue <kind> <title> <command>
# Records an intent instead of executing it. Deduplicates on kind+title so a
# watcher firing every 15 minutes does not enqueue 96 copies a day.
pending_enqueue() {
  local kind="$1" title="$2" cmd="$3"
  python3 - "$PENDING_FILE" "$kind" "$title" "$cmd" <<'PY'
import json, sys, os, datetime
path, kind, title, cmd = sys.argv[1:5]
rows = []
if os.path.exists(path):
    with open(path) as f:
        for line in f:
            try: rows.append(json.loads(line))
            except Exception: pass
# Dedupe: same kind+title still awaiting a decision = already queued.
for r in rows:
    if r.get("kind") == kind and r.get("title") == title and r.get("state") == "pending":
        r["seen"] = r.get("seen", 1) + 1
        r["last_seen"] = datetime.datetime.now().isoformat(timespec="seconds")
        with open(path, "w") as f:
            for x in rows: f.write(json.dumps(x, ensure_ascii=False) + "\n")
        sys.exit(0)
rows.append({
    "id": (max([r.get("id", 0) for r in rows]) + 1) if rows else 1,
    "kind": kind, "title": title, "cmd": cmd, "state": "pending", "seen": 1,
    "queued_at": datetime.datetime.now().isoformat(timespec="seconds"),
})
with open(path, "w") as f:
    for x in rows: f.write(json.dumps(x, ensure_ascii=False) + "\n")
PY
}

# pending_list — human-readable, for Telegram
pending_list() {
  python3 - "$PENDING_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
rows = []
if os.path.exists(path):
    with open(path) as f:
        for line in f:
            try: rows.append(json.loads(line))
            except Exception: pass
p = [r for r in rows if r.get("state") == "pending"]
if not p:
    print("✅ Nothing pending approval."); sys.exit(0)
print(f"⏸ {len(p)} action(s) awaiting approval:\n")
for r in p:
    seen = f" ·seen {r['seen']}x" if r.get("seen", 1) > 1 else ""
    print(f"[{r['id']}] {r['title']}\n     {r['kind']} · queued {r['queued_at'][5:16]}{seen}\n     $ {r['cmd'][:110]}\n")
print("/approve <n|all>   /reject <n|all>")
PY
}

# pending_decide <approve|reject> <id|all>  -> prints a summary; runs cmds on approve
pending_decide() {
  local action="$1" target="$2"
  python3 - "$PENDING_FILE" "$action" "$target" <<'PY'
import json, os, sys, subprocess, datetime
path, action, target = sys.argv[1:4]
rows = []
if os.path.exists(path):
    with open(path) as f:
        for line in f:
            try: rows.append(json.loads(line))
            except Exception: pass
sel = [r for r in rows if r.get("state") == "pending" and (target == "all" or str(r.get("id")) == target)]
if not sel:
    print(f"Nothing pending matching '{target}'."); sys.exit(0)
out = []
for r in sel:
    if action == "approve":
        # Run it for real. rc is recorded so an approved-but-failed action is
        # visible rather than assumed done.
        pr = subprocess.run(["bash", "-lc", r["cmd"]], capture_output=True, text=True, timeout=900)
        r["state"] = "approved"; r["rc"] = pr.returncode
        r["output"] = (pr.stdout + pr.stderr)[-400:]
        out.append(f"{'✅' if pr.returncode == 0 else '❌'} [{r['id']}] {r['title']} (rc={pr.returncode})")
    else:
        r["state"] = "rejected"; out.append(f"🚫 [{r['id']}] {r['title']}")
    r["decided_at"] = datetime.datetime.now().isoformat(timespec="seconds")
with open(path, "w") as f:
    for x in rows: f.write(json.dumps(x, ensure_ascii=False) + "\n")
print("\n".join(out))
PY
}

# pending_status_json — writes the Ops tile so the queue is visible in Force AI Ops
pending_status_json() {
  python3 - "$PENDING_FILE" "$STATE_DIR/pending-status.json" <<'PY'
import json, os, sys, datetime
src, dst = sys.argv[1:3]
rows = []
if os.path.exists(src):
    with open(src) as f:
        for line in f:
            try: rows.append(json.loads(line))
            except Exception: pass
pend = [r for r in rows if r.get("state") == "pending"]
failed = [r for r in rows if r.get("state") == "approved" and r.get("rc")]
ok = "true" if not pend and not failed else ("warn" if pend else "false")
json.dump({
    "ok": ok,
    "summary": (f"{len(pend)} awaiting approval" if pend else "nothing pending")
               + (f" · {len(failed)} approved-but-failed" if failed else ""),
    "detail": {
        "pending": len(pend), "approved_failed": len(failed),
        "total_ever": len(rows),
        "oldest_pending": (pend[0]["queued_at"] if pend else None),
        "titles": [r["title"][:70] for r in pend[:6]],
    },
    "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(dst, "w"), indent=1)
PY
}
