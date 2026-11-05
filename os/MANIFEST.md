# os/ manifest

The AI OS layer of ebda-foundation: the operating tooling that every business (Ebda AI Studio, Whisky 11, Force AI) runs under. It is ported in from the frozen predecessor at tag `final-before-ebda`; see the freeze note in `docs/history/`.

## Layout

| Path | Purpose | State |
|---|---|---|
| `config/os.env` | Single source for the OS identity: repo slug, orgs, launchd prefix, git chain key, state dir, services env path. | present |
| `ops/` (repo root today) | Merge gate, host lock, workflow lint. | present, moves under `os/` during the port |
| everything else | Standards, audit lenses, hooks, launchd jobs, scripts from the predecessor. | not ported yet |

## Rules for anything ported here

- Read identity and paths from `config/os.env`; never hard-code a slug, org, launchd label or state path.
- No product, client or customer names outside `docs/history/`.
- Secrets never enter the repo; they live in `OS_SERVICES_ENV`.
- Launchd labels use the `OS_LAUNCHD_PREFIX` prefix.

Layering and cost-if-wrong: `docs/rulings/FDN-OS-1.md`.
