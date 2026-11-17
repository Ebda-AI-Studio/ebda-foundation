#!/usr/bin/env bash
# Whisky AI OS — local dev services on apple/container (Docker Desktop replacement).
#
# Docker Desktop was removed 2026-09-07 and apple/container is the host engine. The repos'
# docker-compose.yml files are KEPT — CI still runs `docker compose` INSIDE the runners,
# where a Docker daemon exists. This script only replaces the LOCAL developer path on macOS.
#
# Profiles:
#   ebda   — postgres:16-alpine (5432) + redis:7-alpine (6379)
#            used by ebda-store and sibling repos (identical compose files: same
#            container names and ports, so they cannot run simultaneously).
#
# Usage:
#   ops/dev-services.sh <ebda> up
#   ops/dev-services.sh <ebda> down
#   ops/dev-services.sh <ebda> status
#
# Env (ebda profile; defaults match the compose files):
#   POSTGRES_USER=postgres  POSTGRES_PASSWORD=postgres  POSTGRES_DB=ebda_db
#   REDIS_PASSWORD=redis
#
# Data persists in named container volumes, so `down` does not lose your database.
# Exit codes: 0 ok, 1 usage/precondition, 2 a service failed to become reachable.
set -uo pipefail

PROFILE="${1:-}"; ACTION="${2:-}"
[ -n "$PROFILE" ] && [ -n "$ACTION" ] || { sed -n '1,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

command -v container >/dev/null || {
  echo "error: apple/container is not installed. See ~/Desktop/cutover-to-apple-container.sh" >&2
  exit 1
}
container system status >/dev/null 2>&1 || container system start >/dev/null 2>&1 || {
  echo "error: could not start the container system" >&2; exit 1; }

case "$PROFILE" in
  ebda)
    PG_NAME=ebda-postgres; RD_NAME=ebda-redis
    PG_IMAGE=docker.io/library/postgres:16-alpine
    RD_IMAGE=docker.io/library/redis:7-alpine
    PG_PORT=5432; RD_PORT=6379
    PG_USER="${POSTGRES_USER:-postgres}"; PG_PASS="${POSTGRES_PASSWORD:-postgres}"
    PG_DB="${POSTGRES_DB:-ebda_db}"; RD_PASS="${REDIS_PASSWORD:-redis}"
    ;;
  *) echo "error: unknown profile '$PROFILE' (expected: ebda)" >&2; exit 1 ;;
esac

running(){ grep -q . < <(container list 2>/dev/null | awk -v n="$1" '$1==n{print}'); }
exists(){ grep -q . < <( container list --all 2>/dev/null | awk -v n="$1" '$1==n{print}'); }
gone(){    exists "$1" && container delete -f "$1" >/dev/null 2>&1; return 0; }

wait_port(){ # $1=port $2=label
  for _ in $(seq 1 45); do nc -z 127.0.0.1 "$1" 2>/dev/null && { echo "  $2 ready on 127.0.0.1:$1"; return 0; }; sleep 2; done
  echo "  ERROR: $2 never accepted on 127.0.0.1:$1" >&2; return 1
}

case "$ACTION" in
  up)
    echo "starting '$PROFILE' services..."
    # Pre-flight: a NATIVE service on the port produces an opaque "Address already in use
    # (errno: 48)" from the container runtime. Name the occupant instead.
    for spec in "$PG_PORT:postgres" "$RD_PORT:$([ "$PROFILE" = ebda ] && echo redis || echo wsproxy)"; do
      port="${spec%%:*}"; label="${spec##*:}"
      if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1" (pid "$2")"}')
        echo "error: port $port for $label is already held by $holder" >&2
        echo "       On this Mac, Homebrew postgresql@17 owns 5432 and native redis owns 6379." >&2
        echo "       Stop it (brew services stop postgresql@17) or use a profile on free ports." >&2
        exit 1
      fi
    done
    container volume create "${PG_NAME}-data" >/dev/null 2>&1 || true
    gone "$PG_NAME"; gone "$RD_NAME"

    # PGDATA must be a SUBDIRECTORY of the mount: apple/container named volumes are real
    # formatted filesystems and arrive containing lost+found, which makes initdb refuse
    # ("directory exists but is not empty"). Docker's named volumes do not behave this way.
    container run --detach --name "$PG_NAME" \
      -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PASS" -e POSTGRES_DB="$PG_DB" \
      -e PGDATA=/var/lib/postgresql/data/pgdata \
      -v "${PG_NAME}-data:/var/lib/postgresql/data" \
      -p "127.0.0.1:${PG_PORT}:5432" "$PG_IMAGE" >/dev/null || { echo "postgres failed to start" >&2; exit 2; }

    if [ "$PROFILE" = ebda ]; then
      container run --detach --name "$RD_NAME" \
        -p "127.0.0.1:${RD_PORT}:6379" "$RD_IMAGE" \
        redis-server --appendonly yes --requirepass "$RD_PASS" >/dev/null \
        || { echo "redis failed to start" >&2; exit 2; }
    else
      # wsproxy proxies to whatever host the CLIENT names; it needs to reach postgres.
      # container has no inter-container DNS without `sudo container system dns create`,
      # so we hand it postgres's address explicitly and print it for your connection string.
      PGIP=$(container list 2>/dev/null | awk -v n="$PG_NAME" '$1==n{print $6}' | cut -d/ -f1)
      container run --detach --name "$RD_NAME" \
        -e APPEND_PORT=":5432" -e ALLOW_ADDR_REGEX=".*" -e LOG_TRAFFIC="true" \
        -p "127.0.0.1:${RD_PORT}:80" "$RD_IMAGE" >/dev/null \
        || { echo "wsproxy failed to start" >&2; exit 2; }
      echo "  postgres container IP: ${PGIP:-unknown}  (use this as the wsproxy target host)"
    fi

    rc=0
    wait_port "$PG_PORT" postgres || rc=2
    wait_port "$RD_PORT" "$([ "$PROFILE" = ebda ] && echo redis || echo wsproxy)" || rc=2
    [ $rc -eq 0 ] && echo "'$PROFILE' up." || echo "'$PROFILE' came up DEGRADED." >&2
    exit $rc
    ;;
  down)
    echo "stopping '$PROFILE' services (named volumes are preserved)..."
    gone "$PG_NAME"; gone "$RD_NAME"
    echo "'$PROFILE' down."
    ;;
  status)
    for n in "$PG_NAME" "$RD_NAME"; do
      if running "$n"; then echo "  $n: running"
      elif exists "$n"; then echo "  $n: stopped"
      else echo "  $n: absent"; fi
    done
    container list --all 2>/dev/null | head -5
    ;;
  *) echo "error: unknown action '$ACTION' (expected: up | down | status)" >&2; exit 1 ;;
esac
