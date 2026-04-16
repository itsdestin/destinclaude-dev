# YouCoded Toolkit Structure

The toolkit at `youcoded-core/` ships as a Claude Code plugin with a root manifest plus three functional layers. Each has its own `plugin.json`.

| File | Version | Purpose |
|------|---------|---------|
| `youcoded-core/plugin.json` | v2.3.2 (root/aggregate) | Root manifest — what users install |
| `youcoded-core/core/plugin.json` | v0.1.0 | Foundation — hooks, setup, sync, themes |
| `youcoded-core/life/plugin.json` | v0.1.0 | Personal knowledge — journal, encyclopedia |
| `youcoded-core/productivity/plugin.json` | v0.1.0 | Task processing, skill creation, messaging |

## Skills

Skills are directories containing a `SKILL.md` file. YAML frontmatter `description` is how Claude discovers when to invoke them. Skills live under each layer (e.g., `core/skills/sync/SKILL.md`). During setup they are symlinked into `~/.claude/plugins/youcoded-core/`.

## Hooks

Declared in `core/hooks/hooks-manifest.json` — **desired-state format**. During `/update`, `phase_settings_migrate()` merges this into the user's `settings.json`. **Never edit hooks in settings.json directly — update the manifest.**

Current manifest declares 11 hooks across 6 types:
- SessionStart: `session-start.sh`, `contribution-detector.sh`
- PreToolUse: `write-guard.sh`, `worktree-guard.sh`, `tool-router.sh`
- PostToolUse: `sync.sh`, `title-update.sh`
- UserPromptSubmit: `todo-capture.sh`
- Stop: `checklist-reminder.sh`, `done-sound.sh`
- SessionEnd: `session-end-sync.sh`

## Hook guards

- **`write-guard.sh`** — same-machine concurrency guard. Blocks writes to tracked files (memory, CLAUDE.md, settings.json, etc.) when another active Claude session last modified the file. Uses `.write-registry.json`.
- **`worktree-guard.sh`** — enforces single-branch policy. Blocks `git checkout`/`switch` in the main plugin dir. Feature work must use `git worktree add`.

## Commands

Markdown files in `core/commands/` become slash commands (e.g., `/update`, `/health`, `/toolkit`, `/restore`, `/diagnose`, `/appupdate`, `/contribute`, `/toolkit-uninstall`).

## Important conventions

- `.sh` files MUST have execute bit set. On Windows: `git update-index --chmod=+x path/to/file.sh`
- `config.json` is portable (synced across devices). `config.local.json` is machine-specific and rebuilt every session by `session-start.sh`.
- Specs live in `core/specs/` (living docs). Plans live in `docs/plans/` (historical).
