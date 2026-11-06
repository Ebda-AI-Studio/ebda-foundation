#!/bin/bash
# update-memory-pipeline.sh v2 — headless memory refresh pipeline
#
# Refreshes the 3-layer memory stack:
#   Layer 1: scoped Claude memory (~/.claude/projects/.../memory/)
#   Layer 2: Obsidian vault ($OS_PROJECTS_DIR/calude code meomry/)
#            with `_claude-memory/` mirroring layer 1 for portability
#   Layer 3: graphify graphs (graphify-out/) per scope + global graph
#
# Designed to run HEADLESS (nohup-friendly). Zero permission prompts via the
# allowlist in ~/.claude/settings.json. Safe-by-default: pre-flight validation,
# bidirectional rsync safety, atomic commit with rollback on failure.
#
# Usage:
#   update-memory-pipeline.sh                  # all (default): vault + global memory
#   update-memory-pipeline.sh vault            # only vault
#   update-memory-pipeline.sh global           # only global memory dir
#   update-memory-pipeline.sh project <slug>   # only a project's scoped memory
#   update-memory-pipeline.sh dry-run          # show what would run, no changes
#
# Logs to /tmp/update-memory-<timestamp>.log
# Exit codes: 0 success, 2 config error, 3 partial failure (rolled back), 4 unrecoverable
#
# Version history:
#   v1 (2026-05-10): initial — extract → report → html → obsidian → commit → push
#   v2 (2026-05-10): pre-flight, bidirectional rsync safety, README banner,
#                    sensitive-keyword warnings, label-coverage metric,
#                    orphan-stash cleanup, atomic git stash rollback,
#                    index↔files consistency check
#   v3 (2026-05-10): extraction is now OPTIONAL — defaults to skip-extract.
#                    Sonnet via in-session subagent dispatch is the new
#                    quality bar (see "Update memory" verb in ~/.claude/CLAUDE.md).
#                    Gemini fallback still available via --extract=gemini flag
#                    or `GRAPHIFY_FALLBACK=gemini` env. Without either, the
#                    pipeline only mirrors + commits + pushes (model writes
#                    file in-session before invoking pipeline).
#   v4 (2026-05-19): Gemini extraction path REMOVED. Sonnet (via in-session
#                    subagent dispatch) is the only extractor. Pipeline modes
#                    are now: skip (default — merges Sonnet polish chunks
#                    written before invocation) or ast (code-only AST-update,
#                    zero LLM, for codebase graphs). Setting EXTRACT=gemini
#                    now warns + falls back to skip.
#   v4.1 (2026-09-04): SECRET GATE. The vault is a pushed repo and had no scan of
#     any kind — no CI, no hooks — while this pipeline pushes to it automatically.
#     vault_secret_gate() now runs before anything is staged and FAILS CLOSED on a
#     missing scanner, an absent/empty/unparseable report, or any finding; a clean
#     verdict is believed only after a planted canary proves the gate can still go red.

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail

# TCC canary (2026-07-12): the vault + graphs live under ~/Desktop — a blind
# launchd context must alert loudly and abort (memory sync NOT happening).
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
OS_JOB_NAME=update-memory-pipeline
if command -v require_projects_access_critical >/dev/null 2>&1; then require_projects_access_critical || exit 0; fi

VERSION="4.1"
TS=$(date +%Y%m%d-%H%M%S)
LOG="/tmp/update-memory-${TS}.log"
exec > >(tee -a "$LOG") 2>&1

# v4: extraction is Sonnet-only (handled in-session before invoking this pipeline).
# Modes:
#   skip (default) — merge any Sonnet-written polish chunks, regen report/html, commit, push
#   ast            — graphify update . (AST-only, zero LLM, for codebase graphs)
EXTRACT="${EXTRACT:-${GRAPHIFY_FALLBACK:-skip}}"

VAULT="$OS_PROJECTS_DIR/calude code meomry"
GLOBAL_MEM="$HOME/.claude/projects/-Users-ahmadsharaf/memory"
GRAPHIFY=$HOME/.local/bin/graphify
PY=$HOME/.local/share/uv/tools/graphifyy/bin/python
DRY_RUN=0

# --- pre-flight checks
preflight() {
  local errs=0

  # v4: pipeline no longer calls Gemini directly (Sonnet via in-session subagent
  # is the only extractor). Key still loaded for graphify CLI's own internal use
  # (cold-start full extracts, etc.) — warn-only if missing.
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    GEMINI_API_KEY=$(grep '^export GEMINI_API_KEY=' ~/.zshenv 2>/dev/null | sed 's/^export GEMINI_API_KEY="//; s/"$//')
  fi
  export GEMINI_API_KEY
  if [ -z "$GEMINI_API_KEY" ]; then
    echo "WARN[preflight]: GEMINI_API_KEY not in env or ~/.zshenv — graphify CLI internals may degrade; pipeline itself does not need it"
  fi

  [ -x "$GRAPHIFY" ] || { echo "FAIL[preflight]: $GRAPHIFY not executable"; errs=$((errs + 1)); }
  [ -x "$PY" ] || { echo "FAIL[preflight]: $PY not executable"; errs=$((errs + 1)); }
  $PY -c "import graphify, networkx" 2>/dev/null || { echo "FAIL[preflight]: graphify/networkx not importable"; errs=$((errs + 1)); }

  if [ -d "$VAULT/.git" ]; then
    cd "$VAULT" || return 1
    local head_email
    head_email=$(git log -1 --pretty='%ae' 2>/dev/null)
    if [ "$head_email" != "ahmed0montaser@gmail.com" ]; then
      echo "WARN[preflight]: vault HEAD author=$head_email (expected ahmed0montaser@gmail.com)"
    fi
    # Clean orphan lint-staged stashes from past failures (safe — only matches lint-staged stashes)
    local orphans
    orphans=$(git stash list 2>/dev/null | grep -c "lint-staged automatic backup" || true)
    if [ "$orphans" -gt 0 ]; then
      echo "[preflight] cleaning $orphans orphan lint-staged stashes"
      [ "$DRY_RUN" -eq 0 ] && for i in $(seq 1 "$orphans"); do
        local idx
        idx=$(git stash list | grep -n "lint-staged automatic backup" | head -1 | cut -d: -f1)
        [ -n "$idx" ] && git stash drop "stash@{$((idx - 1))}" >/dev/null 2>&1 || true
      done
    fi
  fi

  return "$errs"
}

# --- helper: graphify extract + regen report + html on a markdown corpus
refresh_graph() {
  local dir="$1"
  local label="$2"
  if [ ! -d "$dir" ]; then
    echo "  [$label] skipped (dir missing)"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [$label] DRY: would graphify extract + regen report + html"
    return 0
  fi

  cd "$dir" || return 1

  # Preserve labels file across the extract (extract doesn't touch it but be defensive)
  local label_backup=""
  if [ -f graphify-out/.graphify_labels.json ]; then
    label_backup=$(mktemp)
    cp graphify-out/.graphify_labels.json "$label_backup"
  fi

  case "$EXTRACT" in
    skip)
      # Sonnet is the extractor (in-session subagents write .graphify_polish_chunk_*.json).
      # FOLD those chunks into graph.json here — this used to be a silent no-op, so Sonnet
      # nodes piled up unmerged and coverage stayed stuck (fixed 2026-07-06).
      if ls graphify-out/.graphify_polish_chunk_*.json >/dev/null 2>&1; then
        echo "  [$label] EXTRACT=skip — merging Sonnet polish chunks into graph.json..."
        "$HOME/.claude/scripts/graphify-merge-chunks.sh" . 2>&1 | sed 's/^/    /' | tail -6
      else
        echo "  [$label] EXTRACT=skip — no polish chunks to merge"
      fi
      # Refresh the command-center coverage tile (cheap, no LLM). The heavy claude -p
      # backfill of any still-ungraphed files runs on its own daily launchd job.
      if [ "$label" = "global-memory" ]; then
        "$HOME/.claude/scripts/graphify-backfill.sh" report 2>&1 | sed 's/^/    /' | tail -1
      fi
      ;;
    ast)
      echo "  [$label] EXTRACT=ast — graphify update (code-only AST, zero LLM)..."
      "$GRAPHIFY" update . 2>&1 | tail -3
      ;;
    gemini)
      echo "  [$label] WARN: EXTRACT=gemini was removed in v4 — Sonnet via in-session subagent is the only extractor. Falling back to skip."
      ;;
    *)
      echo "  [$label] WARN: unknown EXTRACT='$EXTRACT', skipping extraction"
      ;;
  esac

  # Restore labels if extract clobbered them
  if [ -n "$label_backup" ] && [ ! -f graphify-out/.graphify_labels.json ]; then
    cp "$label_backup" graphify-out/.graphify_labels.json
    echo "  [$label] restored .graphify_labels.json after extract"
  fi
  [ -n "$label_backup" ] && rm -f "$label_backup"

  # Sensitive-keyword detection: warn loudly if files were silently dropped
  if [ -f graphify-out/.graphify_analysis.json ]; then
    "$PY" - <<'PYEOF'
import json
from pathlib import Path
try:
    a = json.loads(Path('graphify-out/.graphify_analysis.json').read_text())
    skipped = a.get('detection', {}).get('skipped_sensitive', [])
    if skipped:
        print(f"  [{__name__}] WARNING: graphify silently skipped {len(skipped)} files with sensitive-keyword filenames:")
        for f in skipped[:5]:
            print(f"    - {f.split('/')[-1]} (rename to avoid 'token'/'secret'/'key' substring)")
except Exception:
    pass
PYEOF
  fi

  # Wikilink backbone: graphify's extract_markdown() has no [[wikilink]] parser, so every
  # cross-note link is invisible to the structural pass and only shows up if the LLM pass
  # happens to notice it. This reads them straight from the markdown (zero LLM) and is
  # idempotent, so it is safe to run on every refresh. Added 2026-08-03 after the global
  # memory graph was found at 72% isolated nodes / 0.28 edges per node.
  # Global memory and the vault cross-link constantly, so each resolves against the other.
  if [ -f "$HOME/.claude/scripts/lib/graphify-wikilink-edges.py" ]; then
    echo "  [$label] wikilink edges..."
    local sibling=""
    case "$label" in
      global-memory) [ -d "$VAULT" ] && sibling="$VAULT" ;;
      vault)         [ -d "$GLOBAL_MEM" ] && sibling="$GLOBAL_MEM" ;;
    esac
    if [ -n "$sibling" ]; then
      python3 "$HOME/.claude/scripts/lib/graphify-wikilink-edges.py" . --also "$sibling" 2>&1 | sed 's/^/  /'
    else
      python3 "$HOME/.claude/scripts/lib/graphify-wikilink-edges.py" . 2>&1 | sed 's/^/  /'
    fi
  fi

  echo "  [$label] regenerate report + html..."
  "$PY" - <<'PYEOF'
import json
from pathlib import Path
from networkx.readwrite import json_graph
from graphify.cluster import score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate

p = Path('graphify-out/graph.json')
if not p.exists():
    raise SystemExit('FAIL: graph.json missing after extract')
g = json.loads(p.read_text())
G = json_graph.node_link_graph(g, edges='links')
comms = {}
for nid, d in G.nodes(data=True):
    cid = d.get('community')
    if cid is not None:
        comms.setdefault(int(cid), []).append(nid)
cohesion = score_all(G, comms)
gods = god_nodes(G)
surprises = surprising_connections(G, comms)
lf = Path('graphify-out/.graphify_labels.json')
labels = {int(k): v for k, v in json.loads(lf.read_text()).items()} if lf.exists() else {}
for cid in comms:
    labels.setdefault(cid, f'Community {cid}')
questions = suggest_questions(G, comms, labels)
report = generate(G, comms, cohesion, labels, gods, surprises,
    {'total_files':0,'total_words':0,'files':{}},
    {'input':0,'output':0},
    str(Path('.').resolve()),
    suggested_questions=questions)
Path('graphify-out/GRAPH_REPORT.md').write_text(report)

# Label coverage metric
hand_labeled = sum(1 for cid in comms if not labels.get(cid, '').startswith('Community '))
print(f'  report: {G.number_of_nodes()} nodes / {G.number_of_edges()} edges / {len(comms)} communities ({hand_labeled} hand-labeled, {len(comms) - hand_labeled} fallback)')
if len(comms) > 5 and hand_labeled / max(len(comms), 1) < 0.3:
    print(f'  WARNING: <30% of communities have hand-labels — consider /graphify polish pass')
PYEOF

  "$GRAPHIFY" export html >/dev/null 2>&1 && echo "  [$label] html ok"
}

# --- helper: refresh <global>/memory/_scoped/<project>/ from the REAL per-project
#     scoped memory dirs (~/.claude/projects/-Users-<user>-Desktop-projects-<repo>/memory).
#
#     WHY THIS EXISTS. mirror_scoped_to_vault below syncs GLOBAL_MEM -> vault only.
#     Nothing ever populated GLOBAL_MEM/_scoped from the per-project dirs, so that
#     tree was a one-off snapshot and every scoped memory file written after it lived
#     on one Mac — exactly what the mirror's own README claims to prevent ("scoped
#     Claude memory is local-only and lost if the machine is wiped"). Measured
#     2026-09-14 before this fix: 50 of 387 scoped files were missing from the vault
#     (umbra 11 local/1 mirrored, quote-studio 3/0, mypovonai-learn 11/0, store 218/208).
#
#     ADDITIVE ON PURPOSE — never --delete. Two scopes had MORE in the mirror than on
#     disk (client-repo 9/10, ebda-whatsapp 63/64), because other machines
#     and older runs contributed files this Mac never had. A --delete here would
#     destroy them. `--update` also means a newer mirror copy is left alone, so this
#     composes with mirror_scoped_to_vault's own back-propagation step.
refresh_scoped_from_projects() {
  [ -d "$GLOBAL_MEM" ] || { echo "  [scoped] skipped (global memory dir missing)"; return 0; }
  local proj_root="$HOME/.claude/projects"
  [ -d "$proj_root" ] || { echo "  [scoped] skipped (no $proj_root)"; return 0; }

  local copied total d slug out n
  copied=0; total=0

  for d in "$proj_root"/*/memory; do
    [ -d "$d" ] || continue
    # The global memory scope lives under projects/ too and must never be copied
    # into its own _scoped/ tree. Compare by inode, not by name: a name comparison
    # silently stops guarding the moment GLOBAL_MEM is pointed anywhere else (a
    # test, a second account, a relocated vault), and the failure mode is copying
    # all of global memory into _scoped/<its-own-slug>/.
    [ "$d" -ef "$GLOBAL_MEM" ] && continue
    slug="$(basename "$(dirname "$d")")"
    # Strip the machine-specific projects-root prefix, leaving the repo name.
    slug="${slug#-Users-${USER}-Desktop-projects-}"
    # A slug that still starts with '-' never matched the prefix (another machine's
    # path shape); keep it verbatim rather than inventing a name for it.
    total=$((total + 1))

    if [ "$DRY_RUN" -eq 1 ]; then
      n=$(rsync -an --update --include='*/' --include='*.md' --exclude='*' \
            "$d/" "$GLOBAL_MEM/_scoped/$slug/" 2>/dev/null | grep -cE '\.md$' || true)
      [ "${n:-0}" -gt 0 ] && echo "  [scoped] DRY: would copy $n file(s) -> _scoped/$slug"
      continue
    fi

    mkdir -p "$GLOBAL_MEM/_scoped/$slug" || continue
    out=$(rsync -ai --update --include='*/' --include='*.md' --exclude='*' \
          --exclude graphify-out --exclude '.graphify_*' --exclude '.DS_Store' \
          "$d/" "$GLOBAL_MEM/_scoped/$slug/" 2>/dev/null | grep -E '^[>c]f' || true)
    if [ -n "$out" ]; then
      n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
      copied=$((copied + n))
      echo "  [scoped] $slug: +$n"
    fi
  done

  # Always print a line, including on a dry run and including when nothing moved:
  # silence is indistinguishable from "this step did not run at all", which is the
  # exact failure this function exists to correct.
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [scoped] DRY: scanned $total project scope(s)"
  elif [ "$copied" -gt 0 ]; then
    echo "  [scoped] refreshed $copied file(s) from $total project scope(s) (additive; nothing deleted)"
  else
    echo "  [scoped] $total project scope(s) already current"
  fi
}

# --- helper: bidirectional rsync between scoped global memory and vault _claude-memory/
#     Step 1 (back-propagate): if any file in _claude-memory/ is newer than its source counterpart,
#                              copy it back to source first (catches accidental Obsidian-side edits)
#     Step 2 (forward sync):   source → _claude-memory/ with --delete (source is authoritative)
#     Step 3 (banner):         write README.md into _claude-memory/ warning not to edit there
mirror_scoped_to_vault() {
  if [ ! -d "$GLOBAL_MEM" ] || [ ! -d "$VAULT" ]; then
    echo "  [mirror] skipped (paths missing)"
    return 0
  fi

  # Pull the per-project scoped dirs into GLOBAL_MEM/_scoped BEFORE the forward sync,
  # otherwise the vault only ever receives whatever _scoped happened to contain.
  refresh_scoped_from_projects
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [mirror] DRY: would back-propagate newer _claude-memory/ files, then forward-sync"
    return 0
  fi

  mkdir -p "$VAULT/_claude-memory"

  # Step 1: back-propagation safety (rsync --update only copies if source newer than dest)
  # ROOT files only — Mac's own memory lives at the root of _claude-memory/,
  # and accidental Obsidian-side edits to those files must be preserved.
  if [ -n "$(ls -A "$VAULT/_claude-memory" 2>/dev/null)" ]; then
    local backprop
    backprop=$(rsync -ai --update \
      --exclude graphify-out --exclude '.graphify_*' --exclude '.DS_Store' --exclude README.md \
      "$VAULT/_claude-memory/" "$GLOBAL_MEM/" 2>&1 | grep -E '^>f' || true)
    if [ -n "$backprop" ]; then
      echo "  [mirror] BACK-PROPAGATED edits made directly in _claude-memory/ (newer there than source):"
      echo "$backprop" | sed 's/^/    /'
      echo "  [mirror] These should normally be edited in $GLOBAL_MEM. Recovered."
    fi
  fi

  # Step 1.5: vault-authoritative deletion sync for cross-machine subdirs.
  # Convention: subdirs under _claude-memory/ are owned by OTHER machines
  # (Windows → `C--Users-<name>/`, Linux → `-home-<name>/`). Mac's own
  # memory lives at the root level of _claude-memory/ — never in a subdir.
  #
  # Without this step, the resurrection loop fires: machine A deletes
  # foo.md → pushes → Mac pulls (foo.md gone from vault) → but mac scoped
  # still has foo.md from a previous back-prop → forward-sync (--delete,
  # source authoritative) re-adds foo.md to vault → push → bad-file
  # resurrected silently.
  #
  # Fix: for each cross-machine subdir, vault is authoritative. Run rsync
  # with --delete from vault → scoped so deletions on other machines
  # propagate into Mac's local view BEFORE the forward-sync step. The
  # accidental-edit protection above (step 1) only applies to root files,
  # NOT subdirs — accidental edits to other-machine subdirs aren't a real
  # scenario (Mac never edits files inside `C--Users-moze1/`).
  for vault_subdir in "$VAULT/_claude-memory/"*/; do
    [ -d "$vault_subdir" ] || continue
    local subname
    subname=$(basename "$vault_subdir")
    # Skip system / build dirs, and `_scoped` — which is MAC-OWNED, not a
    # cross-machine subdir. The convention above ("Mac's own memory lives at the
    # root level of _claude-memory/ — never in a subdir") has one exception, and
    # treating it as cross-machine made the vault authoritative over it, so any
    # scoped memory newly written on this Mac was rsync --delete'd BEFORE step 2
    # could ever push it to the vault. Silent data loss on every scoped write.
    # Proven 2026-08-16 with a canary file:
    #   [mirror] cross-machine subdir _scoped synced from vault (vault authoritative):
    #     *deleting ebda-studio/zz-canary-test.md
    case "$subname" in
      .*|graphify-out|_backups|_scoped) continue ;;
    esac
    local scoped_subdir="$GLOBAL_MEM/$subname"
    mkdir -p "$scoped_subdir"
    local subsync
    subsync=$(rsync -ai --delete \
      --exclude '.DS_Store' --exclude README.md \
      "$vault_subdir" "$scoped_subdir/" 2>&1 | grep -E '^(>|\*deleting)' || true)
    if [ -n "$subsync" ]; then
      echo "  [mirror] cross-machine subdir $subname synced from vault (vault authoritative):"
      echo "$subsync" | sed 's/^/    /'
    fi
  done

  # Step 2: forward sync (source authoritative)
  echo "  [mirror] rsync $GLOBAL_MEM -> $VAULT/_claude-memory/"
  rsync -a --delete \
    --exclude graphify-out --exclude '.graphify_*' --exclude '.DS_Store' --exclude '.claude' --exclude README.md \
    "$GLOBAL_MEM/" "$VAULT/_claude-memory/" | tail -3

  # Step 3: write banner README warning not to edit
  cat > "$VAULT/_claude-memory/README.md" <<EOF
# DO NOT EDIT FILES IN THIS FOLDER

This folder is **auto-mirrored** from \`~/.claude/projects/-Users-ahmadsharaf/memory/\` by \`~/.claude/scripts/update-memory-pipeline.sh\` on every "update memory" run.

## Editing rules

- **Always edit the source**: \`~/.claude/projects/-Users-ahmadsharaf/memory/<filename>.md\`
- **Edits made directly here are recoverable but discouraged.** The pipeline runs \`rsync --update\` to back-propagate any newer file from this folder to the source before forward-syncing — so an accidental edit doesn't get silently nuked. But:
  - Two-way sync conflicts (you edit here AND I edit source between runs) resolve by mtime, not merge.
  - The git commit captures whatever the latest state is after sync.

## Why this folder exists

Vault + graphify = the **two true memory layers** (per global \`~/.claude/CLAUDE.md\` § Update memory verb). Scoped Claude memory at \`~/.claude/\` is local-only and lost if the machine is wiped. This mirror plus the vault's GitHub remote (\`$OS_ORG/claude-memory-vault\`) makes scoped memory portable across machines.

Last refreshed: $(date "+%Y-%m-%d %H:%M:%S %Z") (pipeline v$VERSION)
EOF

  # Make sure vault graphify ignores this folder (it'd otherwise re-extract content already in global memory's graph)
  if [ -f "$VAULT/.graphifyignore" ] && ! grep -qF "_claude-memory/" "$VAULT/.graphifyignore"; then
    echo "_claude-memory/" >> "$VAULT/.graphifyignore"
    echo "  [mirror] added _claude-memory/ to vault .graphifyignore"
  fi
}

# --- helper: validate MEMORY.md index ↔ actual files (warn on orphans / unindexed)
validate_index() {
  local mem_dir="$1"
  local label="$2"
  local idx="$mem_dir/MEMORY.md"
  [ -f "$idx" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [$label-index] DRY: would validate MEMORY.md ↔ files"
    return 0
  fi
  # Quoted delimiter: the body is Python and must NOT be shell-expanded.
  # A backtick in a Python comment was being read as a command substitution,
  # so bash tried to execute `.exists()` and died with "unexpected end of
  # file" — silently, every run, since the failure was inside $( ). Values
  # now travel via the environment instead of interpolation.
  LH_MEM_DIR="$mem_dir" LH_LABEL="$label" "$PY" - <<'PYEOF'
import re
from pathlib import Path
import os
mem = Path(os.environ['LH_MEM_DIR'])
LABEL = os.environ['LH_LABEL']
projects_root = mem.parent.parent  # ~/.claude/projects — scoped cross-project paths resolve here
idx = (mem / 'MEMORY.md').read_text()
# Sub-indexes (MEMORY-<topic>.md) are PART of the index. Heavy sections were
# split out of the root MEMORY.md (2026-08-13) to keep it under the read cap, so
# their pointers now live in the sub-index — count them as indexed. Without this
# the ~48 moved entries all false-flag as "missing from MEMORY.md" every run.
for sub in sorted(mem.glob('MEMORY-*.md')):
    idx += '\n' + sub.read_text()
# Match ONLY markdown link targets: ](target.md). [^)\s]+ excludes whitespace/newlines so a
# stray '(' in prose (e.g. a grep regex like 'set(Interval|Timeout)\(') can't swallow the next
# real link across lines — the previous \(([^)]+\.md)\) regex did exactly that and false-flagged.
referenced = set(re.findall(r'\]\(([^)\s]+\.md)\)', idx))
# Exclude the index files themselves (MEMORY.md + MEMORY-*.md) and CLAUDE.md —
# they are indexes, not content memories to be validated for membership.
on_disk = {f.name for f in mem.glob('*.md') if f.name != 'CLAUDE.md' and not f.name.startswith('MEMORY')}

def resolves(ref):
    # Slash-refs are relative to the INDEX's own directory first: '_scoped/<proj>/x.md'
    # and '../../<other>/memory/x.md' both live under/next to mem. Only genuinely
    # projects-root-relative refs ('-Users-...-<proj>/memory/x.md') need the fallback.
    # Resolving ONLY against projects_root false-flagged all 32 mem-relative scoped
    # links as orphans on the validator's first live run (2026-08-14).
    if '/' in ref:
        return (mem / ref).exists() or (projects_root / ref).exists()
    # ref in on_disk covers content memories; the `.exists()` fallback covers the
    # index files themselves (MEMORY.md / MEMORY-*.md), which are excluded from
    # on_disk but ARE valid link targets — sub-indexes link back to MEMORY.md and
    # to each other, and those must not read as orphans.
    return ref in on_disk or (mem / ref).exists()

orphans = sorted(r for r in referenced if not resolves(r))
indexed_here = {r for r in referenced if '/' not in r}
scoped = len(referenced) - len(indexed_here)
unindexed = sorted(on_disk - indexed_here)
if orphans:
    print(f"  [{LABEL}-index] WARNING: {len(orphans)} index entries point to missing files:")
    for o in orphans[:5]:
        print(f"    - {o}")
if unindexed:
    print(f"  [{LABEL}-index] WARNING: {len(unindexed)} files exist on disk but missing from MEMORY.md / its sub-indexes:")
    for u in unindexed[:5]:
        print(f"    - {u}")
if not orphans and not unindexed:
    print(f"  [{LABEL}-index] index ↔ files consistent ({len(on_disk)} top-level + {scoped} scoped entries)")
PYEOF
}

# --- helper: vault-specific obsidian export
vault_obsidian_export() {
  cd "$VAULT" || return 1
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [vault] DRY: would graphify export obsidian"
    return 0
  fi
  echo "  [vault] graphify export obsidian..."
  "$GRAPHIFY" export obsidian --dir _graphify-nodes 2>&1 | tail -2

  # PS 5.1 encoding guard: PowerShell 5.1 on Windows reads .ps1 files as
  # Windows-1252 ANSI by default unless they start with a UTF-8 BOM. Any
  # non-ASCII char (em-dash, arrow, ✓/✗) parses as mojibake + breaks
  # script execution. Auto-add BOM to every .ps1 under _bootstrap/ so
  # Windows contributors can run them. See feedback-windows-ps-installer-
  # compat.md + feedback-windows-filename-length-trap.md.
  python3 - <<'PY'
import os
BOOTSTRAP = "_bootstrap"
BOM = b"\xef\xbb\xbf"
if not os.path.isdir(BOOTSTRAP):
    raise SystemExit(0)
for entry in os.listdir(BOOTSTRAP):
    if not entry.lower().endswith(".ps1"):
        continue
    path = os.path.join(BOOTSTRAP, entry)
    with open(path, "rb") as f:
        head = f.read(3)
    if head == BOM:
        continue
    with open(path, "rb") as f:
        body = f.read()
    with open(path, "wb") as f:
        f.write(BOM + body)
    print(f"  [vault] ps1-bom: added BOM to {entry}")
PY

  # Windows path-length guard: NTFS truncates paths past ~260 chars, so
  # graphify-generated filenames > ~150 chars break `git clone` for any
  # vault contributor on Windows ("Filename too long" error). Truncate
  # offenders in-place after each export so the next clone works.
  python3 - <<'PY'
import os, re
DIR = "_graphify-nodes"
MAX_BASENAME = 120  # leave headroom under Windows 255-char component cap
if not os.path.isdir(DIR):
    raise SystemExit(0)
for entry in os.listdir(DIR):
    if not entry.endswith(".md"):
        continue
    if len(entry) <= MAX_BASENAME:
        continue
    # Slug shape: keep first ~80 chars of the original, strip trailing
    # punctuation/whitespace, append .md. Skip if a shortened version
    # already exists (idempotent across reruns).
    stem = entry[:-3]
    shortened = stem[:80].rstrip(" ,.:;()[]→-") + ".md"
    src, dst = os.path.join(DIR, entry), os.path.join(DIR, shortened)
    if os.path.exists(dst):
        os.remove(src)  # collision — keep the existing shortened file
        print(f"  [vault] truncate: removed dupe '{entry[:60]}...' (target exists)")
        continue
    os.rename(src, dst)
    print(f"  [vault] truncate: '{entry[:60]}...' -> '{shortened[:60]}...'")
PY
}

# --- helper: the vault is a PUSHED repo — nothing leaves it without a secret scan.
#
# WHY THIS EXISTS (2026-09-04): the vault had NO secret gate of any kind — no CI, no
# hooks, no scan — while this pipeline pushes to it automatically after every commit
# and at every session end. A memory file was found carrying partial PostHog/VAPID/
# Sentry values in the same paragraph that states the rule against it. Those are
# NEXT_PUBLIC_* values (public by design), so that instance was low severity; the
# posture was the finding. A genuinely secret value rode the same unchecked path.
#
# FAILS CLOSED, four ways, per standard/gate-integrity.md:
#   1. no scanner            -> abort (a declared-but-uninstalled gate fails OPEN, silently)
#   2. absent/empty report   -> abort (gitleaks 8.30.1 writes NOTHING to --report-path
#                                      /dev/stdout; that exact bug made a secret gate
#                                      pass on any corpus for months)
#   3. unparseable report    -> abort (a parser fallback converts a broken gate into a
#                                      passing one; never `?? []`)
#   4. any finding           -> abort, printing file:line:rule with values REDACTED
#
# And a CLEAN verdict is believed only after a POSITIVE CONTROL: a canary private key
# is planted inside the real scan scope, with the real flags, and the scanner must go
# red on it. If the control does not fire, this gate cannot fail and its "clean" means
# nothing — so that also aborts. The canary lives under .gitleaks-canary/, which is
# gitignored (gitleaks `dir` does NOT honour .gitignore — verified 8.30.1 — so it is
# scanned but can never be committed) and is removed by a trap on every exit path.
vault_secret_gate() {
  local scan_root="$VAULT"
  local tmp rc report canary_dir n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/vault-secret-gate.XXXXXX") || return 4
  canary_dir="$scan_root/.gitleaks-canary"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' '$canary_dir'" RETURN

  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "  [vault] SECRET GATE: FAIL — gitleaks not installed. Refusing to push."
    echo "  [vault]   brew install gitleaks"
    return 4
  fi

  # `detect` is deprecated and ABSENT from 8.30.1; `dir` is the subcommand. Pin the
  # check itself so a future rename cannot silently turn this into exit 0 / no output.
  if ! gitleaks --help 2>&1 | grep -qE '^\s+dir\s'; then
    echo "  [vault] SECRET GATE: FAIL — this gitleaks has no 'dir' subcommand ($(gitleaks version 2>&1))."
    return 4
  fi

  # The vault's own allowlist. Narrow, path+rule scoped, each entry carrying a WHY —
  # the memory corpus documents secret SHAPES (a gate's own positive control, a
  # .gitleaksignore fingerprint format) and prose that reads as a key ("token:<name>").
  # Absent config = gitleaks defaults, which is stricter, not looser: never fail-open.
  local cfg=()
  [ -f "$VAULT/.gitleaks.toml" ] && cfg=(--config "$VAULT/.gitleaks.toml")

  _gl_scan() {  # $1 = dir to scan, $2 = report path; echoes finding count or fails
    local d="$1" r="$2"
    gitleaks dir "$d" ${cfg[@]+"${cfg[@]}"} --no-banner --redact --report-format json --report-path "$r" >/dev/null 2>&1
    [ -s "$r" ] || { echo "  [vault]   report absent or zero-byte: $r" >&2; return 1; }
    python3 - "$r" <<'PY' 2>/dev/null || return 1
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)            # a parse error EXITS NON-ZERO — it never empties the gate
if not isinstance(d, list):
    raise SystemExit(1)
print(len(d))
PY
  }

  report="$tmp/vault.json"
  if ! n=$(_gl_scan "$scan_root" "$report"); then
    echo "  [vault] SECRET GATE: FAIL — scan produced no usable report. Refusing to push."
    return 4
  fi

  if [ "$n" -gt 0 ]; then
    echo "  [vault] SECRET GATE: FAIL — $n finding(s). Refusing to commit or push."
    python3 - "$report" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))[:20]:
    print("  [vault]   %s:%s  %s" % (f.get("File"), f.get("StartLine"), f.get("RuleID")))
PY
    echo "  [vault]   values are redacted above by design. Fix the FILE, then re-run."
    return 4
  fi

  # Clean. Now prove this gate could have failed — same binary, same flags, same tree.
  #
  # The canary is GENERATED, never embedded. A private-key-shaped literal in this file
  # is a real finding to every scanner that reads this repo — the foundation's own
  # gitleaks CI caught exactly that and failed the PR, correctly. Suppressing it by
  # fingerprint is not an option either: a .gitleaksignore entry is commit-pinned and
  # this repo squash-merges, so the suppression would silently expire
  # (feedback-gitleaks-squash-merge-fingerprint-trap). A freshly generated, never-used
  # 1024-bit key costs ~0.05s, exists for the length of one scan, and is a STRONGER
  # control than a fake-looking string: it is the real shape.
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  [vault] SECRET GATE: FAIL — openssl missing, cannot build the positive control."
    echo "  [vault]   Without a control this gate's 'clean' is unverifiable. Refusing to push."
    return 4
  fi
  mkdir -p "$canary_dir" || return 4
  if ! openssl genrsa -out "$canary_dir/positive-control.pem" 1024 >/dev/null 2>&1; then
    echo "  [vault] SECRET GATE: FAIL — could not generate the positive control key."
    return 4
  fi
  if ! n=$(_gl_scan "$scan_root" "$tmp/control.json"); then
    echo "  [vault] SECRET GATE: FAIL — positive control produced no usable report."
    return 4
  fi
  if [ "$n" -lt 1 ]; then
    echo "  [vault] SECRET GATE: FAIL — the POSITIVE CONTROL did not fire."
    echo "  [vault]   A planted private key scanned clean, so this gate cannot fail and"
    echo "  [vault]   its 'clean' verdict is meaningless. Refusing to push."
    return 4
  fi

  echo "  [vault] secret gate: clean (positive control fired: $n)"
  return 0
}

# --- helper: vault commit + push with atomic rollback on failure
vault_commit_push() {
  cd "$VAULT" || return 1
  if [ -z "$(git status --short)" ]; then
    echo "  [vault] no changes to commit"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [vault] DRY: would commit + push:"
    git status --short | head -10 | sed 's/^/    /'
    return 0
  fi

  # Nothing is staged until the corpus is proven clean — see vault_secret_gate().
  if ! vault_secret_gate; then
    echo "  [vault] ABORT: secret gate refused. Nothing committed, nothing pushed."
    return 4
  fi

  local head_before
  head_before=$(git rev-parse HEAD)

  # Specific paths only — never `git add -A`
  git add wiki/ graphify-out/graph.json graphify-out/GRAPH_REPORT.md graphify-out/graph.html graphify-out/.graphify_labels.json _graphify-nodes/ _claude-memory/ .gitignore .graphifyignore .gitleaks.toml 2>/dev/null || true

  if [ -z "$(git diff --cached --name-only)" ]; then
    echo "  [vault] nothing staged after specific-paths add"
    return 0
  fi

  echo "  [vault] committing..."
  if ! git commit -m "$(cat <<MSG
chore: refresh memory (auto via update-memory-pipeline.sh v$VERSION)

Pipeline run at $TS — graphify extract + report regen + html regen +
obsidian export + scoped-memory mirror across the vault.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
MSG
)" 2>&1 | tail -5; then
    echo "  [vault] FAIL: commit rejected. HEAD unchanged at $head_before"
    return 3
  fi

  echo "  [vault] pushing..."
  if ! git push origin "$(git rev-parse --abbrev-ref HEAD)" 2>&1 | tail -2; then
    echo "  [vault] WARN: push failed but commit landed locally. HEAD: $(git rev-parse --short HEAD)"
    return 3
  fi
}

# --- helper: keep the OS repo (ebda-foundation) drift-free every run.
# The foundation IS the Whisky AI OS but is DECOUPLED from this pipeline, so its
# mechanical artifacts (ARCHITECTURE.md self-map + graphify-out graph) drift and
# merged PRs sit un-pulled. We delegate to the OS's own ops/sync-foundation.sh
# (it ff-pulls, regenerates only when source changed, and commits ONLY the
# graph+self-map allowlist — content edits stay human PRs). Non-fatal: a failure
# here must never break the memory pipeline.
sync_foundation() {
  local fnd="$OS_HOME"
  local sync="$fnd/os/ops/sync-foundation.sh"
  if [ ! -x "$sync" ]; then
    echo "  [foundation] skip — $sync not found"; return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [foundation] DRY: would run os/ops/sync-foundation.sh --check"
    bash "$sync" --check 2>&1 | sed 's/^/  [foundation] /' || true
    return 0
  fi
  echo "  [foundation] syncing OS repo (self-map + graph, allowlist only)..."
  bash "$sync" 2>&1 | sed 's/^/  [foundation] /' || echo "  [foundation] WARN: sync-foundation returned nonzero (non-fatal)"
}

# --- helper: mirror ~/.claude/CLAUDE.md into the Codex AGENTS.md copies so both
# agents run on the same rules. Non-fatal, like sync_foundation.
sync_agents_md() {
  local sync="$HOME/.claude/scripts/sync-agents-md.sh"
  if [ ! -x "$sync" ]; then
    echo "  [agents-md] skip — $sync not installed (ops/install.sh)"; return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    bash "$sync" --check 2>&1 | sed 's/^/  [agents-md] DRY /' || true
    return 0
  fi
  bash "$sync" 2>&1 | sed 's/^/  [agents-md] /' || echo "  [agents-md] WARN: sync-agents-md returned nonzero (non-fatal)"
}

# --- main dispatch
main() {
  local scope="${1:-all}"
  case "$scope" in
    dry-run|--dry-run) DRY_RUN=1; scope="all" ;;
  esac

  echo "[$(date +%H:%M:%S)] update-memory-pipeline v$VERSION start (scope=$scope, extract=$EXTRACT, dry=$DRY_RUN, log=$LOG)"

  preflight || { echo "FAIL: preflight errors above"; exit 2; }

  # Pull vault FIRST so any cross-device commits (e.g. Windows-side
  # "update memory" pushes that landed since last sync) get integrated
  # before we mirror our local memory on top. Without this pull, the
  # subsequent vault_commit_push would either (a) succeed in a fast-
  # forward push that silently overwrites a remote-only update if the
  # working tree didn't touch the same files, or (b) fail at push time
  # with non-fast-forward and force a manual recovery. Either way bad.
  # Rebase keeps the history linear (no merge commits in the vault).
  if [ -d "$VAULT/.git" ] && [ "$DRY_RUN" -eq 0 ]; then
    cd "$VAULT" || exit 1
    echo "  [vault] git pull --rebase origin main (pre-sync)"
    if git pull --rebase origin main 2>&1 | tail -3; then
      :
    else
      echo "  [vault] WARN: pull failed — continuing with current state. Check 'git status' after run."
    fi
  fi

  case "$scope" in
    vault)
      mirror_scoped_to_vault
      refresh_graph "$VAULT" vault
      vault_obsidian_export
      vault_commit_push
      ;;
    global)
      refresh_graph "$GLOBAL_MEM" global-memory
      validate_index "$GLOBAL_MEM" global-memory
      ;;
    project)
      local proj_path="${2:-}"
      if [ -z "$proj_path" ]; then
        echo "FAIL: project scope needs path or slug arg"; exit 2
      fi
      [ -d "$proj_path" ] || proj_path="$HOME/.claude/projects/-Users-ahmadsharaf-Desktop-projects-${proj_path}/memory"
      refresh_graph "$proj_path" "project($(basename "$proj_path"))"
      validate_index "$proj_path" "project($(basename "$proj_path"))"
      ;;
    all)
      refresh_graph "$GLOBAL_MEM" global-memory
      validate_index "$GLOBAL_MEM" global-memory
      mirror_scoped_to_vault
      refresh_graph "$VAULT" vault
      vault_obsidian_export
      vault_commit_push
      refresh_global_graph
      ;;
    *)
      echo "FAIL: unknown scope '$scope'. Use: all | vault | global | project <slug> | dry-run"
      exit 2
      ;;
  esac

  # Keep the OS repo in sync on the broad scopes (all / global). Non-fatal.
  case "$scope" in
    all|global) sync_foundation; sync_agents_md ;;
  esac

  # Immediately nudge the runtime layer (OS dashboard + Zero) so a memory update
  # reflects NOW instead of waiting for the next scheduled watchdog tick. The
  # dashboard reads ~/.whisky-os-state live, so a status tile + a bus event are
  # enough. Fully best-effort — the runtime may not be present (fresh machine).
  nudge_runtime "$scope"

  echo "[$(date +%H:%M:%S)] update-memory-pipeline v$VERSION done"
}

# nudge_runtime SCOPE — reflect a completed memory sync on the Live Companion OS
# immediately. Writes the `memory` status tile + emits a `memory_updated` event
# on the NDJSON bus the dashboard/Zero tail. Never fails the pipeline.
nudge_runtime() {
  local scope="${1:-all}"
  local statedir="${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}"
  [ -d "$statedir" ] || return 0
  # os-state.sh provides write_status + emit_event (installed by the foundation).
  # shellcheck disable=SC1090
  . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null \
    || . "$OS_HOME/os/ops/lib/os-state.sh" 2>/dev/null \
    || return 0
  local ts; ts="$(date -u +%FT%TZ)"
  if command -v write_status >/dev/null 2>&1; then
    write_status "memory" "true" "memory + graph synced ($scope)" \
      "{\"scope\":\"$scope\",\"ts\":\"$ts\"}" 2>/dev/null || true
  fi
  if command -v emit_event >/dev/null 2>&1; then
    emit_event "memory" "info" "memory + graph synced ($scope)" \
      "{\"scope\":\"$scope\"}" 2>/dev/null || true
  fi
  echo "  [runtime] nudged OS dashboard (memory tile + bus event)"
}

# Re-merge every per-scope graph into the cross-project global graph so
# `~/.graphify/global-graph.json` never goes stale (it previously drifted ~50
# days because nothing re-merged it — the per-scope refreshes above only touch
# each scope's own graphify-out/). Best-effort + non-fatal; null-delimited to
# survive the space in the vault path.
refresh_global_graph() {
  command -v "$HOME/.local/bin/graphify" >/dev/null 2>&1 || return 0
  local list; list="$(mktemp)"
  # Repos live at <business>/{internal-projects,clients/<client>}/<repo> since the
  # 2026-09-25 business-folder layout, so a graph sits up to 6 levels down. The
  # old -maxdepth 3 found ONE graph after the move, merge-graphs needs two, and
  # the global graph silently stopped refreshing. Worktrees are excluded: they
  # are copies of a repo already counted.
  find "$OS_PROJECTS_DIR" -maxdepth 6 -name graph.json -path '*graphify-out*' \
      -not -path '*/node_modules/*' -not -path '*/_worktrees/*' 2>/dev/null > "$list"
  if [ "$(wc -l < "$list" | tr -d ' ')" -lt 2 ]; then
    echo "  [global-graph] only $(wc -l < "$list" | tr -d ' ') scope graph(s) found — NOT merged (expected many; check the projects layout)"
    rm -f "$list"; return 0
  fi
  if [ -s "$list" ]; then
    tr '\n' '\0' < "$list" \
      | xargs -0 "$HOME/.local/bin/graphify" merge-graphs --out "$HOME/.graphify/global-graph.json" \
      >/dev/null 2>&1 \
      && echo "  [global-graph] re-merged $(wc -l < "$list" | tr -d ' ') scope graphs" \
      || echo "  [global-graph] merge skipped (non-fatal)"
  fi
  rm -f "$list"
}

main "$@"
