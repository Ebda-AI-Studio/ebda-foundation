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
case "$1" in
  list) [ -n "${FAKE_LOADED:-}" ] && printf '123\t0\t%s\n' "$FAKE_LOADED"; printf '%s\t0\t%s\n' 1 com.apple.fake; exit 0 ;;
  print) exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/launchctl"
export PATH="$T/bin:$PATH"
export EBDA_OS_LOCAL_ENV="$T/none.env"
want="$(grep -vcE '^(#|$)' "$ROOT/os/launchd/mac-local.list")"

H1="$T/h1"; mkdir -p "$H1"
out="$(bash "$INSTALL" --dry-run --home "$H1" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "dry-run exits 0" || { no "dry-run exits 0 (rc=$rc)"; echo "$out" | tail -5; }
n="$(printf '%s\n' "$out" | grep -ci 'forceai')"; [ "$n" = 0 ] && ok "dry-run output has 0 lines mentioning the old name" || no "dry-run mentions old name ($n)"
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
[ "$fail" = 0 ] && echo "install-dryrun: PASS" || echo "install-dryrun: FAIL"
exit "$fail"
