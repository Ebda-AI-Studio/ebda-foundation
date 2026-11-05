#!/usr/bin/env bash
# claude-stub.sh — generate a scriptable stand-in for the `claude` CLI, so a
# model-calling script can be tested offline against the ways the real call fails.
#
# WHY NOT AN HTTP MOCK: deepseek-harness ships an excellent scripted-wire-fault LLM
# server (packages/test-support/llm-mock-server). It is the wrong shape here — the
# OS's 17 model-calling scripts shell out to the `claude` CLI, they do not speak
# HTTP. The equivalent seam is the binary, so this stubs that.
#
# Source, then:  make_claude_stub <dir> <mode>   -> prints the stub path
# Modes:
#   ok         a valid JSON array, one instinct
#   empty      exit 0, no output          (the real CLI does this when it crashes)
#   ratelimit  usage-limit text on stderr, non-zero exit
#   malformed  prose with no parseable JSON
#   crash      non-zero exit with a stack-trace-shaped message on stderr
#   slow       sleeps longer than any caller's timeout
#   partial    a truncated JSON array (the shape a killed stream leaves behind)

make_claude_stub() {
  _cs_dir="${1:?make_claude_stub needs a directory}"
  _cs_mode="${2:?make_claude_stub needs a mode}"
  mkdir -p "$_cs_dir"
  _cs_path="$_cs_dir/claude"
  case "$_cs_mode" in
    ok)        printf '#!/usr/bin/env bash\necho %s\n' \
                 "'[{\"trigger\":\"t1\",\"action\":\"a1\",\"confidence\":0.9}]'" > "$_cs_path" ;;
    empty)     printf '#!/usr/bin/env bash\nexit 0\n' > "$_cs_path" ;;
    ratelimit) printf '#!/usr/bin/env bash\necho "Claude usage limit reached. Try again later." >&2\nexit 1\n' > "$_cs_path" ;;
    malformed) printf '#!/usr/bin/env bash\necho "Sure! Here are the instincts I found:"\necho "1. Always grep before claiming done."\n' > "$_cs_path" ;;
    crash)     printf '#!/usr/bin/env bash\necho "TypeError: Cannot read properties of undefined" >&2\nexit 1\n' > "$_cs_path" ;;
    slow)      printf '#!/usr/bin/env bash\nsleep 120\n' > "$_cs_path" ;;
    partial)   printf '#!/usr/bin/env bash\nprintf %s\n' "'[{\"trigger\":\"t1\",\"action\"'" > "$_cs_path" ;;
    *) echo "make_claude_stub: unknown mode '$_cs_mode'" >&2; return 1 ;;
  esac
  chmod +x "$_cs_path"
  printf '%s' "$_cs_path"
}
