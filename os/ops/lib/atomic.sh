#!/usr/bin/env bash
# atomic.sh — write a file atomically, or not at all.
#
# WHY: ~/.whisky-os-state/ holds 123 live state files and 13 ops scripts write
# them with read-modify-truncate-write (dream-act.sh's ledger append was the
# worst: json.load, append, open(path,"w"), json.dump). Any crash, kill, disk
# error or concurrent run between the truncate and the flush leaves a truncated
# or empty file — and the next run reads that as "no history", which for a
# dedupe ledger means re-filing every issue it had already decided.
#
# Same-directory temp + rename. rename(2) is atomic within a filesystem; a temp
# in /tmp is a COPY across filesystems and buys nothing.
#
# Source, don't execute:  . "$(dirname "$0")/lib/atomic.sh"
#
# atomic_write <path>              content on stdin
# atomic_json_update <path> <py>   read JSON, transform with a python snippet
#                                  (the parsed object is `d`; assign to `d`),
#                                  refuse to write anything that is not JSON

atomic_write() {
  _aw_path="${1:?atomic_write needs a path}"
  _aw_dir="$(dirname "$_aw_path")"
  [ -d "$_aw_dir" ] || mkdir -p "$_aw_dir" || return 1
  _aw_tmp="$_aw_dir/.$(basename "$_aw_path").tmp.$$"
  if ! cat > "$_aw_tmp"; then
    rm -f "$_aw_tmp"
    return 1
  fi
  # An empty payload is almost always a failed producer, not an intentional
  # truncation. Refuse it: silently emptying a state file is the exact damage
  # this helper exists to prevent. Truncate explicitly with `: > file` if meant.
  if [ ! -s "$_aw_tmp" ]; then
    rm -f "$_aw_tmp"
    echo "atomic_write: refusing to write an EMPTY payload to $_aw_path" >&2
    return 1
  fi
  mv -f "$_aw_tmp" "$_aw_path" || { rm -f "$_aw_tmp"; return 1; }
  return 0
}

atomic_json_update() {
  _aju_path="${1:?atomic_json_update needs a path}"
  _aju_expr="${2:?atomic_json_update needs a python snippet operating on d}"
  _aju_dir="$(dirname "$_aju_path")"
  [ -d "$_aju_dir" ] || mkdir -p "$_aju_dir" || return 1
  _aju_tmp="$_aju_dir/.$(basename "$_aju_path").tmp.$$"

  if AJU_PATH="$_aju_path" AJU_TMP="$_aju_tmp" AJU_EXPR="$_aju_expr" python3 <<'PY'
import json, os, sys

path, tmp, expr = os.environ["AJU_PATH"], os.environ["AJU_TMP"], os.environ["AJU_EXPR"]
try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
except FileNotFoundError:
    d = None
except Exception as e:
    # A corrupt state file is a finding. Overwriting it destroys the evidence of
    # whatever corrupted it, so refuse and let the caller decide.
    print(f"atomic_json_update: {path} does not parse ({e}) — refusing to overwrite", file=sys.stderr)
    sys.exit(3)

ns = {"d": d, "json": json, "os": os}
exec(expr, ns)          # noqa: S102 — the snippet is repo code, not input
d = ns["d"]

try:
    text = json.dumps(d, indent=2) + "\n"
except TypeError as e:
    print(f"atomic_json_update: transform produced non-JSON ({e}) — nothing written", file=sys.stderr)
    sys.exit(4)

with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, path)
PY
  then
    return 0
  fi
  rm -f "$_aju_tmp"
  return 1
}
