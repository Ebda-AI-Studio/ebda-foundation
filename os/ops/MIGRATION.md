# Whisky AI OS — migrate to the ForceAI Mac Studio

Move the whole OS (33 scheduled jobs + scripts + memory + dashboard + self-heal +
DR + knowledge brain) from Ahmad's personal Mac onto the company **ForceAI Studio**,
so the Studio *runs* everything and the personal Mac becomes a pure controller
(SSH in). The Studio has a **different username** — the kit is built for that.

## Why not Docker
The OS is macOS-native: **launchd** scheduling, `osascript`/notifications, the
:7717 dashboard, Keychain, iCloud, and **Claude Code + `claude -p`** (tied to the
Max-plan login on the host). A Linux container has none of it, and the Studio's
value *is* being a persistent host (self-hosted CI, local AI on the M5, backups).
Docker's only role here is the **CI runners** (OrbStack) and throwaway local test
services — not the OS. Local AI runs **native** (MLX/Ollama) for GPU + Neural Engine.

## What moves how
| Layer | Mechanism |
| --- | --- |
| OS scripts + logic | `ebda-foundation` repo → `ops/install.sh` (git) |
| launchd jobs (33) | `ops/launchd/*.plist` **templates** (`__HOME__`/`__PATH__`) → install.sh substitutes this machine's user + paths |
| Memory + vault | git (`update-memory-pipeline.sh` + `claude-memory-vault`) — already synced |
| CLAUDE-HOME (global CLAUDE.md, `settings.json` hooks, skills, agents, workflows, commands, keybindings, scoped memory, instinct store) | `ops/migrate-claude-home.sh export` on the old Mac → tarball → `ops/migrate-claude-home.sh import <tarball>` on the new Mac, AFTER `bootstrap.sh`. This layer lives outside the repo and does NOT move with `install.sh` — without it a new Mac gets the launchd fleet but a Claude with no rules, no skills, no memory. Excludes transcripts/caches, credentials (re-auth per machine), and plugin caches (reinstall). |
| CLIs | `ops/Brewfile` + `ops/bootstrap.sh` (npm/uv/Claude Code) |
| Auth/secrets | **re-auth per service** + scp the 2 `.env` files (never in git) |
| Backups | let the daily job repopulate, or scp `_backups/` once |

The installer is **dynamic**: it copies *every* `ops/*.sh` and schedules *every*
`ops/launchd/*.plist`. **Adding a new automation later = drop the script in `ops/`
+ its plist in `ops/launchd/` (use `__HOME__`/`__PATH__` tokens) → re-run
`ops/install.sh`.** No list to maintain — new scripts are opt-in by existing.

## On the ForceAI Studio (bring-up)
```bash
git clone <foundation-remote> && cd ebda-foundation
./ops/bootstrap.sh          # brew + npm + uv + Claude Code, then install.sh, then the checklist
./ops/migrate-claude-home.sh import <tarball>   # restore CLAUDE-HOME (rules/skills/memory) exported from the old Mac
```
Then complete the **manual re-auth** the checklist prints (claude/gh/neonctl/wrangler/railway
login + scp the 2 `.env` files). Verify: `bash ops/self-check.sh`, `os-recall.sh senses`,
`open http://127.0.0.1:7717`.

Also clone the working repos the OS monitors/deploys (FWB, WBS, CRM, …) under
`~/Desktop/projects/` so the monitors + self-heal have their targets.

## On the personal Mac (decommission — do LAST, after the Studio is verified live)
```bash
./ops/uninstall.sh --dry-run   # preview
./ops/uninstall.sh             # stop + unload all OS jobs (reversible via install.sh)
# optional, once fully confident:
./ops/uninstall.sh --purge     # also delete the plists + dashboard runtime copy
```
This leaves memory, the vault, and `~/.whisky-services.env` untouched — only the
local jobs stop. The personal Mac now just SSHes into the Studio to control it.

## Apple Business (make the Studio company-owned, off personal iCloud)
The new **Apple Business** platform (2026) gives company-controlled Managed Apple
Accounts + MDM + per-user iCloud (up to 2TB/$0.99/user/mo). Use it for the
Studio's **identity + device management** — NOT for syncing the OS/dev files (git
already does that; iCloud Drive over `.git`/`node_modules`/`_backups` is a
reliability hazard).

1. Enroll the business at **business.apple.com** (needs a D-U-N-S number; free).
   Verify the company (Force AI) — allow a few days.
2. Create a **Managed Apple Account** for the company (tie billing/identity to the
   company Gmail/domain, mirroring the GitHub-org + company-Gmail moves already done).
3. Set the **Studio up under the Managed Apple Account**, not the personal Apple ID
   (sign out of personal iCloud on the Studio first; sign into the company one).
4. Optional: enroll the Studio + the MacBook in **MDM** (remote config/wipe/inventory).
   Buy iCloud storage per-user if you want company document/photo storage.
5. Keep OS state on **git + the daily local/R2 backups** — Apple Business owns
   *identity + devices*, git owns *the OS*. No overlap.

Availability: Apple Business Manager is in 200+ countries (2026); confirm your country
specifics at business.apple.com before relying on any single feature.

## Gotchas the kit already handles
- **Username change** — plists are `__HOME__` templates; install.sh substitutes `$HOME`.
- **Node version / Homebrew prefix differ** — install.sh computes `__PATH__` from the
  live `brew --prefix` + `command -v node` at install time.
- **TCC** — launchd can't exec from `~/Desktop`; install.sh installs runnable copies
  into `~/.claude/scripts` (source stays in `ops/`).
- **New scripts** — dynamic copy + schedule; nothing to hardcode.
