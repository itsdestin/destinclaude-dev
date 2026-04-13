# Local dev alongside the built app

Running a dev build of DestinCode while your installed/built app is still open (with real Claude sessions running) is an explicit supported workflow. This doc explains how it works and what to watch for.

## Quick start

```bash
bash scripts/run-dev.sh
```

That sets two env vars and runs `npm run dev` in `destincode/desktop/`:

- `DESTINCODE_PORT_OFFSET=50` — shifts every port destincode controls.
- `DESTINCODE_PROFILE=dev` — splits Electron userData into a separate dir.

## What gets isolated

| Thing | Built app | Dev instance |
|---|---|---|
| Vite dev server | n/a (packaged) | `localhost:5223` |
| Remote server default port | 9900 | 9950 |
| Electron `userData` | `%APPDATA%/destincode/` | `%APPDATA%/destincode-dev/` |
| Window title / dock label | DestinCode | DestinCode Dev |
| localStorage (theme, font, recents) | untouched | dev-only, starts empty |

Running a second concurrent dev? Set `DESTINCODE_PORT_OFFSET=100` (or any other free offset) before invoking. The script uses 50 by default.

## What is shared (intentional)

Dev and built both read and write `~/.claude/`:

- `settings.json`, `enabledPlugins`
- `installed_plugins.json`, `known_marketplaces.json`, `marketplaces/destincode/`
- Plugin skills, themes, memory, sync state
- Claude Code CLI sessions, projects, credentials

This is intentional — isolating these would mean dev can't test against your real plugins and settings, which defeats the point. Two coordination mechanisms keep it safe:

1. **`.sync-lock` is a `mkdir`-based atomic lock.** Only one instance syncs at a time.
2. **`write-guard.sh`** (toolkit PreToolUse hook) tracks per-file writes in `.write-registry.json` and blocks a second session from writing a file another live session just wrote. Cross-instance concurrent writes surface as `WRITE BLOCKED` messages — friction, not corruption. Re-read the file and retry.

## Caveats

- **Plugin install/uninstall mutates your real state.** Installing a plugin in dev adds it to your built app's enabled plugins too. Clean up after testing if you don't want that to stick.
- **Windows OneDrive.** If `~/.claude/` lives under a OneDrive-synced folder, two writers can produce conflict copies. Check with `(Resolve-Path ~/.claude).Path` in PowerShell — if the path starts with a OneDrive folder, either exclude `.claude` from sync or accept the occasional conflict file.
- **Second dev run fails noisily.** `strictPort: true` in `vite.config.ts` means if the dev port is already taken, Vite errors instead of silently picking the next one. Kill the stale process or bump `DESTINCODE_PORT_OFFSET`.
- **If dev crashes, close only the dev window.** The built app is unaffected.

## Committing dev changes

Work lives in a worktree (`.worktrees/destincode-dev-profile`). The usual flow applies:

```bash
cd .worktrees/destincode-dev-profile
git add -p
git commit
git push origin dev-profile
# open PR, merge, then:
cd ../..
git worktree remove .worktrees/destincode-dev-profile
git -C destincode branch -D dev-profile
```

## How it's wired

| File | Role |
|---|---|
| `destincode/desktop/src/shared/ports.ts` | Single source of truth for `VITE_DEV_PORT` and `REMOTE_SERVER_DEFAULT_PORT`, both derived from `DESTINCODE_PORT_OFFSET`. |
| `destincode/desktop/vite.config.ts` | Reads the same env var directly (vite.config runs outside the main tsconfig). |
| `destincode/desktop/src/main/main.ts` | Computes `DEV_SERVER_URL` from the shared constant; splits `userData` and app name when `DESTINCODE_PROFILE=dev`. |
| `destincode/desktop/src/main/remote-config.ts` | Default port comes from the shared constant. |
| `scripts/run-dev.sh` | Sets both env vars and runs `npm run dev`. |
