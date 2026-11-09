#!/usr/bin/env bash
# Weekly auto-refresh for registered ecosystem-research domains.
#
# Each registered domain (in reference-ecosystem-research-registry.md) is
# re-mined via `claude -p` running the ecosystem-research skill in
# --mechanical mode (Gemini-bulk + Sonnet-synthesis, ~$0.05 per run).
# The skill itself diffs against the existing cache so only NET-NEW
# pitfalls trigger a memory write.
#
# Hard rules (from ~/.claude/CLAUDE.md "Practical hard rules"):
# - SERIALIZE: one `claude -p` worker at a time. Never parallel.
# - Skip domains whose cache mtime is <7 days.
# - Log every run + exit code to ~/.claude/logs/ecosystem-research-cron.log.
# - Failures do NOT stop the loop — next domain still runs.
#
# Usage:
#   bash ~/.claude/scripts/ecosystem-research-cron.sh            # run a refresh pass now
#   bash ~/.claude/scripts/ecosystem-research-cron.sh --install  # install launchd plist (weekly Sun 04:00)
#   bash ~/.claude/scripts/ecosystem-research-cron.sh --uninstall
#   bash ~/.claude/scripts/ecosystem-research-cron.sh --status   # print last-run + registered domain ages

set -uo pipefail
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

REGISTRY="$HOME/.claude/projects/-Users-ahmadsharaf/memory/reference-ecosystem-research-registry.md"
CACHE_DIR="$HOME/.claude/projects/-Users-ahmadsharaf/memory/ecosystem-research"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/ecosystem-research-cron.log"
PLIST_PATH="$HOME/Library/LaunchAgents/com.ahmad.ecosystem-research.plist"
PLIST_LABEL="com.ahmad.ecosystem-research"
MAX_AGE_SECONDS=$((7 * 24 * 60 * 60))  # 7 days

mkdir -p "$LOG_DIR" "$CACHE_DIR"

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE"; }

# ───────────────────────────── install / uninstall / status ────────────

install_plist() {
    if [[ ! -x "$(command -v claude 2>/dev/null)" ]]; then
        echo "✗ claude CLI not on PATH. Aborting install." >&2
        exit 1
    fi
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${HOME}/.claude/scripts/ecosystem-research-cron.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>0</integer>
        <key>Hour</key><integer>4</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"
    echo "✓ Installed launchd plist: $PLIST_PATH"
    echo "  Runs weekly: Sundays at 04:00 local"
    echo "  Log: $LOG_FILE"
}

uninstall_plist() {
    if [[ -f "$PLIST_PATH" ]]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo "✓ Uninstalled launchd plist"
    else
        echo "  (no plist installed at $PLIST_PATH — nothing to do)"
    fi
}

show_status() {
    echo "── Ecosystem Research Cron Status ──"
    echo "Registry: $REGISTRY"
    echo "Cache dir: $CACHE_DIR"
    echo "Log: $LOG_FILE"
    echo
    if [[ -f "$PLIST_PATH" ]]; then
        echo "✓ launchd plist installed"
        launchctl list | grep "$PLIST_LABEL" || echo "  (loaded but not in launchctl list — may need user-session reload)"
    else
        echo "✗ launchd plist NOT installed (run with --install)"
    fi
    echo
    if [[ -d "$CACHE_DIR" ]]; then
        echo "── Cached domains (age in days) ──"
        for f in "$CACHE_DIR"/*.md; do
            [[ -e "$f" ]] || continue
            local slug=$(basename "$f" .md)
            local mtime_s=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
            local age_d=$(( ($(date +%s) - mtime_s) / 86400 ))
            printf "  %-50s %3dd\n" "$slug" "$age_d"
        done
    fi
    echo
    if [[ -f "$LOG_FILE" ]]; then
        echo "── Last 10 log lines ──"
        tail -n 10 "$LOG_FILE"
    fi
}

# ──────────────────────────── refresh pass ─────────────────────────────

# Extract domains from the registry. Format expected: lines starting with
# "- `<domain string>`" (single backticks). Robust to other markdown
# content in the file.
extract_domains() {
    [[ -f "$REGISTRY" ]] || { log "registry missing: $REGISTRY"; return; }
    grep -oE '^- `[^`]+`' "$REGISTRY" 2>/dev/null | sed -E 's/^- `(.*)`$/\1/'
}

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

cache_age_seconds() {
    local f="$1"
    [[ -f "$f" ]] || { echo "999999999"; return; }
    local mtime_s
    mtime_s=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
    echo $(( $(date +%s) - mtime_s ))
}

run_refresh_for_domain() {
    local domain="$1"
    local slug
    slug=$(slugify "$domain")
    local cache="$CACHE_DIR/${slug}.md"
    local age
    age=$(cache_age_seconds "$cache")

    if (( age < MAX_AGE_SECONDS )); then
        log "skip  '$domain' (cache age $((age/86400))d < 7d)"
        return 0
    fi

    log "refresh '$domain' (cache age $((age/86400))d)  → claude -p --mechanical"

    # The --mechanical flag is interpreted by the ecosystem-research skill.
    # Bound runtime at 20 minutes — if claude -p hangs past that, kill it
    # and move on. Macros: gtimeout if coreutils installed, perl fallback.
    local out
    if command -v gtimeout >/dev/null 2>&1; then
        out=$(gtimeout 1200 "$CLAUDE_BIN" -p "/ecosystem-research $domain --mechanical --refresh" 2>&1)
    else
        out=$(perl -e 'alarm 1200; exec @ARGV' "$CLAUDE_BIN" -p "/ecosystem-research $domain --mechanical --refresh" 2>&1)
    fi
    local rc=$?

    if (( rc == 0 )); then
        log "    ✓ ok"
    else
        log "    ✗ failed (rc=$rc) — first 5 lines:"
        echo "$out" | head -5 | sed 's/^/      /' | tee -a "$LOG_FILE"
    fi

    return 0  # never stop the loop on a single failure
}

run_pass() {
    log "=== weekly refresh pass start ==="
    local domains
    domains=$(extract_domains)
    if [[ -z "$domains" ]]; then
        log "registry empty — nothing to refresh. Add domains via '/ecosystem-research register <domain>'."
        log "=== pass done (empty) ==="
        return 0
    fi
    local count=0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        run_refresh_for_domain "$d"
        count=$((count+1))
        # Serialize: small gap between claude -p workers (lets API rate-limits breathe)
        sleep 5
    done <<< "$domains"
    log "=== pass done ($count domains processed) ==="
}

# ──────────────────────────── main ─────────────────────────────────────

case "${1:-}" in
    --install)   install_plist ;;
    --uninstall) uninstall_plist ;;
    --status)    show_status ;;
    "")          run_pass ;;
    *)           echo "Unknown flag: $1" >&2; exit 2 ;;
esac
