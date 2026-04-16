# Local dev alongside the built app

Running a dev build of YouCoded while your installed/built app is still open (with real Claude sessions running) is an explicit supported workflow. This doc explains how it works and what to watch for.

## Quick start

```bash
bash scripts/run-dev.sh
```

That sets two env vars and runs `npm run dev` in `youcoded/desktop/`:

- `YOUCODED_PORT_OFFSET=50` — shifts every port youcoded controls.
- `YOUCODED_PROFILE=dev` — splits Electron userData into a separate dir.

## What gets isolated

| Thing | Built app | Dev instance |
|---|---|---|
| Vite dev server | n/a (packaged) | `localhost:5223` |
| Remote server default port | 9900 | 9950 |
| Electron `userData` | `%APPDATA%/youcoded/` | `%APPDATA%/youcoded-dev/` |
| Window title / dock label | YouCoded | YouCoded Dev |
| localStorage (theme, font, recents) | untouched | dev-only, starts empty |
| `~/.claude/settings.json` hooks | written by the built app | **not touched by dev** (see below) |

Running a second concurrent dev? Set `YOUCODED_PORT_OFFSET=100` (or any other free offset) before invoking. The script uses 50 by default.

### Why dev doesn't install hooks

`scripts/install-hooks.js` writes absolute paths to `hook-scripts/relay.js`, `title-update.sh`, etc. into `~/.claude/settings.json`. If dev ran that script from a worktree, the paths would point into the worktree — and the moment the worktree is removed, every hook call fails with ENOENT. Sessions then hang on the "Initializing" overlay forever because the app waits for the first hook event to confirm Claude is alive.

To prevent that, `main.ts` skips `install-hooks` when `YOUCODED_PROFILE=dev`. Dev uses whatever hook-script paths the built app last wrote. Tradeoff: editing `hook-scripts/*.js` or `*.sh` in dev won't take effect until you rebuild and reinstall the app. Hook-script changes are rare in practice.

The built app also self-checks on every startup: if it finds a hook command whose path contains `.worktrees/` or doesn't exist on disk, it logs a warning and lets `install-hooks.js` repair it. So even if something slips past (e.g., from an older dev build that didn't have the skip-in-dev gate), relaunching the built app once recovers automatically.

If you ever see errors like `Cannot find module 'C:\...\.worktrees\...\relay.js'` in the terminal, that's the smoking gun — **close the dev app and relaunch the built app once**.

## What is shared (intentional)

Dev and built both read and write `~/.claude/`:

- `settings.json`, `enabledPlugins`
- `installed_plugins.json`, `known_marketplaces.json`, `marketplaces/youcoded/`
- Plugin skills, themes, memory, sync state
- Claude Code CLI sessions, projects, credentials

This is intentional — isolating these would mean dev can't test against your real plugins and settings, which defeats the point. Two coordination mechanisms keep it safe:

1. **`.sync-lock` is a `mkdir`-based atomic lock.** Only one instance syncs at a time.
2. **`write-guard.sh`** (toolkit PreToolUse hook) tracks per-file writes in `.write-registry.json` and blocks a second session from writing a file another live session just wrote. Cross-instance concurrent writes surface as `WRITE BLOCKED` messages — friction, not corruption. Re-read the file and retry.

## Caveats

- **Plugin install/uninstall mutates your real state.** Installing a plugin in dev adds it to your built app's enabled plugins too. Clean up after testing if you don't want that to stick.
- **Windows OneDrive.** If `~/.claude/` lives under a OneDrive-synced folder, two writers can produce conflict copies. Check with `(Resolve-Path ~/.claude).Path` in PowerShell — if the path starts with a OneDrive folder, either exclude `.claude` from sync or accept the occasional conflict file.
- **Second dev run fails noisily.** `strictPort: true` in `vite.config.ts` means if the dev port is already taken, Vite errors instead of silently picking the next one. Kill the stale process or bump `YOUCODED_PORT_OFFSET`.
- **If dev crashes, close only the dev window.** The built app is unaffected.

## Committing dev changes

Work lives in a worktree (`.worktrees/youcoded-dev-profile`). The usual flow applies:

```bash
cd .worktrees/youcoded-dev-profile
git add -p
git commit
git push origin dev-profile
# open PR, merge, then:
cd ../..
git worktree remove .worktrees/youcoded-dev-profile
git -C youcoded branch -D dev-profile
```

## How it's wired

| File | Role |
|---|---|
| `youcoded/desktop/src/shared/ports.ts` | Single source of truth for `VITE_DEV_PORT` and `REMOTE_SERVER_DEFAULT_PORT`, both derived from `YOUCODED_PORT_OFFSET`. |
| `youcoded/desktop/vite.config.ts` | Reads the same env var directly (vite.config runs outside the main tsconfig). |
| `youcoded/desktop/src/main/main.ts` | Computes `DEV_SERVER_URL` from the shared constant; splits `userData` and app name when `YOUCODED_PROFILE=dev`. |
| `youcoded/desktop/src/main/remote-config.ts` | Default port comes from the shared constant. |
| `scripts/run-dev.sh` | Sets both env vars and runs `npm run dev`. |
