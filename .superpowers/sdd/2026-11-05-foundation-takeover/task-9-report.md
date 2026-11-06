# Task 9 report

Added os/ops/force-purge-check.sh (read-only, 8 categories, exit 1 on any hit), os/tests/force-purge-check.test.sh (fake HOME, 8 PASS), registered in run-all.sh, MANIFEST row, exempted both from no-force-strings.

Real run (read-only), per-category hit counts (lines for content categories, files elsewhere):
force-purge-check: 354 hit(s) [ symlinks=28 launchd-plists=51 launchd-content=54 scripts=158 settings=0 instructions=19 repo-docs=44 memory-vault=0 ]

Concerns: content categories count matching lines; memory-vault 0 (vault not a git dir at expected path or already off ForceAI-KW - not verified which).

## Fix round 1
- Config: projects dir and business-dir list now come from os.env via os_config_load (new key OS_NONFORCE_BUSINESS_DIRS, mirrored in os-config.sh); no exemption.
- Symlinks: chains followed hop by hop (portable readlink), any hop in Force-AI/ is reported.
- Paths: line numbers extracted separately, so ":" and spaces in paths are safe.
- Tests: +4 cases (relative, chained, safe chain, space/colon paths); force-purge-check.test.sh 12/12; run-all.sh --quiet exit 0.
