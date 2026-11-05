# shellcheck shell=bash
# ops/lib/args.sh - strict argument handling for sweeps and watchers (plan 2026-10-26 S0, incident I12).
# `workspace-hygiene.sh --help` used to run a REAL sweep because unknown flags were skipped. Now:
#   args_help <script> "$@"      -h/--help anywhere: print the script's leading comment block, exit 0 - call it BEFORE
#                                any lock, source of an acting lib, or side effect.
#   args_unknown <script> <arg>  an unknown flag is exit 2 with a message, never silently ignored.
args_help() {
  local script="$1" a; shift
  for a in "$@"; do
    case "$a" in
      -h|--help)
        awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$script"
        exit 0 ;;
    esac
  done
  return 0
}
args_unknown() { echo "$(basename "$1"): unknown argument '$2' (try --help)" >&2; exit 2; }
