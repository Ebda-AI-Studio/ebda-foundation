#!/usr/bin/env bash
# Disk discipline: (1) global git post-checkout dispatcher, (2) PreToolUse install block, (3) PostToolUse worktree
# deps, (4) workspace-hygiene has no CI-VM step. Every gate has its NEGATIVE case (a guard that cannot be made to
# fail is not evidence). Fully isolated: temp HOME, stub wt-deps. Run: bash ops/lib/__tests__/disk-discipline.test.sh
set -uo pipefail
OPS="$(cd "$(dirname "$0")/../.." && pwd)"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/Library/Logs"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main

# APFS clonefile (cp -c) exists on the dev Mac only; Linux CI cannot exercise the clone path, so those cases SKIP visibly
echo x > "$T/.p1"; if cp -c "$T/.p1" "$T/.p2" 2>/dev/null; then APFS=1; else APFS=0; echo "NOTE: no APFS clonefile on this host - clone-path cases are SKIPPED (they run on the dev Mac)"; fi

# ---- stub wt-deps: records calls; "--check" answers per $T/hit ----
cat > "$T/wtd.sh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--check" ]; then [ -f "$T/hit" ]; exit \$?; fi
echo "\$@" >> "$T/wtd.calls"; echo "stub clone done"
STUB
chmod +x "$T/wtd.sh"; export WT_DEPS_BIN="$T/wtd.sh" WT_MIN_FREE_GB=0 WT_TRUST_LIB="$OPS/lib/trusted-origin.sh" WT_TRUST_ROOT="$T"

# ---- global dispatcher wired exactly like install.sh does ----
GH="$HOME/.claude/git-hooks"; mkdir -p "$GH"; cp "$OPS/git-hooks/dispatch.sh" "$GH/"; chmod +x "$GH/dispatch.sh"
for h in pre-commit post-checkout pre-push commit-msg; do ln -sfn dispatch.sh "$GH/$h"; done
git config --global core.hooksPath "$GH"

mkrepo() { rm -rf "$1"; git init -q "$1"; (cd "$1" && echo '{"name":"x"}' > package.json && echo '{}' > package-lock.json && git add package.json package-lock.json && git commit -qm init && git remote add origin "https://github.com/Whisky-11/$(basename "$1").git"); }

# ============ 1. dispatcher ============
R="$T/plain"; mkrepo "$R"
: > "$T/wtd.calls"
git -C "$R" worktree add -q "$T/plain-wt" -b feat/a 2>/dev/null
grep -q "plain-wt" "$T/wtd.calls" && ok "new worktree (raw git worktree add) triggers wt-deps" || no "new worktree triggers wt-deps"
: > "$T/wtd.calls"; git -C "$T/plain-wt" checkout -q -b feat/b; git -C "$R" checkout -q -b other; git -C "$R" checkout -q main
[ ! -s "$T/wtd.calls" ] && ok "ordinary branch switches do NOT trigger wt-deps" || no "ordinary checkout triggered wt-deps"
: > "$T/wtd.calls"; git clone -q "$R" "$T/cloned" 2>/dev/null
[ ! -s "$T/wtd.calls" ] && ok "git clone does NOT trigger wt-deps" || no "clone triggered wt-deps"
: > "$T/wtd.calls"; WT_SKIP_DEPS=1 git -C "$R" worktree add -q "$T/skip-wt" -b feat/skip 2>/dev/null
[ ! -s "$T/wtd.calls" ] && ok "WT_SKIP_DEPS=1 opts out" || no "WT_SKIP_DEPS ignored"

# SECURITY: a worktree of a repo with an UNTRUSTED origin gets no automatic install from the git hook
: > "$T/wtd.calls"; git -C "$R" remote set-url origin https://github.com/attacker/x.git
git -C "$R" worktree add -q "$T/untrusted-wt" -b feat/untrusted 2>/dev/null
[ ! -s "$T/wtd.calls" ] && ok "SECURITY: untrusted-origin repo: git hook installs nothing" || no "git hook ran wt-deps for an untrusted origin"
git -C "$R" remote set-url origin https://github.com/Whisky-11/plain.git

# chaining: the repo's own .git/hooks/pre-commit still runs and its exit code still gates the commit
printf '#!/bin/sh\necho ran >> "%s/precommit.ran"\nexit 1\n' "$T" > "$R/.git/hooks/pre-commit"; chmod +x "$R/.git/hooks/pre-commit"
echo y > "$R/f"; git -C "$R" add f
git -C "$R" commit -qm blocked 2>/dev/null; rc=$?
[ "$rc" -ne 0 ] && [ -f "$T/precommit.ran" ] && ok "chains to .git/hooks/pre-commit and propagates its failure" || no "repo pre-commit not chained (rc=$rc)"
printf '#!/bin/sh\nexit 0\n' > "$R/.git/hooks/pre-commit"
git -C "$R" commit -qm passes 2>/dev/null && ok "chained hook exit 0 lets the commit through" || no "commit blocked by a passing hook"

# chaining: husky layout WITHOUT a local core.hooksPath (global applies) still runs .husky/pre-commit
H="$T/husky"; mkrepo "$H"; mkdir -p "$H/.husky"; printf 'echo husky-ran >> "%s/husky.ran"\nexit 1\n' "$T" > "$H/.husky/pre-commit"
echo z > "$H/g"; git -C "$H" add g; git -C "$H" commit -qm x 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ ! -f "$T/husky.ran" ] && ok "SECURITY: husky NOT run without per-repo opt-in" || no "husky ran without opt-in (rc=$rc)"
git -C "$H" config --local ebda.chainHusky true; git -C "$H" commit -qm x 2>/dev/null; rc=$?
[ "$rc" -ne 0 ] && [ -f "$T/husky.ran" ] && ok "opted-in repo: chains to .husky/pre-commit and propagates failure" || no "opted-in husky not chained (rc=$rc)"

# SECURITY: a fresh CLONE of a repo with a malicious tracked .husky/post-checkout executes nothing
EV="$T/evil-src"; mkrepo "$EV"; mkdir -p "$EV/.husky"; printf 'echo pwned > "%s/pwned"\n' "$T" > "$EV/.husky/post-checkout"; chmod +x "$EV/.husky/post-checkout"
printf '#!/bin/sh\necho pwned > "%s/pwned"\n' "$T" > "$EV/.husky/pre-commit"; chmod +x "$EV/.husky/pre-commit"
git -C "$EV" add .husky; git -C "$EV" commit -qm evil; rm -f "$T/pwned"
git clone -q "$EV" "$T/evil-clone" 2>/dev/null; git -C "$T/evil-clone" checkout -q -b x 2>/dev/null; git -C "$T/evil-clone" worktree add -q "$T/evil-wt" -b y 2>/dev/null
echo q > "$T/evil-clone/q"; git -C "$T/evil-clone" add q; git -C "$T/evil-clone" commit -qm q 2>/dev/null
[ ! -e "$T/pwned" ] && ok "SECURITY: clone/checkout/worktree/commit of an untrusted repo with .husky executes nothing" || no "malicious .husky RAN"
# and a repo's own node_modules/.bin is never on PATH for chained hooks
grep -v '^[[:space:]]*#' "$OPS/git-hooks/dispatch.sh" | grep -q 'node_modules/.bin' && no "dispatcher references node_modules/.bin" || ok "dispatcher never touches the repo's node_modules/.bin"

# stdin passes through (pre-push gets ref lines on stdin)
printf '#!/bin/sh\ncat > "%s/push.stdin"\nexit 0\n' "$T" > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
git init -q --bare "$T/remote.git"; git -C "$R" push -q "$T/remote.git" main 2>/dev/null
[ -s "$T/push.stdin" ] && ok "stdin reaches the chained pre-push hook" || no "stdin lost through the dispatcher"

# low disk + cache MISS: refuse to start a fresh install (negative case); cache HIT: still clones
: > "$T/wtd.calls"; rm -f "$T/hit"
WT_MIN_FREE_GB=99999 git -C "$R" worktree add -q "$T/low-wt" -b feat/low 2>/dev/null
[ ! -s "$T/wtd.calls" ] && ok "below the free-disk floor + cache miss: no install started" || no "install started below the floor"
: > "$T/wtd.calls"; touch "$T/hit"
WT_MIN_FREE_GB=99999 git -C "$R" worktree add -q "$T/low-wt2" -b feat/low2 2>/dev/null
grep -q low-wt2 "$T/wtd.calls" && ok "below the floor + cache HIT: clone still happens" || no "clone refused on a hit below the floor"

# ============ 1a. one anchored validator ============
. "$OPS/lib/trusted-origin.sh"
for u in https://github.com/Whisky-11/x.git https://github.com/Ebda-AI-Studio/x git@github.com:voidengineer-911/x.git ssh://git@github.com/Whisky-11/x.git https://github.com/Whisky-11/x/; do
  wt_trusted_origin_url "$u" && ok "trusted origin accepted: $u" || no "trusted origin rejected: $u"
done
for u in https://evil.com/github.com/Whisky-11/x git@evil:github.com/Ebda-AI-Studio/x https://github.com.evil.tld/Whisky-11/x https://github.com@evil.tld/Whisky-11/x \
         'https://evil.tld/x?github.com/Whisky-11/y' https://github.com/Whisky-111/x https://github.com/attacker/Whisky-11/x https://github.com/Whisky-11/x/y/z http://github.com/Whisky-11/x '' ssh://git@evil.tld/github.com/Ebda-AI-Studio/y; do
  wt_trusted_origin_url "$u" && no "EVIL origin accepted: '$u'" || ok "evil origin rejected: '$u'"
done
mkdir -p "$T/real/Whisky-11x"; ln -sfn "$T/real" "$T/projects-link"
# symlink out of the trust root: resolved real path decides
mkrepo "$T/real/linked"; ln -sfn "$T/real/linked" "$T/linkedsym"
( WT_TRUST_ROOT="$T/projects" ; mkdir -p "$T/projects"; wt_trusted_repo "$T/linkedsym" ) && no "symlink escape trusted" || ok "repo reached via symlink outside the trust root is NOT trusted"

# ============ 1b. wt-deps HOOK MODE trust gate (real wt-deps.sh, stub npm) ============
BIN="$T/bin"; mkdir -p "$BIN"; printf '#!/bin/sh\necho "$@" >> "%s/npm.calls"; mkdir -p node_modules/pkg; echo x > node_modules/pkg/i.js\n' "$T" > "$BIN/npm"; chmod +x "$BIN/npm"
TR="$T/projects"; mkdir -p "$TR"; export WT_DEPS_CACHE="$T/cache"
trust_case() { # $1 name  $2 origin url  $3 under-root(1/0)
  local d; if [ "$3" = 1 ]; then d="$TR/$1"; else d="$T/outside-$1"; fi
  mkrepo "$d"; git -C "$d" remote set-url origin "$2"; : > "$T/npm.calls"
  (cd "$d" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$d" >/dev/null 2>&1); echo $?
}
trust_case evil https://evil.tld/github.com/Whisky-11/repo 1 >/dev/null; [ ! -s "$T/npm.calls" ] && ok "SECURITY: untrusted origin gets NO automatic install" || no "install ran for untrusted origin"
trust_case outside https://github.com/Whisky-11/x.git 0 >/dev/null; [ ! -s "$T/npm.calls" ] && ok "SECURITY: trusted org but outside ~/Desktop/projects gets no install" || no "install ran outside the trust root"
trust_case mine https://github.com/Whisky-11/mine.git 1 >/dev/null; [ ! -s "$T/npm.calls" ] && ok "SECURITY: trusted repo, cache MISS: hook mode runs NO installer (clone-only)" || no "installer ran from a hook: $(cat "$T/npm.calls")"
# a deliberate (non-hook) install fills the cache; a second worktree of the same repo then CLONES in hook mode
MI="$TR/mine"; : > "$T/npm.calls"; (cd "$MI" && PATH="$BIN:$PATH" bash "$OPS/wt-deps.sh" "$MI" >/dev/null 2>&1)
git -C "$MI" worktree add -q "$TR/mine-wt" -b feat/m 2>/dev/null; : > "$T/npm.calls"
(cd "$TR/mine-wt" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$TR/mine-wt" >/dev/null 2>&1)
if [ "$APFS" = 1 ]; then [ ! -s "$T/npm.calls" ] && [ -f "$TR/mine-wt/node_modules/pkg/i.js" ] && ok "trusted repo, cache HIT: hook mode clones node_modules, no installer" || no "hook clone failed"
else [ ! -s "$T/npm.calls" ] && ok "SKIP(no APFS): hook clone-HIT case; still asserted: no installer ran" || no "installer ran without APFS"; fi
# hostile project config / hostile lockfile: hook mode REFUSES (nothing runs)
HN="$TR/npmrcrepo"; mkrepo "$HN"; git -C "$HN" remote set-url origin https://github.com/Whisky-11/npmrcrepo.git; printf 'script-shell=/tmp/evil\ngit=/tmp/evil\n' > "$HN/.npmrc"; : > "$T/npm.calls"
(cd "$HN" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$HN" >/dev/null 2>&1); [ ! -s "$T/npm.calls" ] && ok "SECURITY: hostile project .npmrc cannot influence anything (hook mode never installs)" || no "install ran despite .npmrc"
GL="$TR/gitdep"; mkrepo "$GL"; git -C "$GL" remote set-url origin https://github.com/Whisky-11/gitdep.git; printf '{"packages":{"node_modules/x":{"resolved":"git+ssh://git@evil.tld/x.git#abc"}}}' > "$GL/package-lock.json"; : > "$T/npm.calls"
(cd "$GL" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$GL" >/dev/null 2>&1); [ ! -s "$T/npm.calls" ] && ok "SECURITY: hook mode refuses git/file/tarball-URL dependencies in the lockfile" || no "install ran despite a git dependency"
printf '{"packages":{"node_modules/x":{"resolved":"https://evil.tld/x.tgz"}}}' > "$GL/package-lock.json"; : > "$T/npm.calls"
(cd "$GL" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$GL" >/dev/null 2>&1); [ ! -s "$T/npm.calls" ] && ok "SECURITY: hook mode refuses a non-registry tarball URL" || no "install ran despite a tarball URL"
# path traversal: newline-in-name dir and a symlinked node_modules are never followed/copied (normal mode, real miss path)
printf '#!/bin/sh\nmkdir -p node_modules/ok "evil\n../../escaped/node_modules"; echo x > node_modules/ok/i; mkdir -p "%s/outside"; echo secret > "%s/outside/s"; mkdir -p sub; ln -s "%s/outside" sub/node_modules\n' "$T" "$T" "$T" > "$BIN/npm"
TV="$T/trav"; mkrepo "$TV"; (cd "$TV" && PATH="$BIN:$PATH" bash "$OPS/wt-deps.sh" "$TV" >/dev/null 2>&1)
M="$(cat "$T"/cache/trav/*/manifest 2>/dev/null)"
grep -q '\.\.' <<<"$M" && no "manifest kept a '..' entry" || ok "newline-in-name dir (escape via '..') is dropped from the manifest"
grep -q 'sub/node_modules' <<<"$M" && no "symlinked node_modules listed" || ok "symlinked node_modules pointing outside is not snapshotted"
[ ! -e "$T/escaped" ] && ok "nothing created outside the worktree/cache" || no "escape dir created"
find "$T/cache/trav" -name s 2>/dev/null | grep -q . && no "outside file copied into cache" || ok "outside symlink target never copied into the cache"

printf '#!/bin/sh\necho "$@" >> "%s/npm.calls"; mkdir -p node_modules/pkg; echo x > node_modules/pkg/i.js\n' "$T" > "$BIN/npm"   # restore the recording stub
# every fallback in hook mode exits WITHOUT running an installer: force clone_in to fail via a symlinked parent in the worktree
printf '#!/bin/sh\necho "$@" >> "%s/npm.calls"; mkdir -p node_modules/pkg packages/a/node_modules/z; echo x > node_modules/pkg/i.js\n' "$T" > "$BIN/npm"
SY="$TR/sy"; mkrepo "$SY"; (cd "$SY" && PATH="$BIN:$PATH" bash "$OPS/wt-deps.sh" "$SY" >/dev/null 2>&1)
git -C "$SY" worktree add -q "$TR/sy-wt" -b feat/sy 2>/dev/null; mkdir -p "$T/symout"; ln -s "$T/symout" "$TR/sy-wt/packages"; : > "$T/npm.calls"
(cd "$TR/sy-wt" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$TR/sy-wt" >/dev/null 2>&1); rc=$?
[ ! -s "$T/npm.calls" ] && [ "$rc" -eq 0 ] && [ -z "$(ls -A "$T/symout")" ] && ok "SECURITY: hook-mode clone failure (symlinked parent) runs NO installer and writes nothing outside" || no "clone-failure fallback ran an installer or escaped (rc=$rc)"
# probe failure (cache dir unwritable) in hook mode
: > "$T/npm.calls"; XC="$TR/xc"; mkrepo "$XC"; (cd "$XC" && PATH="$BIN:$PATH" bash "$OPS/wt-deps.sh" "$XC" >/dev/null 2>&1); git -C "$XC" worktree add -q "$TR/xc-wt" -b feat/xc 2>/dev/null; : > "$T/npm.calls"
chmod 555 "$T/cache/xc"; (cd "$TR/xc-wt" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$TR/xc-wt" >/dev/null 2>&1); chmod 755 "$T/cache/xc"
[ ! -s "$T/npm.calls" ] && ok "SECURITY: hook-mode probe/cache-dir failure runs NO installer" || no "installer ran on probe failure"
printf '#!/bin/sh\necho "$@" >> "%s/npm.calls"; mkdir -p node_modules/pkg; echo x > node_modules/pkg/i.js\n' "$T" > "$BIN/npm"
PN="$TR/pnpmrepo"; mkrepo "$PN"; rm -f "$PN/package-lock.json"; echo 'lockfileVersion: 9' > "$PN/pnpm-lock.yaml"; : > "$T/npm.calls"
printf '#!/bin/sh\necho pnpm "$@" >> "%s/npm.calls"\n' "$T" > "$BIN/pnpm"; chmod +x "$BIN/pnpm"
(cd "$PN" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$PN" >/dev/null 2>&1); [ ! -s "$T/npm.calls" ] && ok "SECURITY: hook mode never runs pnpm/yarn (repo-controlled pnpmfile/yarnPath)" || no "pnpm ran in hook mode"
D="$TR/nolock"; mkrepo "$D"; rm -f "$D/package-lock.json"; git -C "$D" remote set-url origin https://github.com/Whisky-11/n.git; : > "$T/npm.calls"
(cd "$D" && PATH="$BIN:$PATH" WT_DEPS_HOOK=1 WT_TRUST_ROOT="$TR" bash "$OPS/wt-deps.sh" "$D" >/dev/null 2>&1); [ ! -s "$T/npm.calls" ] && ok "hook mode never runs a bare npm install without a lockfile" || no "bare install in hook mode"

# ============ 1c. cache prune keeps the NEWEST keys and never wipes the repo cache dir ============
printf '#!/bin/sh\nmkdir -p node_modules/pkg; echo x > node_modules/pkg/i.js\n' > "$BIN/npm"
PR="$TR/prunerepo"; mkrepo "$PR"; export WT_DEPS_KEEP=2
for v in 1 2 3; do echo "{\"name\":\"x\",\"v\":$v}" > "$PR/package.json"; echo "{\"v\":$v}" > "$PR/package-lock.json"; rm -rf "$PR/node_modules"; (cd "$PR" && PATH="$BIN:$PATH" bash "$OPS/wt-deps.sh" "$PR" >/dev/null 2>&1); sleep 1; done
n=$(ls -d "$T"/cache/prunerepo/*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$APFS" != 1 ]; then ok "SKIP(no APFS): prune-keeps-newest case (cache is only written on APFS)"
elif [ "$n" = 2 ] && ls "$T"/cache/prunerepo/*/.complete >/dev/null 2>&1; then ok "prune keeps exactly KEEP=2 complete keys after 3 installs (repo cache dir survives)"
else no "prune wrong: $n entries"; fi
unset WT_DEPS_KEEP

# ============ 2. PreToolUse install block ============
G="$OPS/hooks/block-worktree-install.sh"
cmdp() { python3 -c "import json,sys;print(json.dumps({'tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':sys.argv[2]}}))" "$1" "$2"; }
WT="$T/plain-wt"; touch "$T/hit"
printf '%s' "$(cmdp "$WT" 'npm ci')" | bash "$G" >/dev/null 2>&1; [ $? -eq 2 ] && ok "deny npm ci in a worktree on a cache hit" || no "npm ci not denied on hit"
printf '%s' "$(cmdp "$WT" 'cd /tmp && cd '"$WT"' && pnpm install --frozen-lockfile')" | bash "$G" >/dev/null 2>&1; [ $? -eq 2 ] && ok "deny pnpm install after cd into the worktree" || no "pnpm install after cd not denied"
printf '%s' "$(cmdp "$WT" 'yarn')" | bash "$G" >/dev/null 2>&1; [ $? -eq 2 ] && ok "deny bare yarn on a hit" || no "bare yarn not denied"
msg="$(printf '%s' "$(cmdp "$WT" 'npm install')" | bash "$G" 2>&1 >/dev/null)"; grep -q "wt-deps" <<<"$msg" && ok "deny message points at wt-deps" || no "deny message missing wt-deps"
rm -f "$T/hit"
printf '%s' "$(cmdp "$WT" 'npm ci')" | bash "$G" >/dev/null 2>&1; [ $? -eq 0 ] && ok "ALLOW npm ci on a cache MISS (genuine lockfile change)" || no "npm ci blocked on a miss"
touch "$T/hit"
printf '%s' "$(cmdp "$WT" 'npm install zod')" | bash "$G" >/dev/null 2>&1; [ $? -eq 0 ] && ok "allow npm install <pkg> (adding a dependency)" || no "npm install <pkg> blocked"
printf '%s' "$(cmdp "$R" 'npm ci')" | bash "$G" >/dev/null 2>&1; [ $? -eq 0 ] && ok "allow in the main checkout (not a worktree)" || no "main checkout blocked"
printf '%s' "$(cmdp "$WT" 'WT_ALLOW_INSTALL=1 npm ci')" | bash "$G" >/dev/null 2>&1; [ $? -eq 0 ] && ok "WT_ALLOW_INSTALL=1 escape hatch" || no "escape hatch ignored"
printf '%s' "$(cmdp "$WT" 'git commit -m "npm ci"')" | bash "$G" >/dev/null 2>&1; [ $? -eq 0 ] && ok "allow 'npm ci' inside a quoted commit message" || no "false positive on quoted text"
printf 'not json' | bash "$G" >/dev/null 2>&1; [ $? -eq 0 ] && ok "malformed payload does not block" || no "malformed payload blocked"

# ============ 3. PostToolUse worktree deps (covers husky repos, whose own hooksPath bypasses the global hook) ============
P="$OPS/hooks/post-worktree-deps.sh"
: > "$T/wtd.calls"
NEW="$T/hk-wt"; git -C "$R" worktree add -q --no-checkout "$NEW" -b feat/hk 2>/dev/null; git -C "$NEW" checkout -q feat/hk 2>/dev/null || true
: > "$T/wtd.calls"
printf '%s' "$(cmdp "$R" "git worktree add $NEW -b feat/hk")" | bash "$P" >/dev/null 2>&1
grep -q "hk-wt" "$T/wtd.calls" && ok "PostToolUse: 'git worktree add <path>' runs wt-deps on the new path" || no "PostToolUse did not run wt-deps"
: > "$T/wtd.calls"
printf '%s' "$(cmdp "$R" 'git status')" | bash "$P" >/dev/null 2>&1
[ ! -s "$T/wtd.calls" ] && ok "PostToolUse: unrelated Bash command is ignored" || no "PostToolUse fired on git status"
python3 -c "import json,sys;print(json.dumps({'tool_name':'EnterWorktree','cwd':sys.argv[1],'tool_input':{},'tool_response':{'worktreePath':sys.argv[2]}}))" "$R" "$NEW" | bash "$P" >/dev/null 2>&1
grep -q "hk-wt" "$T/wtd.calls" && ok "PostToolUse: EnterWorktree response path runs wt-deps" || no "EnterWorktree not handled"

# ============ 4. workspace-hygiene no longer touches any CI VM (Umbra retired 2026-11-14) ============
if ! grep -qiE 'umbra|safe_umbra_prune' "$OPS/workspace-hygiene.sh"; then ok "workspace-hygiene has no VM-trim step"; else no "workspace-hygiene still references umbra"; fi

echo; echo "disk-discipline: $_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
