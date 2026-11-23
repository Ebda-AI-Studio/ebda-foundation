#!/usr/bin/env bash
#
# fix-launchd-path.sh — add /usr/local/bin and /opt/local/bin to every Ebda OS
# launchd agent's PATH.
#
# WHY
# ---
# The dead-gate detector reported `gdate` as "not installed". It IS installed:
#     gdate -> /opt/local/bin/gdate      (MacPorts)
#
# But every ${OS_LAUNCHD_PREFIX}.* plist hardcodes:
#     PATH=~/.local/bin:/opt/homebrew/bin:/opt/homebrew/opt/postgresql@17/bin:
#          /opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
#
# Neither /usr/local/bin nor /opt/local/bin is in it. So the binaries resolve in
# Ahmad's interactive shell and are INVISIBLE to every scheduled job. Proven:
#     env -i PATH="<launchd path>" bash -c 'command -v gdate'  -> not found
#
# A gate whose binary is missing fails OPEN and silent; that is the whole point
# of the dead-gate detector.
#
# Appends rather than prepends: appending cannot shadow an existing resolution,
# so no currently-working job can change behaviour.

set -uo pipefail
LA="$HOME/Library/LaunchAgents"
ADD="/usr/local/bin:/opt/local/bin"
APPLY="${1:-}"

[ "$APPLY" = "--apply" ] || echo "DRY RUN — pass --apply to write. "

python3 - "$LA" "$ADD" "$APPLY" <<'PY'
import plistlib, sys, os, glob

la, add, apply_ = sys.argv[1:4]
add_parts = add.split(":")
changed = []

for path in sorted(glob.glob(os.path.join(la, "*.plist"))):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
            f.seek(0)
            data = plistlib.load(f)
    except Exception as e:
        print(f"  SKIP (unreadable) {os.path.basename(path)}: {e}")
        continue

    env = data.get("EnvironmentVariables")
    if not isinstance(env, dict) or "PATH" not in env:
        continue

    cur = env["PATH"]
    parts = cur.split(":")
    missing = [p for p in add_parts if p not in parts]
    if not missing:
        continue

    env["PATH"] = cur + ":" + ":".join(missing)
    changed.append((os.path.basename(path), missing))

    if apply_ == "--apply":
        # Preserve the original on-disk format; a binary plist rewritten as XML
        # still loads, but silently changing file format across 40+ files is the
        # kind of unrequested side effect that makes a diff unreviewable.
        fmt = plistlib.FMT_BINARY if head.startswith(b"bplist") else plistlib.FMT_XML
        with open(path, "wb") as f:
            plistlib.dump(data, f, fmt=fmt)

for name, missing in changed:
    print(f"  {'PATCHED' if apply_ == '--apply' else 'would patch'}  {name}  += {':'.join(missing)}")
print(f"\n{len(changed)} plist(s) {'patched' if apply_ == '--apply' else 'need patching'}")
PY
