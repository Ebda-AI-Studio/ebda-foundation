# changelog.d

One file per change: `changelog.d/<slug>.md`, `[A-Za-z0-9._-]+`, containing ONE line `- ID (files): what changed`.
Do NOT edit `CHANGELOG.md`'s `## Unreleased` (CI fails a hand-written bullet): fragments cannot conflict with each other, hand edits to one shared list did (#104 to #113 each re-merged for it).
`bash os/ops/changelog-assemble.sh` previews the notes; a release runs `os/ops/changelog-assemble.sh --release vX.Y.Z`, which folds the fragments under that version and deletes them.
