#!/usr/bin/env bash
# dead-gate-detect.sh — closes gap G9 (2026-07-22 audit).
#
# The failure class: a remediation gated on `command -v <bin>` silently STOPS
# running the day <bin> is uninstalled/retired — it fails OPEN (skips), no error.
# The `mac-maintenance` runner-prune was DEAD 10 days this way (gated on the
# retired `orb`), so the 58GB-ENOSPC guard silently stopped. Same family as the
# OrbStack stale-advice bug and [[self-heal-credit-verified-recovery-not-post-state]].
#
# This watcher scans every OS script for real `command -v <bin>` guards (in CODE,
# not comments) and flags any guarded binary that is (a) NOT installed and (b)
# NOT a shell function/builtin defined in the OS itself — i.e. an external tool
# the code thinks it can call but can't. Read-only. Notifies on findings.
#
# Whitelist genuinely-optional bins via DEAD_GATE_IGNORE (space-separated) in
# ~/.whisky-services.env — tools that are SUPPOSED to be absent on some boxes.
#
# SECOND CLASS (added 2026-09-04): an UNREGISTERED HOOK. This detector was blind
# to the deadest gate of all — a hook script that exists, is documented as a hook,
# and is wired to nothing. ops/self-eval-gate.sh had been in that state, firing
# never, while reading as coverage. Scripts declare themselves with a marker line
# `# claude-hook: <Event>`; this checks each declaration against the actual
# registrations in ~/.claude/settings.json. A declaration with no registration is
# a finding. (A comment-text heuristic was tried first and produced false
# positives on runner-hook-health.sh and migrate-claude-home.sh — hence a marker.)
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE="$HOME/.claude/scripts"
STATE="$HOME/.whisky-os-state"; LOG="$STATE/dead-gate.log"; mkdir -p "$STATE"
NOTIFY="$HERE/notify.sh"
ts(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now; }
. "$HERE/lib/os-state.sh" 2>/dev/null || true   # write_status, if present

# Scan roots: the deployed runtime + (if present) the foundation ops source.
ROOTS=("$HERE")
[ -n "${DEAD_GATE_ROOT:-}" ] && ROOTS=("$DEAD_GATE_ROOT")   # test seam
[ -z "${DEAD_GATE_ROOT:-}" ] && [ -d "$OS_HOME/os/ops" ] && ROOTS+=("$OS_HOME/os/ops")

IGNORE="${DEAD_GATE_IGNORE:-}"
[ -z "$IGNORE" ] && [ -f "$OS_SERVICES_ENV" ] && IGNORE="$(grep -E '^DEAD_GATE_IGNORE=' "$OS_SERVICES_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"')"

# One python pass: for every *.sh under the roots, find `command -v <bin>` in the
# CODE portion of each line (text before an unquoted '#'), collect (bin,file,line).
# Then filter: drop bins that are installed, are shell functions defined anywhere
# in the OS scripts, are shell builtins, or are on the ignore list.
HITS=()
while IFS= read -r _hit; do [ -n "$_hit" ] && HITS+=("$_hit"); done < <(HERE="$HERE" ROOTS="${ROOTS[*]}" IGNORE="$IGNORE" python3 - <<'PY'
import os, re, subprocess, glob, shutil
roots = os.environ["ROOTS"].split()
ignore = set(os.environ.get("IGNORE","").split())
guard_re = re.compile(r'command\s+-v\s+([A-Za-z0-9_.\-]+)')

def code_part(line):
    # strip a trailing shell comment: first '#' that is not inside quotes and
    # not a ${var#...}/${var##...}/$# parameter form. Good-enough heuristic.
    out=[]; q=None; i=0
    while i < len(line):
        c=line[i]
        if q:
            out.append(c)
            if c==q: q=None
        elif c in ('"',"'"):
            q=c; out.append(c)
        elif c=='#':
            prev = line[i-1] if i>0 else ' '
            if prev in (' ','\t',';','&','|','(',')'):  # a real comment start
                break
            out.append(c)      # $#, ${x#...} etc — keep
        else:
            out.append(c)
        i+=1
    return ''.join(out)

# gather candidate (bin,file,line)
# False-positive classes (2026-11-20), each skipped on purpose:
#  - a `_retired*` dir: code that is deliberately dead is not a dead gate
#  - a tests/ line that echoes/prints the guard: a fixture asserting the guard is ABSENT (e.g. no-gdate)
#  - an elif/else branch whose earlier `if/elif command -v X` guards a tool that IS installed: the
#    later branch is a fallback that never needed to run (host-lock: lockf, then flock)
cands=[]   # (bin,file,lineno)
allfiles=set()
branch_re = re.compile(r'^(\s*)(if|elif)\b')
def earlier_branch_installed(lines, idx):
    """True if line idx is inside an elif whose earlier if/elif branch guards an installed binary."""
    m = branch_re.match(lines[idx])
    if not m or m.group(2) != 'elif':
        return False
    indent = m.group(1)
    j = idx - 1
    while j >= 0:
        mj = branch_re.match(lines[j])
        if mj and mj.group(1) == indent:
            for g in guard_re.finditer(code_part(lines[j])):
                if shutil.which(g.group(1)):
                    return True
            if mj.group(2) == 'if':
                return False
        j -= 1
    return False
for r in roots:
    for f in glob.glob(os.path.join(r,'**','*.sh'), recursive=True):
        allfiles.add(f)
        parts = f.split(os.sep)
        if any(p.startswith('_retired') for p in parts):
            continue
        in_tests = 'tests' in parts
        try: txt=open(f,encoding='utf-8',errors='replace').read().splitlines()
        except Exception: continue
        # a test that builds its fixtures in a mktemp dir carries guard text as DATA (this detector's own
        # test too): its `command -v` lines are fixtures, not live gates
        if in_tests and any('mktemp' in l for l in txt):
            continue
        for n,line in enumerate(txt,1):
            if in_tests and re.match(r'^\s*(\{\s*)?(echo|printf|cat)\b', line):
                continue
            for m in guard_re.finditer(code_part(line)):
                b=m.group(1)
                if earlier_branch_installed(txt, n-1):
                    continue
                cands.append((b,f,n))

# A guarded name is a FUNCTION (not a binary) only if `name()` / `function name` is defined in the
# same file or in a file it sources (statically visible `source`/`.` paths, followed transitively).
# Anywhere-in-the-tree was too broad, and a snake_case-name rule hid a guard on a
# function that no sourced lib defines.
func_re = re.compile(r'^\s*(?:function\s+)?([A-Za-z0-9_]+)\s*\(\)\s*\{?')
src_kw = re.compile(r'(?:^\s*|[;&|(]\s*)(?:source|\.)\s+')
sh_tok = re.compile(r'[A-Za-z0-9_./~-]+\.sh\b')
def sourced_paths(line):
    """.sh paths on a `source`/`.` line, with $VAR / $(...) prefixes dropped (the visible tail is resolved)."""
    code = code_part(line).replace('$HOME', home)
    if not src_kw.search(code): return []
    code = re.sub(r'\$\{[^}]*\}|\$[A-Za-z_]+|\$\([^)]*\)?', '', code)
    return sh_tok.findall(code)
home = os.environ['HOME']
_fcache = {}
def lines_of(f):
    if f not in _fcache:
        try: _fcache[f] = open(f, encoding='utf-8', errors='replace').read().splitlines()
        except Exception: _fcache[f] = []
    return _fcache[f]
def resolve_src(frm, raw):
    raw = raw.replace('$HOME', home)
    if raw.startswith('~/'): raw = home + raw[1:]
    if os.path.isabs(raw) and os.path.isfile(raw): return os.path.realpath(raw)
    rel = raw.lstrip('/')    # `"$DIR/lib/x.sh"` leaves `/lib/x.sh`: resolve the visible tail
    for c in [os.path.join(os.path.dirname(frm), rel)] + [os.path.join(r, rel) for r in roots] + \
             [os.path.join(home, '.claude', 'scripts', rel)]:
        if os.path.isfile(c): return os.path.realpath(c)
    # variable-computed dir (`$LIB/os-state.sh`): fall back to the same basename in a lib/ dir
    for d in [os.path.join(r, 'lib') for r in roots] + [os.path.join(home, '.claude', 'scripts', 'lib')]:
        c = os.path.join(d, os.path.basename(rel))
        if os.path.isfile(c): return os.path.realpath(c)
    return None
def defined_funcs(f, seen=None):
    seen = seen if seen is not None else set()
    f = os.path.realpath(f)
    if f in seen: return set()
    seen.add(f)
    out = set()
    for line in lines_of(f):
        mm = func_re.match(line)
        if mm: out.add(mm.group(1))
        for sp in sourced_paths(line):
            t = resolve_src(f, sp)
            if t: out |= defined_funcs(t, seen)
    return out

def is_builtin(b):
    try:
        r=subprocess.run(['bash','-c','type -t "$1"','_',b],capture_output=True,text=True,timeout=5)
        return r.stdout.strip() in ('builtin','keyword','alias')
    except Exception:
        return False

# A lib guards a function its CALLER provides (`command -v write_status` inside lib/net-probe.sh): it
# cannot see its sourcers, so a file also counts the functions of every file that sources it.
direct = {}
for f in allfiles:
    t = set()
    for line in lines_of(f):
        for sp in sourced_paths(line):
            r = resolve_src(f, sp)
            if r: t.add(r)
    direct[os.path.realpath(f)] = t
def callers_of(f):
    f = os.path.realpath(f); out = set(); todo = [f]
    while todo:
        x = todo.pop()
        for c, t in direct.items():
            if x in t and c not in out:
                out.add(c); todo.append(c)
    return out
def known_funcs(f):
    out = defined_funcs(f)
    for c in callers_of(f): out |= defined_funcs(c)
    return out

reported=set()
for b,f,n in sorted(cands):
    if b in reported or b in ignore: continue
    if b in known_funcs(f): continue   # defined here / in a sourced lib / by a sourcing caller: a function
    if shutil.which(b): continue     # installed → gate is live
    if is_builtin(b): continue       # shell builtin/keyword
    reported.add(b)
    print(f"{b}\t{f.replace(home,'~')}:{n}")
PY
)

# --- class 2: declared-but-unregistered Claude Code hooks --------------------
UNREG=()
while IFS= read -r _u; do [ -n "$_u" ] && UNREG+=("$_u"); done < <(ROOTS="${ROOTS[*]}" python3 - <<'PY2'
import glob, json, os, re, sys

roots = os.environ["ROOTS"].split()
settings = os.path.join(os.environ["HOME"], ".claude", "settings.json")

registered = {}   # basename -> set(events)
try:
    with open(settings, encoding="utf-8") as fh:
        data = json.load(fh)
    for event, arr in (data.get("hooks") or {}).items():
        for matcher in arr:
            for h in (matcher.get("hooks") or []):
                cmd = str(h.get("command", ""))
                # the command may carry arguments: `…/wc-event.sh done`
                base = os.path.basename(cmd.split()[0]) if cmd.split() else ""
                if base:
                    registered.setdefault(base, set()).add(event)
except FileNotFoundError:
    print("!\tsettings.json\t~/.claude/settings.json is ABSENT — every declared hook is dead")
    sys.exit(0)
except Exception as e:
    print(f"!\tsettings.json\t~/.claude/settings.json does not parse ({e}) — hook state UNKNOWN")
    sys.exit(0)

marker = re.compile(r"^#\s*claude-hook:\s*([A-Za-z]+)\s*$", re.M)
seen = set()
for root in roots:
    for path in sorted(glob.glob(os.path.join(root, "*.sh")) + glob.glob(os.path.join(root, "hooks", "*.sh"))):
        base = os.path.basename(path)
        if base in seen:
            continue
        seen.add(base)
        try:
            head = open(path, encoding="utf-8", errors="replace").read(4000)
        except OSError:
            continue
        for event in marker.findall(head):
            if event not in registered.get(base, set()):
                print(f"{base}\t{event}\t{path.replace(os.environ['HOME'], '~')}")
PY2
)
u=${#UNREG[@]}

n=${#HITS[@]}
printf '%s [dead-gate] scanned %s root(s), %s missing-binary + %s unregistered-hook candidate(s)\n' "$(ts)" "${#ROOTS[@]}" "$n" "$u" >>"$LOG"

if [ "$u" -gt 0 ]; then
  echo "dead-gate-detect: $u DECLARED HOOK(S) NOT REGISTERED — they exist, and they never fire:"
  printf '%s\n' ${UNREG[@]+"${UNREG[@]}"} | awk -F'\t' '{printf "  • %s declares %s — not registered  (%s)\n",$1,$2,$3}'
  echo "  fix: ops/install.sh && ops/install-hooks.sh"
fi

if [ "$n" -eq 0 ] && [ "$u" -eq 0 ]; then
  echo "dead-gate-detect: OK — every guarded binary is installed and every declared hook is registered."
  command -v write_status >/dev/null 2>&1 && write_status "dead-gate" "true" "clean — no dead-gate candidates" '{}'
  exit 0
fi

if [ "$n" -eq 0 ]; then
  # unregistered hooks only: still a finding, still notified
  command -v write_status >/dev/null 2>&1 && write_status "dead-gate" "false" "$u declared hook(s) not registered — they never fire" '{}'
  [ -x "$NOTIFY" ] && "$NOTIFY" "🕳️ Declared hook(s) not registered" \
    "$u hook script(s) declare a claude-hook event but are absent from ~/.claude/settings.json — they have never fired. Run ops/install-hooks.sh." >/dev/null 2>&1 || true
  exit 0
fi

pretty=$(printf '%s\n' ${HITS[@]+"${HITS[@]}"} | awk -F'\t' '{printf "  • %s  —  %s\n",$1,$2}')
echo "dead-gate-detect: $n GUARDED EXTERNAL BINARY(IES) MISSING — remediation may be silently dead:"
printf '%s\n' "$pretty"
printf '%s [dead-gate] %s\n' "$(ts)" "$(printf '%s' "${HITS[*]}" | tr '\n\t' '; ')" >>"$LOG"
DETAIL=$(printf '%s\n' ${HITS[@]+"${HITS[@]}"} | python3 -c 'import json,sys;print(json.dumps({"candidates":[l.strip() for l in sys.stdin if l.strip()]}))' 2>/dev/null || echo '{}')
command -v write_status >/dev/null 2>&1 && write_status "dead-gate" "false" "$n dead-gate candidate(s) — a guarded external binary is missing, so its code silently skips" "$DETAIL"
[ -x "$NOTIFY" ] && "$NOTIFY" "🕳️ Dead-gate candidate(s) in the OS" \
  "$n guard(s) call a binary not installed here — the gated remediation is silently OFF (fails open). Restore the tool, re-point at its replacement, or add to DEAD_GATE_IGNORE if intentional:"$'\n\n'"$pretty" >/dev/null 2>&1 || true
exit 0
