. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/../../ops/remediation/pr-fix.sh"

# --- gr_excluded_path: string classifier ---
assert_eq "0" "$(gr_excluded_path 'src/auth/session.ts'; echo $?)" "auth path excluded"
assert_eq "0" "$(gr_excluded_path 'app/payment/checkout.ts'; echo $?)" "payment path excluded"
assert_eq "0" "$(gr_excluded_path 'prisma/migrations/001/migration.sql'; echo $?)" "migration path excluded"
assert_eq "0" "$(gr_excluded_path '.env.production'; echo $?)" "env file excluded"
assert_eq "0" "$(gr_excluded_path '.github/workflows/cf-deploy.yml'; echo $?)" "deploy workflow excluded"
assert_eq "1" "$(gr_excluded_path 'src/components/Card.tsx'; echo $?)" "plain component not excluded"
assert_eq "0" "$(gr_excluded_path 'src/rls/policy.ts'; echo $?)" "rls/policy path excluded"
assert_eq "0" "$(gr_excluded_path 'config/secrets.ts'; echo $?)" "secrets path excluded"
assert_eq "0" "$(gr_excluded_path 'migrations/0001_init.sql'; echo $?)" "root-level migrations excluded"
assert_eq "1" "$(gr_excluded_path 'src/components/AuthorBio.tsx'; echo $?)" "AuthorBio not excluded (no auth prefix collision)"
assert_eq "1" "$(gr_excluded_path 'src/pages/loginless.tsx'; echo $?)" "loginless not excluded (no login prefix collision)"
assert_eq "1" "$(gr_excluded_path 'docs/deployment-notes.md'; echo $?)" "deployment-notes doc not excluded"

# --- gr_touches_excluded: over a real diff ---
R="$(mktemp -d)"; git -C "$R" init -q
git -C "$R" config user.email t@e.co; git -C "$R" config user.name T
mkdir -p "$R/src"; echo 'export const a=1' > "$R/src/a.ts"
git -C "$R" add src/a.ts; git -C "$R" commit -qm base; git -C "$R" branch base
echo 'export const a=2' > "$R/src/a.ts"; git -C "$R" add src/a.ts; git -C "$R" commit -qm edit
assert_eq "1" "$(gr_touches_excluded "$R" base HEAD; echo $?)" "plain-file diff -> not excluded"
mkdir -p "$R/src/auth"; echo 'x' > "$R/src/auth/session.ts"
git -C "$R" add src/auth/session.ts; git -C "$R" commit -qm auth
assert_eq "0" "$(gr_touches_excluded "$R" base HEAD; echo $?)" "auth file in diff -> excluded"
# --- gr_diff_size: 2 files changed above already -> counts real lines ---
sz="$(gr_diff_size "$R" base HEAD)"
assert_eq "0" "$([ "$sz" -ge 2 ] && echo 0 || echo 1)" "diff size counts changed lines (>=2)"

# --- gr_adds_dependency: no manifest yet -> 1; add package.json -> 0 ---
assert_eq "1" "$(gr_adds_dependency "$R" base HEAD; echo $?)" "no manifest touched -> not a dep add"
echo '{"dependencies":{"left-pad":"1.0.0"}}' > "$R/package.json"
git -C "$R" add package.json; git -C "$R" commit -qm "add dep"
assert_eq "0" "$(gr_adds_dependency "$R" base HEAD; echo $?)" "package.json touched -> dep add"

# --- gr_unrelated: allowlist gating ---
# current HEAD touched src/a.ts, src/auth/session.ts, package.json vs base
assert_eq "1" "$(gr_unrelated "$R" base HEAD '[]'; echo $?)" "empty allowlist -> no constraint (nothing unrelated)"
assert_eq "0" "$(gr_unrelated "$R" base HEAD '["src/a.ts"]'; echo $?)" "files outside allowlist -> unrelated"

# --- guardrail_verdict: precedence excluded > dep > unrelated > oversize > ok ---
# The fixture diff touches an auth file AND package.json -> excluded wins.
assert_eq "REJECT excluded-path" "$(guardrail_verdict "$R" base HEAD '{}')" "excluded path wins"

# Fresh fixture: one plain small file -> OK
R2="$(mktemp -d)"; git -C "$R2" init -q
git -C "$R2" config user.email t@e.co; git -C "$R2" config user.name T
echo 'a' > "$R2/x.ts"; git -C "$R2" add x.ts; git -C "$R2" commit -qm base; git -C "$R2" branch base
printf 'a\nb\n' > "$R2/x.ts"; git -C "$R2" add x.ts; git -C "$R2" commit -qm edit
assert_eq "OK" "$(guardrail_verdict "$R2" base HEAD '{"files":["x.ts"]}')" "small in-scope plain diff -> OK"
# grow it past 150 lines -> OVERSIZE
python3 -c 'open("'"$R2"'/x.ts","w").write("\n".join(str(i) for i in range(200)))'
git -C "$R2" add x.ts; git -C "$R2" commit -qm big
assert_eq "OVERSIZE" "$(guardrail_verdict "$R2" base HEAD '{"files":["x.ts"]}')" ">150 lines -> OVERSIZE"
# dep add on an otherwise-clean small diff -> REJECT dependency-add
R3="$(mktemp -d)"; git -C "$R3" init -q
git -C "$R3" config user.email t@e.co; git -C "$R3" config user.name T
echo 'a' > "$R3/x.ts"; git -C "$R3" add x.ts; git -C "$R3" commit -qm base; git -C "$R3" branch base
echo '{"dependencies":{"p":"1"}}' > "$R3/package.json"; git -C "$R3" add package.json; git -C "$R3" commit -qm dep
assert_eq "REJECT dependency-add" "$(guardrail_verdict "$R3" base HEAD '{}')" "dep add -> reject"
rm -rf "$R2" "$R3"

# --- self_check: fake npm on PATH decides pass/fail ---
SCbin="$(mktemp -d)"; SCrepo="$(mktemp -d)"
echo '{"scripts":{"lint":"x","typecheck":"x"}}' > "$SCrepo/package.json"
# fake npm that passes everything
cat > "$SCbin/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCbin/npm"
assert_eq "0" "$(PATH="$SCbin:$PATH" self_check "$SCrepo"; echo $?)" "all scripts pass -> self_check 0"
# fake npm that fails on typecheck
cat > "$SCbin/npm" <<'EOF'
#!/usr/bin/env bash
[ "$2" = "typecheck" ] && exit 2
exit 0
EOF
chmod +x "$SCbin/npm"
assert_eq "1" "$(PATH="$SCbin:$PATH" self_check "$SCrepo"; echo $?)" "typecheck fails -> self_check 1"
# repo with no package.json -> nothing to check -> pass
NOPKG="$(mktemp -d)"
assert_eq "0" "$(PATH="$SCbin:$PATH" self_check "$NOPKG"; echo $?)" "no package.json -> self_check 0"
rm -rf "$SCbin" "$SCrepo" "$NOPKG"

# --- pr_fix: full loop with fakes (claude writes a diff, gh returns a PR, notify is stubbed) ---
export WHISKY_STATE_DIR="$(mktemp -d)"     # ledger state for queue_add/pending_add

_mk_repo() { # -> path to a git repo with an origin + main, on main
  local up d; up="$(mktemp -d)"; d="$(mktemp -d)"
  git -C "$up" init -q --bare
  git -C "$d" init -q; git -C "$d" config user.email t@e.co; git -C "$d" config user.name T
  git -C "$d" checkout -q -b main
  echo '{"scripts":{}}' > "$d/package.json"; echo 'export const a=1' > "$d/a.ts"
  git -C "$d" add package.json a.ts; git -C "$d" commit -qm base
  git -C "$d" remote add origin "$up"; git -C "$d" push -q -u origin main
  git -C "$d" remote set-head origin main 2>/dev/null
  printf '%s' "$d"
}

PFbin="$(mktemp -d)"
# fake gh: `gh pr create ...` -> prints a PR URL ending in a number; everything else no-op 0
cat > "$PFbin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"pr create"*) echo "https://github.com/Ebda-AI-Studio/x/pull/77";; esac
exit 0
EOF
chmod +x "$PFbin/gh"
# fake notify: record the call
NOTE="$(mktemp)"; cat > "$PFbin/notify.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTE"
EOF
chmod +x "$PFbin/notify.sh"

# fake claude that makes a SMALL in-scope edit to a.ts
cat > "$PFbin/claude" <<'EOF'
#!/usr/bin/env bash
echo 'export const a=2' > a.ts
EOF
chmod +x "$PFbin/claude"

# dry-run: no side effects
assert_eq "DRY" "$(REMEDIATE_DRYRUN=1 pr_fix '{"repo":"x","class":"code-health"}' "$(_mk_repo)")" "dry-run -> DRY, no side effects"

# OK path -> QUEUED
RQ="$(_mk_repo)"
out="$(PATH="$PFbin:$PATH" GH_CMD=gh REMEDIATE_NOTIFY="$PFbin/notify.sh" \
       pr_fix '{"repo":"x","class":"code-health","files":["a.ts"]}' "$RQ")"
assert_contains "QUEUED pr#77" "$out" "small in-scope fix -> QUEUED"
assert_eq "1" "$(queue_depth)" "OK path enqueued one item"
queue_pop >/dev/null

# claude makes an EXCLUDED-path edit -> REJECT, no PR, no queue
cat > "$PFbin/claude" <<'EOF'
#!/usr/bin/env bash
mkdir -p src/auth; echo 'x' > src/auth/session.ts
EOF
chmod +x "$PFbin/claude"
out2="$(PATH="$PFbin:$PATH" GH_CMD=gh REMEDIATE_NOTIFY="$PFbin/notify.sh" \
        pr_fix '{"repo":"x","class":"code-health"}' "$(_mk_repo)")"
assert_contains "REJECT excluded-path" "$out2" "excluded-path fix -> REJECT"
assert_eq "0" "$(queue_depth)" "REJECT path enqueues nothing"

# claude makes a >150-line edit -> PENDING + notify
cat > "$PFbin/claude" <<'EOF'
#!/usr/bin/env bash
python3 -c 'open("a.ts","w").write("\n".join(str(i) for i in range(200)))'
EOF
chmod +x "$PFbin/claude"
out3="$(PATH="$PFbin:$PATH" GH_CMD=gh REMEDIATE_NOTIFY="$PFbin/notify.sh" \
        pr_fix '{"repo":"x","class":"code-health","files":["a.ts"]}' "$(_mk_repo)")"
assert_contains "PENDING pr#77" "$out3" "oversize fix -> PENDING"
assert_contains "77" "$(pending_get 77)" "oversize fix stored in pending ledger"
assert_eq "0" "$([ -s "$NOTE" ] && echo 0 || echo 1)" "oversize fix pinged Telegram (notify called)"

# gh pr create fails (empty output) -> REJECT pr-create, nothing queued
cat > "$PFbin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$PFbin/gh"
cat > "$PFbin/claude" <<'EOF'
#!/usr/bin/env bash
echo 'export const a=2' > a.ts
EOF
chmod +x "$PFbin/claude"
out4="$(PATH="$PFbin:$PATH" GH_CMD=gh REMEDIATE_NOTIFY="$PFbin/notify.sh" \
        pr_fix '{"repo":"x","class":"code-health","files":["a.ts"]}' "$(_mk_repo)")"
assert_contains "REJECT pr-create" "$out4" "empty gh pr output -> REJECT pr-create"
assert_eq "0" "$(queue_depth)" "failed PR create enqueues nothing"

rm -rf "$PFbin" "$NOTE" "$WHISKY_STATE_DIR"

rm -rf "$R"
report
