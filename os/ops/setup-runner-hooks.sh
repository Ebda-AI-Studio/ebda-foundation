#!/usr/bin/env bash
# Force AI — install/repair the self-hosted runner's post-job cleanup hook so it
# NEVER fails a job. Run this ON THE RUNNER HOST (the Umbra fwb-ci6 Ubuntu VM: umbra shell fwb-ci6 --), not macOS directly.
#
# Why: a post-job hook that exits non-zero fails the job at "Complete runner" after
# every real check passed → green code becomes un-mergeable. See
# template/runner-hooks/post-job-cleanup.sh + standard/cicd.md.
#
# Usage (on the host):
#   bash setup-runner-hooks.sh                 # patch the existing hook in place
#   HOOK=/home/ahmad/runner-hooks/post-job-cleanup.sh bash setup-runner-hooks.sh
#
# It is idempotent: re-running when already-wrapped is a no-op.
set -u

HOOK="${HOOK:-/home/$(whoami)/runner-hooks/post-job-cleanup.sh}"
HOOK_DIR="$(dirname "$HOOK")"
REAL="$HOOK_DIR/post-job-cleanup.real.sh"
MARKER="# Force AI best-effort wrapper"

echo "== Force AI runner-hook setup =="
echo "hook: $HOOK"

mkdir -p "$HOOK_DIR"

# 1. Diagnose the current hook (so we learn WHY it was failing, not just mask it).
if [ -f "$HOOK" ]; then
  if grep -q "$MARKER" "$HOOK" 2>/dev/null; then
    echo "Already wrapped (best-effort). Nothing to do."
    exit 0
  fi
  echo "--- current hook contents ---"
  cat "$HOOK"
  echo "--- manual run exit code ---"
  bash "$HOOK"; echo "exit=$?"
  echo "-----------------------------"
  # Preserve the existing logic as the 'real' hook (only if not already present).
  if [ ! -f "$REAL" ]; then
    cp "$HOOK" "$REAL"
    echo "Preserved existing logic -> $REAL"
  fi
fi

# 2. Write the best-effort wrapper. It runs $REAL (the preserved/host logic) but
#    can never fail the job.
cat > "$HOOK" <<EOF
#!/usr/bin/env bash
$MARKER — NEVER fail a job on cleanup. See ebda-foundation/standard/cicd.md.
set +e
REAL="$REAL"
[ -f "\$REAL" ] && bash "\$REAL" || true
exit 0
EOF
chmod +x "$HOOK"
[ -f "$REAL" ] && chmod +x "$REAL"

echo "Patched. The hook now always exits 0; cleanup still runs best-effort."
echo "No runner restart needed — the hook is read fresh per job."
