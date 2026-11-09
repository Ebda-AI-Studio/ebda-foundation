#!/usr/bin/env bash
# Whisky AI OS — one-command bring-up on a fresh Mac (e.g. the the Ebda Studio Mac).
#
#   git clone <foundation> && cd ebda-foundation && ./ops/bootstrap.sh
#
# Installs deps (brew + npm + uv + Claude Code), installs + schedules the OS
# (ops/install.sh — dynamic + portable, adapts to THIS machine's user/paths),
# then prints the manual auth + Apple-Business checklist. Idempotent.
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"

step(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

step "1/4  Homebrew formulae (ops/Brewfile)"
if command -v brew >/dev/null 2>&1; then
  brew bundle --file "$SRC/Brewfile" || echo "  (some brew items failed — review above)"
else
  echo "  Homebrew missing. Install: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" then re-run."
  exit 1
fi

step "2/4  non-brew CLIs (npm / uv / Claude Code)"
command -v npm  >/dev/null 2>&1 && npm  install -g wrangler @railway/cli 2>/dev/null && echo "  npm: wrangler @railway/cli" || echo "  npm missing — install node first"
command -v uv   >/dev/null 2>&1 && uv tool install graphifyy 2>/dev/null && echo "  uv: graphifyy (graphify)" || echo "  uv missing — brew install uv"
command -v claude >/dev/null 2>&1 || { echo "  installing Claude Code…"; curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null || echo "  install Claude Code manually: https://claude.ai/download"; }

step "3/4  install + schedule the OS (dynamic, portable)"
bash "$SRC/install.sh"

step "4/4  MANUAL — re-auth + Apple Business (nothing above logs you in)"
cat <<'EOF'
Re-authenticate on THIS machine (credentials never sync — re-login each):
  • claude /login                         (Max plan — powers claude -p, the OS's autonomous worker)
  • gh auth login                         (GitHub: the owner orgs in os.env)
  • wrangler login                        (Cloudflare Workers deploy/rollback)
  • railway login                         (Railway API deploy/rollback)
Copy the 2 secret files from the old Mac (scp), do NOT commit them:
  • ~/.whisky-services.env                (Sentry/UptimeRobot/PostHog/OneSignal/Railway/CF/R2/Gmail-IMAP tokens)
  • ~/.whisky-whoop-telegram.env          (the Whisky Whoop Telegram bot — how the OS reaches Ahmad)
Move the CLAUDE-HOME layer (rules, skills, memory, hooks — the brain config):
  • old Mac:  ops/migrate-claude-home.sh export      → ~/Desktop/claude-home-<date>.tgz
  • this Mac: ops/migrate-claude-home.sh import <tgz> (then claude /login + re-run ops/install.sh)
Verify:
  • bash ops/self-check.sh                (TCC + wiring guard)
  • ~/.claude/scripts/os-recall.sh senses (the OS's awareness map)
  • open http://127.0.0.1:7717            (command center — every subsystem tile)

Apple Business (make this Mac company-owned, off personal iCloud) — see ops/MIGRATION.md §Apple Business.
EOF
echo
echo "bootstrap complete."
