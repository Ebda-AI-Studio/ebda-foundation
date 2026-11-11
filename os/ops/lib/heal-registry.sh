# shellcheck shell=bash
# lib/heal-registry.sh - the self-heal service registry, built from the per-machine ~/.ebda-os.local.json (never from git).
#   heal_registry_path   prints the registry JSON path: $HEAL_REG when set, else $OS_STATE_DIR/heal-registry.json built from
#                        the "heal_services" list. Prints nothing (and returns 1) when no services are configured.
# One list item per service, "|"-separated:  id|name|platform|health-url|expect|recovery|k=v,k=v
#   expect: HTTP code or "<500".  recovery: railway-redeploy | wrangler-rollback | db-prepare-recovery | escalate-only.
#   k=v extras: railway_project railway_service railway_env cf_worker db_project (whatever the recovery needs).
# Ebda-only (Ahmad 2026-11-06): the list holds Ebda/Whisky services; the predecessor's products are never registered.
heal_registry_path() {
  if [ -n "${HEAL_REG:-}" ]; then printf '%s' "$HEAL_REG"; [ -f "$HEAL_REG" ]; return; fi
  local out="${OS_STATE_DIR:-$HOME/.whisky-os-state}/heal-registry.json" items
  items="$(os_local_list heal_services 2>/dev/null)"
  [ -n "$items" ] || return 1
  mkdir -p "$(dirname "$out")" 2>/dev/null
  printf '%s\n' "$items" | python3 -I -c '
import json, sys
svcs = []
for line in sys.stdin.read().splitlines():
    p = line.split("|")
    if len(p) < 6: continue
    s = {"id": p[0], "name": p[1], "platform": p[2], "health": p[3], "expect": p[4], "recovery": p[5], "enabled": True}
    if len(p) > 6:
        for kv in p[6].split(","):
            if "=" in kv:
                k, v = kv.split("=", 1); s[k.strip()] = v.strip()
    svcs.append(s)
json.dump({"cooldown_sec": 600, "max_attempts": 3, "confirm_probes": 3, "services": svcs}, open(sys.argv[1], "w"), indent=2)
' "$out" || return 1
  printf '%s' "$out"
}

# heal_report <kind> <severity P1|P2|P3> <exhausted true|false> <service-id> <title> - hand a self-heal outcome to the brain as a
# finding (act, not ping). One per service per day (the brain dedupes by key). No message is sent from here.
heal_report() {
  local kind="$1" sev="$2" exh="$3" id="$4" title="$5" tmp
  command -v brain_post_findings >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  python3 -I -c '
import json, sys, datetime
kind, sev, exh, id, title = sys.argv[1:6]
print(json.dumps([{"source": "self-heal", "kind": kind, "key": id + "@" + datetime.date.today().isoformat(), "title": title[:480],
                    "severity": sev, "selfHealExhausted": exh == "true", "detail": {"service": id}}]))' "$kind" "$sev" "$exh" "$id" "$title" > "$tmp"
  brain_post_findings "$tmp" >/dev/null 2>&1
  rm -f "$tmp"
  return 0
}
