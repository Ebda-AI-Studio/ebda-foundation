#!/usr/bin/env bash
# Ebda OS — cloud-tier installer. Run ON the Oracle Free ARM VM (Ubuntu 22.04/24.04),
# NOT the Mac. Ports the OS watchdog tier from macOS launchd to systemd --user timers
# so it runs always-on, headless, surviving the Mac being asleep/off.
#
#   ssh ubuntu@<vm-ip>
#   sudo apt-get update && sudo apt-get install -y git
#   git clone https://github.com/$OS_REPO_SLUG.git ~/ebda-foundation
#   nano ~/.whisky-os/secrets.env   # (created on first run; fill it, then re-run)
#   bash ~/ebda-foundation/ops/cloud/cloud-install.sh
#
# Idempotent: re-run after a `git pull` to redeploy scripts + re-sync timers.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # ops/
REPO="$(cd "$SRC/.." && pwd)"                               # ebda-foundation/
OS_HOME="$HOME/.whisky-os"
BIN="$OS_HOME/bin"
STATE="$HOME/.whisky-os-state"
SECRETS="$OS_HOME/secrets.env"
UNIT_DIR="$HOME/.config/systemd/user"
MANIFEST="$SRC/cloud/jobs.manifest"

echo "== Ebda OS cloud-tier install =="
echo "repo: $REPO"

# 1. Deps (idempotent). gh + node + jq + python3 + git.
need_apt=0
for c in git jq python3 curl; do command -v "$c" >/dev/null 2>&1 || need_apt=1; done
if [ "$need_apt" = 1 ]; then
  echo "installing base packages…"
  sudo apt-get update -y
  sudo apt-get install -y git jq python3 curl ca-certificates
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "installing GitHub CLI…"
  (type -p wget >/dev/null || sudo apt-get install -y wget)
  sudo mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -y && sudo apt-get install -y gh
fi
if ! command -v node >/dev/null 2>&1; then
  echo "installing Node.js LTS…"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

# 2. Layout + secrets scaffold.
mkdir -p "$BIN" "$STATE" "$UNIT_DIR"
if [ ! -f "$SECRETS" ]; then
  install -m 600 /dev/null "$SECRETS"
  cat > "$SECRETS" <<'EOF'
# Ebda OS cloud-tier secrets — chmod 600, NEVER commit.
# Telegram (Whisky Whoop bot) — required for any --notify job:
TELEGRAM_BOT_TOKEN=
TELEGRAM_ALERT_CHAT_ID=
# GitHub — a fine-grained PAT (repo + actions:read) so gh works headless:
GH_TOKEN=
# Observability probe tokens (optional; jobs degrade gracefully if unset):
SENTRY_AUTH_TOKEN=
SENTRY_ORG=
UPTIMEROBOT_API_KEY=
RAILWAY_TOKEN=
GEMINI_API_KEY=
EOF
  echo
  echo ">> Created $SECRETS — FILL IT IN, then re-run this script."
  echo "   (Telegram token + chat id + a GitHub PAT are the minimum.)"
  exit 0
fi
# shellcheck disable=SC1090
set -a; . "$SECRETS"; set +a
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
  echo ">> $SECRETS is missing TELEGRAM_BOT_TOKEN and/or GH_TOKEN. Fill them, re-run." ; exit 1
fi

# The OS notify.sh reads $HOME/.whisky-whoop-telegram.env; bridge from secrets.env.
cat > "$HOME/.whisky-whoop-telegram.env" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ALERT_CHAT_ID=$TELEGRAM_ALERT_CHAT_ID
EOF
chmod 600 "$HOME/.whisky-whoop-telegram.env"
# Bridge observability tokens to the file services-watch/alert-triage read.
cat > "$OS_SERVICES_ENV" <<EOF
SENTRY_AUTH_TOKEN=${SENTRY_AUTH_TOKEN:-}
SENTRY_ORG=${SENTRY_ORG:-}
UPTIMEROBOT_API_KEY=${UPTIMEROBOT_API_KEY:-}
RAILWAY_TOKEN=${RAILWAY_TOKEN:-}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
EOF
chmod 600 "$OS_SERVICES_ENV"

# 3. Deploy runtime scripts (mirror ops/install.sh's set; cloud runs the watchdog tier).
echo "deploying scripts -> $BIN"
cp "$SRC/"*.sh "$BIN/" 2>/dev/null || true
mkdir -p "$BIN/lib"; cp "$SRC/lib/"*.sh "$BIN/lib/" 2>/dev/null || true
chmod +x "$BIN/"*.sh "$BIN/lib/"*.sh 2>/dev/null || true

# 4. Generate systemd --user service+timer per manifest line.
echo "generating systemd --user units from $MANIFEST"
# remove previously-generated units so removed manifest lines don't linger
find "$UNIT_DIR" -maxdepth 1 -name 'whisky-os-*.service' -delete 2>/dev/null || true
find "$UNIT_DIR" -maxdepth 1 -name 'whisky-os-*.timer'   -delete 2>/dev/null || true

# trim leading/trailing whitespace
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

gen_count=0
while IFS='|' read -r name schedule args; do
  name="$(trim "${name:-}")"
  case "$name" in ''|\#*) continue ;; esac
  schedule="$(trim "${schedule:-}")"; args="$(trim "${args:-}")"
  [ -f "$BIN/$name.sh" ] || { echo "  skip $name (no $name.sh)"; continue; }
  [ "$args" = "-" ] && args=""
  unit="whisky-os-$name"

  cat > "$UNIT_DIR/$unit.service" <<EOF
[Unit]
Description=Ebda OS — $name
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$HOME/.whisky-os/secrets.env
ExecStart=/usr/bin/env bash $BIN/$name.sh $args
EOF

  sched_kind="${schedule%%:*}"; sched_val="${schedule#*:}"
  if [ "$sched_kind" = "interval" ]; then
    on_clause="OnUnitActiveSec=${sched_val}"
    boot_clause="OnBootSec=120"
  else
    on_clause="OnCalendar=${sched_val}"
    boot_clause=""
  fi
  cat > "$UNIT_DIR/$unit.timer" <<EOF
[Unit]
Description=Ebda OS timer — $name

[Timer]
$boot_clause
$on_clause
Persistent=true

[Install]
WantedBy=timers.target
EOF
  gen_count=$((gen_count+1))
done < "$MANIFEST"

# 5. Enable lingering (run without an active login) + start all timers.
loginctl enable-linger "$USER" 2>/dev/null || true
systemctl --user daemon-reload
while IFS='|' read -r name schedule args; do
  name="$(trim "${name:-}")"
  case "$name" in ''|\#*) continue ;; esac
  [ -f "$BIN/$name.sh" ] || continue
  systemctl --user enable --now "whisky-os-$name.timer" 2>/dev/null || true
done < "$MANIFEST"

echo
echo "== installed $gen_count cloud-tier timers =="
systemctl --user list-timers 'whisky-os-*' --no-pager 2>/dev/null | head -20
echo
echo ">> ON THE MAC, unload the now-duplicated launchd jobs so alerts don't double-fire:"
echo "   for j in services-watch anomaly-watch alert-triage checkout-monitor wbs-monitor os-watch runner-hook-health ci-runner-guard cost-guard dream docs-scan; do"
echo "     launchctl bootout gui/\$(id -u)/${OS_LAUNCHD_PREFIX}.\$j 2>/dev/null; done"
echo "   KEEP on the Mac: ${OS_LAUNCHD_PREFIX}.neon-backup + ${OS_LAUNCHD_PREFIX}.mac-maintenance (Mac-local)."
