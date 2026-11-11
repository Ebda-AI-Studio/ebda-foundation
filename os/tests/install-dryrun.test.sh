#!/usr/bin/env bash
# os/install.sh: dry-run plan, symlink targets, Mac-local plist count, idempotence, and refusal while old-prefix jobs are loaded.
# Everything runs against a temp HOME with a stubbed launchctl; nothing touches the real ~/.claude or ~/Library.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/os/install.sh"
fail=0
ok() { echo "PASS: $1"; }; no() { echo "FAIL: $1"; fail=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
# stateful stub: a bootstrapped label is "loaded" (file under $LOADED_DIR holding the plist path) until a bootout removes it
L="${LOADED_DIR:-/nonexistent}"; label() { printf '%s' "${1##*/}"; }
case "$1" in
  list) [ -n "${FAKE_LOADED:-}" ] && printf '123\t0\t%s\n' "$FAKE_LOADED"; printf '%s\t0\t%s\n' 1 com.apple.fake; exit 0 ;;
  print) [ -f "$L/$(label "$2")" ] || exit 1; [ -n "${FAKE_PRINT_WRONG:-}" ] && { echo "path = /elsewhere/old.plist"; exit 0; }; echo "path = $(cat "$L/$(label "$2")")"; exit 0 ;;
  bootstrap) [ -n "${FAKE_BOOTSTRAP_FAIL:-}" ] && exit 5; [ -n "${FAKE_ALREADY_LOADED_FAILS:-}" ] && [ -f "$L/$(label "$3" | sed 's/\.plist$//')" ] && exit 5; [ -d "$L" ] && printf '%s' "$3" > "$L/$(label "$3" | sed 's/\.plist$//')"; exit 0 ;;
  bootout) [ -n "${FAKE_BOOTOUT_ERR:-}" ] && { echo "$FAKE_BOOTOUT_ERR" >&2; exit 5; }; rm -f "$L/$(label "$2")"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/launchctl"
mkdir -p "$T/loaded"; export LOADED_DIR="$T/loaded"
export PATH="$T/bin:$PATH"
export EBDA_OS_LOCAL_ENV="$T/none.env"
want="$(grep -vE '^(#|$)' "$ROOT/os/launchd/mac-local.list" | grep -vc $'\toptin=')"   # opt-in jobs are off by default (INSTALL-1)

H1="$T/h1"; mkdir -p "$H1"
out="$(bash "$INSTALL" --dry-run --home "$H1" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "dry-run exits 0" || { no "dry-run exits 0 (rc=$rc)"; echo "$out" | tail -5; }
n="$(printf '%s\n' "$out" | grep -ci "for""ceai")"; [ "$n" = 0 ] && ok "dry-run output has 0 lines mentioning the old name" || no "dry-run mentions old name ($n)"
[ -z "$(find "$H1" -type f 2>/dev/null)" ] && ok "dry-run wrote no files" || no "dry-run wrote files"
np="$(printf '%s\n' "$out" | grep -c '^bootstrap ')"; [ "$np" = "$want" ] && ok "dry-run plans $np bootstraps = Mac-local list ($want)" || no "bootstrap lines $np != $want"
lk="$(OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --dry-run --home "$H1" 2>&1 | grep '^link   .*/\.claude/\(agents\|skills\)/')"
bad=0; [ -n "$lk" ] || bad=1
while read -r _ _ _ tgt; do [ -z "$tgt" ] && continue; case "$tgt" in "$ROOT"/*) ;; *) bad=1; echo "  outside repo: $tgt" ;; esac; done <<< "$lk"
[ "$bad" = 0 ] && ok "every agents/skills symlink target is under the repo" || no "symlink target outside repo"

H2="$T/h2"; mkdir -p "$H2"
OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H2" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "real install into temp HOME exits 0" || no "real install rc=$rc"
cnt="$(ls "$H2/Library/LaunchAgents"/com.ebda.os.*.plist 2>/dev/null | wc -l | tr -d ' ')"
[ "$cnt" = "$want" ] && ok "installed plist count $cnt = Mac-local set" || no "plist count $cnt != $want"
grep -rl '__HOME__\|__PATH__\|__OS_HOME__' "$H2/Library/LaunchAgents" 2>/dev/null | grep -q . && no "unrendered tokens left" || ok "all plist tokens rendered"
bad=0; for l in "$H2"/.claude/agents/*.md "$H2"/.claude/skills/*; do [ -L "$l" ] || continue; case "$(readlink "$l")" in "$ROOT"/*) ;; *) bad=1 ;; esac; done
[ "$bad" = 0 ] && ok "installed symlinks all point into the repo" || no "installed symlink outside repo"
snap() { (cd "$H2" && find . -type f -exec cksum {} + | sort; find . -type l -exec sh -c 'echo "$1 $(readlink "$1")"' _ {} \; | sort; cat .gitconfig 2>/dev/null); }
a="$(snap)"; OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H2" >/dev/null 2>&1; b="$(snap)"
[ "$a" = "$b" ] && ok "second run changes nothing (idempotent)" || no "second run changed the tree"
# a stale plist from an older all-jobs install is removed
touch "$H2/Library/LaunchAgents/com.ebda.os.cost-guard.plist"
OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H2" >/dev/null 2>&1
[ ! -e "$H2/Library/LaunchAgents/com.ebda.os.cost-guard.plist" ] && ok "stale non-Mac-local plist removed" || no "stale plist kept"

H3="$T/h3"; mkdir -p "$H3"
msg="$(FAKE_LOADED="com.for""ceai.os-watch" bash "$INSTALL" --home "$H3" 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$msg" | grep -q 'os/cutover.sh' && ok "refuses with 'run os/cutover.sh' while an old-prefix label is loaded" || no "no refusal (rc=$rc)"
[ -z "$(find "$H3" -type f 2>/dev/null)" ] && ok "refusal wrote nothing" || no "refusal wrote files"
# a literal /Users/ path in any installed template breaks other users and --home installs
lit=""; for t in $(grep -vE '^(#|[[:space:]]*$)' "$ROOT/os/launchd/mac-local.list" | cut -f2); do lit="$lit$(grep -Hn '/Users/' "$ROOT/os/$t")"; done
[ -z "$lit" ] && ok "no template in the Mac-local set hard-codes /Users/" || { no "hard-coded /Users/ path"; echo "$lit"; }
lit2="$(grep -ln '/Users/' "$ROOT"/os/ops/launchd/*.plist 2>/dev/null)"
[ -z "$lit2" ] && ok "no plist template at all hard-codes /Users/" || no "hard-coded /Users/ in: $lit2"
# bootstrap failure must fail the install
H4="$T/h4"; mkdir -p "$H4"
FAKE_BOOTSTRAP_FAIL=1 bash "$INSTALL" --home "$H4" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "install exits non-zero when a bootstrap fails (rc=$rc)" || no "bootstrap failure ignored"
# hook-registration failure (unparseable settings.json) must fail the install
H5="$T/h5"; mkdir -p "$H5/.claude"; echo '{not json' > "$H5/.claude/settings.json"
bash "$INSTALL" --home "$H5" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "install exits non-zero when hook registration fails (rc=$rc)" || no "hook failure ignored"
# final review 9: a failed bootout + a failed bootstrap (the OLD definition is still loaded) must fail the install; so must a bootstrap that
# "succeeds" but leaves a different plist loaded
H7="$T/h7"; mkdir -p "$H7" "$T/loaded7"
LOADED_DIR="$T/loaded7" OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H7" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "stateful stub: a clean install still exits 0" || no "clean install with the stateful stub rc=$rc"
LA7="$H7/Library/LaunchAgents"; victim="$(ls "$LA7"/com.ebda.os.*.plist | head -1)"; echo "<!-- changed -->" >> "$victim"
LOADED_DIR="$T/loaded7" FAKE_ALREADY_LOADED_FAILS=1 FAKE_BOOTOUT_ERR="Boot-out failed: 5: Input/output error" OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H7" >"$T/h7.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "could not unload $(basename "$victim" .plist)" "$T/h7.out" && ok "failed bootout + loaded old job: install fails, names the job (rc=$rc)" || { no "bootout failure on a changed plist ignored (rc=$rc)"; tail -3 "$T/h7.out"; }
echo "<!-- changed again -->" >> "$victim"
LOADED_DIR="$T/loaded7" FAKE_PRINT_WRONG=1 OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H7" >"$T/h7b.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "not from the new plist" "$T/h7b.out" && ok "bootstrap ok but another plist is loaded: install fails (rc=$rc)" || { no "wrong loaded plist ignored (rc=$rc)"; tail -3 "$T/h7b.out"; }
# M-10: a stale plist whose job FAILS to unload is kept and fails the install; "not loaded" is fine and the plist goes
H6="$T/h6"; mkdir -p "$H6"
OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H6" >/dev/null 2>&1
touch "$H6/Library/LaunchAgents/com.ebda.os.stale-job.plist"
FAKE_BOOTOUT_ERR="Boot-out failed: 5: Input/output error" OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H6" >"$T/h6.out" 2>&1; rc=$?
[ -e "$H6/Library/LaunchAgents/com.ebda.os.stale-job.plist" ] && ok "stale plist KEPT when its job could not be unloaded" || no "plist removed although bootout failed"
[ "$rc" != 0 ] && grep -q "could not unload com.ebda.os.stale-job" "$T/h6.out" && ok "  ...and the install fails loudly (rc=$rc)" || no "bootout failure not reported (rc=$rc)"
FAKE_BOOTOUT_ERR="Boot-out failed: 3: No such process" OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H6" >/dev/null 2>&1; rc=$?
[ ! -e "$H6/Library/LaunchAgents/com.ebda.os.stale-job.plist" ] && [ "$rc" = 0 ] && ok "a job that was not loaded: plist removed, install clean" || no "not-loaded stale plist mishandled (rc=$rc)"
# INSTALL-1: an opt-in job (hands-mac-local) is skipped by default, installed with its flag, and removed again when the flag goes
grep -q $'^hands-mac-local\t.*\toptin=OS_HANDS_LOCAL$' "$ROOT/os/launchd/mac-local.list" && ok "hands-mac-local is opt-in (optin=OS_HANDS_LOCAL)" || no "hands-mac-local is not opt-in"
for j in claude-bundle-sync pr-shepherd sentry-stale-watch; do
  cut -f1 "$ROOT/os/launchd/mac-local.list" | grep -qxF "$j" && ok "$j is in the Mac-local set (not removed)" || no "$j missing from the Mac-local set"
done
H8="$T/h8"; mkdir -p "$H8" "$T/loaded8"
out8="$(LOADED_DIR="$T/loaded8" OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H8" 2>&1)"
[ ! -e "$H8/Library/LaunchAgents/com.ebda.os.hands-mac-local.plist" ] && printf '%s' "$out8" | grep -q 'skip   com.ebda.os.hands-mac-local (opt-in' && ok "hands-mac-local skipped without OS_HANDS_LOCAL" || no "hands-mac-local installed by default"
LOADED_DIR="$T/loaded8" OS_HANDS_LOCAL=1 OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H8" >/dev/null 2>&1
[ -e "$H8/Library/LaunchAgents/com.ebda.os.hands-mac-local.plist" ] && [ -f "$T/loaded8/com.ebda.os.hands-mac-local" ] && ok "OS_HANDS_LOCAL=1 installs and loads hands-mac-local" || no "opt-in did not install hands-mac-local"
LOADED_DIR="$T/loaded8" OS_LINK_ANY_CHECKOUT=1 bash "$INSTALL" --home "$H8" >/dev/null 2>&1
[ ! -e "$H8/Library/LaunchAgents/com.ebda.os.hands-mac-local.plist" ] && [ ! -f "$T/loaded8/com.ebda.os.hands-mac-local" ] && ok "dropping the opt-in unloads and removes hands-mac-local" || no "hands-mac-local kept after opt-out"
H9="$T/h9"; mkdir -p "$H9/os/launchd"
# a malformed flag column fails loudly instead of silently installing or skipping
cp -R "$ROOT/os" "$T/r9" 2>/dev/null; mkdir -p "$T/repo9"; mv "$T/r9" "$T/repo9/os"
printf 'x\tops/launchd/com.ebda.os.pr-shepherd.plist\tbogus\n' >> "$T/repo9/os/launchd/mac-local.list"
bash "$T/repo9/os/install.sh" --dry-run --home "$H9" >"$T/h9.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "unknown flag 'bogus'" "$T/h9.out" && ok "unknown mac-local.list flag fails the install (rc=$rc)" || { no "unknown flag accepted (rc=$rc)"; tail -2 "$T/h9.out"; }
[ "$fail" = 0 ] && echo "install-dryrun: PASS" || echo "install-dryrun: FAIL"
exit "$fail"
